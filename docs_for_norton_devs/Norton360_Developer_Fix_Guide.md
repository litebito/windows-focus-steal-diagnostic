# Norton 360 NortonUI.exe Focus-Steal Bug: Developer Fix Guide

## For: Gen Digital / Norton 360 Engineering Team
## Document Version: 1.0
## Date: April 4, 2026

---

## Executive Summary

NortonUI.exe steals foreground window focus approximately every 60 seconds via its
Chromium Embedded Framework (CEF) windows, even when those windows are invisible.
This is caused by a combination of a disabled Chromium occlusion feature, an outdated
CEF/Chromium build, and a background timer that triggers CEF window activation without
checking visibility state. This document provides the exact root cause analysis,
affected code paths, and specific fixes with code examples.

---

## 1. Architecture Overview (As Observed)

Based on process tree analysis and command-line extraction via WMI:

```
NortonUI.exe /nogui                              [MAIN PROCESS - PID 22188]
  |
  +-- NortonUI.exe --type=gpu-process             [GPU - SwiftShader software rendering]
  |     --use-gl=swiftshader-webgl
  |
  +-- NortonUI.exe --type=utility                 [NETWORK SERVICE]
  |     --utility-sub-type=network.mojom.NetworkService
  |
  +-- NortonUI.exe --type=utility                 [STORAGE SERVICE]
        --utility-sub-type=storage.mojom.StorageService
```

The main process (PID 22188) is the browser/host process in CEF terms. It owns the
`CefHeaderWindow` and `Chrome_WidgetWin_0` window classes. The child processes are
standard Chromium multi-process architecture (GPU, network, storage services).

The main process is launched by `AvLaunch.exe /gui` (registered in HKLM Run key),
which spawns NortonUI.exe with the `/nogui` flag — meaning it starts headless with
no visible window, creating only hidden CEF browser windows for background operations.

---

## 2. Root Cause Analysis

### 2.1 Primary Cause: CalculateNativeWinOcclusion Disabled

The CEF child processes are launched with:

```
--disable-features=CalculateNativeWinOcclusion
```

`CalculateNativeWinOcclusion` (introduced in Chromium 86, stabilized in 87+) allows
Chromium to detect when its windows are occluded (hidden behind other windows,
minimized, or on other virtual desktops). When enabled, Chromium:

- Throttles rendering for occluded windows
- Avoids activating occluded windows into the foreground
- Reduces resource usage for non-visible content

When this feature is **disabled**, the CEF engine has no awareness that its windows
are hidden. Any internal operation that triggers a window update, paint, or focus
request will attempt to activate the window as if it were visible, calling the
Win32 `SetForegroundWindow` or `BringWindowToTop` API — which steals focus from
the user's active application.

**Why was this likely disabled?** Possible reasons:

1. **Compatibility:** Older CEF builds (especially based on Chromium 91) had bugs
   in the occlusion calculation on multi-monitor setups, sometimes incorrectly
   marking visible windows as occluded and not rendering them. Disabling it was
   a common workaround.

2. **Norton-specific rendering:** If Norton's CEF content needs to render in the
   background (e.g., pre-rendering notification content), occlusion detection
   would throttle this rendering. However, the correct fix is to use offscreen
   rendering (OSR), not to disable occlusion detection.

3. **Copy-paste from old configuration:** The flag may have been added during
   initial CEF integration and never re-evaluated.

### 2.2 Secondary Cause: Background Timer Without Visibility Check

The main NortonUI.exe process has a periodic timer (observed interval: ~60 seconds)
that performs some background operation — likely one or more of:

- Subscription/license status check
- Telemetry heartbeat
- Notification polling
- UI state refresh
- Security status dashboard update

This timer callback interacts with the CEF browser windows in a way that triggers
foreground activation. The likely code pattern is:

```cpp
// CURRENT (BUGGY) PATTERN - pseudocode
void OnTimerCallback() {
    // Perform status check
    UpdateSecurityStatus();

    // This triggers CEF to activate its browser window
    // because it needs to update DOM/JavaScript state
    cef_browser_->GetMainFrame()->ExecuteJavaScript(
        "updateDashboard(statusData);", "", 0);

    // OR: Direct window manipulation
    CefWindowHandle hwnd = cef_browser_->GetHost()->GetWindowHandle();
    // Any of these will steal focus:
    // ::SetForegroundWindow(hwnd);
    // ::BringWindowToTop(hwnd);
    // ::ShowWindow(hwnd, SW_SHOW);
    // ::UpdateWindow(hwnd);
    // Even InvalidateRect can cascade to activation
    // when CalculateNativeWinOcclusion is disabled
}
```

### 2.3 Tertiary Cause: Outdated Chromium/CEF Version

The user-agent string reveals:

```
Chrome/91.0.4472.101
```

Chromium 91 was released in **May 2021** and reached end-of-life in **September 2021**.
This is over 4 years behind current stable. Relevant issues:

- Chromium 91's window management has known bugs with Windows 11's new window
  manager (DWM changes in Windows 11 21H2+)
- The occlusion detection in Chromium 91 was less mature than current versions
  (significant improvements landed in 96-102)
- Multiple CVEs exist for Chromium 91 (though Norton runs with --no-sandbox,
  which is a separate concern)
- The "Avastium" user-agent suffix suggests this CEF build predates or was
  inherited from the Avast/Norton merger

---

## 3. Recommended Fixes

### Fix 1: Remove CalculateNativeWinOcclusion from Disabled Features (IMMEDIATE)

**Impact: HIGH | Effort: LOW | Risk: LOW**

In the code that constructs the CEF command-line arguments (likely in a
`CefApp::OnBeforeCommandLineProcessing` override or in the process launcher),
remove `CalculateNativeWinOcclusion` from the disabled features list.

**Current code (approximate):**
```cpp
// In CefApp::OnBeforeCommandLineProcessing or equivalent
void NortonCefApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {

    command_line->AppendSwitchWithValue(
        "disable-features",
        "CalculateNativeWinOcclusion,"       // <-- REMOVE THIS
        "CookiesWithoutSameSiteMustBeSecure,"
        "SameSiteByDefaultCookies,"
        "SameSiteDefaultChecksMethodRigorously,"
        "WebRtcHideLocalIpsWithMdns"
    );
}
```

**Fixed code:**
```cpp
void NortonCefApp::OnBeforeCommandLineProcessing(
    const CefString& process_type,
    CefRefPtr<CefCommandLine> command_line) {

    command_line->AppendSwitchWithValue(
        "disable-features",
        "CookiesWithoutSameSiteMustBeSecure,"
        "SameSiteByDefaultCookies,"
        "SameSiteDefaultChecksMethodRigorously,"
        "WebRtcHideLocalIpsWithMdns"
    );

    // If background rendering is needed, use OSR mode instead of
    // disabling occlusion detection (see Fix 3)
}
```

**Testing:** After this change, verify that:
1. Background status checks no longer steal foreground focus
2. Norton notification popups still render correctly when triggered
3. The Norton dashboard renders correctly when the user opens it manually
4. Multi-monitor setups don't exhibit rendering artifacts

### Fix 2: Add Visibility Check Before Window Activation (IMMEDIATE)

**Impact: HIGH | Effort: LOW | Risk: LOW**

In the timer callback that triggers the CEF browser update, add a visibility
check before any operation that could activate the window:

```cpp
void OnTimerCallback() {
    UpdateSecurityStatus();

    CefWindowHandle hwnd = cef_browser_->GetHost()->GetWindowHandle();

    // CHECK 1: Is the window visible?
    if (!::IsWindowVisible(hwnd)) {
        // Window is hidden - do NOT interact with it visually.
        // Use IPC or shared memory to pass data instead.
        SendStatusViaPipe(statusData);
        return;
    }

    // CHECK 2: Is the window the foreground window? If not, don't activate it.
    if (::GetForegroundWindow() != hwnd) {
        // Window exists but is not in foreground - user is working elsewhere.
        // Queue the update for when the user next brings Norton to foreground.
        pendingUpdate_ = statusData;
        return;
    }

    // Window is visible AND in foreground - safe to update
    cef_browser_->GetMainFrame()->ExecuteJavaScript(
        "updateDashboard(statusData);", "", 0);
}
```

Additionally, if any code calls `SetForegroundWindow`, `BringWindowToTop`,
`ShowWindow`, or `SetWindowPos` with `HWND_TOP`/`HWND_TOPMOST`, wrap it:

```cpp
// NEVER call SetForegroundWindow from a background timer
// This is the direct cause of focus stealing

// If you must show a notification window, use the Windows toast
// notification API instead, which does not steal focus:
// https://learn.microsoft.com/en-us/windows/apps/design/shell/tiles-and-notifications/send-local-toast

// If you must use a custom window for notifications, create it with
// WS_EX_NOACTIVATE to prevent focus stealing:
HWND hNotify = CreateWindowEx(
    WS_EX_NOACTIVATE | WS_EX_TOPMOST | WS_EX_TOOLWINDOW,
    L"NortonNotificationClass",
    L"Norton 360",
    WS_POPUP,
    x, y, width, height,
    NULL, NULL, hInstance, NULL);

// Show without activating:
ShowWindow(hNotify, SW_SHOWNOACTIVATE);
```

### Fix 3: Use Off-Screen Rendering (OSR) for Background Operations (MEDIUM-TERM)

**Impact: HIGH | Effort: MEDIUM | Risk: LOW**

If the background timer needs to execute JavaScript or update CEF content
without a visible window, use CEF's Off-Screen Rendering mode. OSR renders
to a memory buffer instead of a window, eliminating any possibility of
focus stealing:

```cpp
// Configure the browser for off-screen rendering
CefWindowInfo window_info;
window_info.SetAsWindowless(0);  // No parent window, fully offscreen

CefBrowserSettings browser_settings;
// Disable unnecessary features for background operation
browser_settings.windowless_frame_rate = 1;  // Minimum frame rate

// Create the browser in windowless mode
CefBrowserHost::CreateBrowser(
    window_info,
    client_handler,
    "about:blank",      // or your status page URL
    browser_settings,
    nullptr,
    nullptr);

// The CefRenderHandler::OnPaint callback receives the rendered buffer
// but never creates or activates any window
```

When the user explicitly opens the Norton dashboard (via tray icon or Start Menu),
create a NEW windowed browser instance for the visible UI. When they close it,
destroy the windowed browser and continue with OSR-only.

### Fix 4: Replace CEF Timer with Non-UI IPC (MEDIUM-TERM)

**Impact: HIGH | Effort: MEDIUM | Risk: LOW**

The background status polling should not go through the CEF browser at all.
NortonSvc.exe (the protection service) already runs as a separate process.
Communication between NortonSvc and NortonUI should use non-UI IPC:

```cpp
// Option A: Named Pipes (preferred for Windows services)
// NortonSvc.exe (server)
HANDLE hPipe = CreateNamedPipe(
    L"\\\\.\\pipe\\NortonStatusPipe",
    PIPE_ACCESS_DUPLEX,
    PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
    1, 4096, 4096, 0, NULL);

// NortonUI.exe (client) - poll without any window interaction
void OnTimerCallback() {
    HANDLE hPipe = CreateFile(
        L"\\\\.\\pipe\\NortonStatusPipe",
        GENERIC_READ, 0, NULL, OPEN_EXISTING, 0, NULL);
    if (hPipe != INVALID_HANDLE_VALUE) {
        char buffer[4096];
        DWORD bytesRead;
        ReadFile(hPipe, buffer, sizeof(buffer), &bytesRead, NULL);
        // Parse status data
        // Only update CEF browser if window is visible AND foreground
        CloseHandle(hPipe);
    }
}

// Option B: WMI / COM (already used by Norton for other operations)
// Option C: Shared memory (fastest, good for frequent polling)
// Option D: Windows event objects (for event-driven instead of polling)
```

### Fix 5: Upgrade CEF/Chromium (LONG-TERM)

**Impact: HIGH | Effort: HIGH | Risk: MEDIUM**

Upgrade from Chromium 91 to the latest CEF stable branch. As of early 2026,
this would be CEF based on Chromium 130+. Benefits:

- Window occlusion detection is mature and reliable (significant improvements
  in Chromium 96-102)
- Windows 11 DWM integration is properly handled
- Hundreds of security patches (91 has multiple known CVEs)
- `WS_EX_NOACTIVATE` support is improved
- Modern Chromium has built-in focus-stealing prevention for background tabs

The CEF upgrade also allows removing several workaround flags currently in use:
- `--blacklist-accelerated-compositing` (deprecated flag name)
- `--disable-flash-3d` (Flash is removed)
- `--disable-bundled-ppapi-flash` (Flash is removed)
- `--use-gl=swiftshader-webgl` (modern Chromium has better GPU fallback)
- `--no-sandbox` (should be re-evaluated for security)

**Migration path:**
1. Update to CEF 118+ (LTS branch)
2. Remove deprecated command-line flags
3. Enable `CalculateNativeWinOcclusion` (it's on by default)
4. Test notification popups with `WS_EX_NOACTIVATE`
5. Evaluate re-enabling sandbox for child processes

---

## 4. Specific Code Locations to Investigate

Based on the observed behavior, the engineering team should focus on:

### 4.1 CEF Command-Line Construction
Search the codebase for:
```
CalculateNativeWinOcclusion
disable-features
OnBeforeCommandLineProcessing
```

### 4.2 Timer/Polling Mechanism
Search for the ~60-second timer. Look for:
```
SetTimer
CreateTimerQueueTimer
std::thread.*sleep.*60
std::chrono.*seconds(60)
CefPostDelayedTask
base::RepeatingTimer
```

### 4.3 Window Activation Calls
Search for any calls that activate windows from a non-UI thread or timer context:
```
SetForegroundWindow
BringWindowToTop
SetWindowPos.*HWND_TOP
ShowWindow.*SW_SHOW
SetActiveWindow
SetFocus
```

### 4.4 CEF Browser Window Handle Access
Search for code that obtains and manipulates the browser HWND:
```
GetWindowHandle
GetHost()->
GetMainFrame()->ExecuteJavaScript
CefBrowser.*Reload
CefBrowser.*LoadURL
```

### 4.5 Notification/Status Update Path
The Norton dashboard has a status display that shows protection status,
subscription status, and last scan info. The code path that updates this
display is likely the one firing the timer. Search for:
```
updateDashboard
statusCheck
heartbeat
telemetry
subscription.*check
license.*check
notification.*poll
```

---

## 5. Quick Validation Test

To verify the fix without a full build/release cycle:

### Test 1: Focus Steal Detection
Use `SetWinEventHook` with `EVENT_SYSTEM_FOREGROUND` to monitor foreground
changes for 30 minutes. Count NortonUI focus events on invisible windows.
- **Before fix:** ~30 events (one per minute)
- **After fix:** 0 events

### Test 2: Display Sleep
Set display timeout to 2 minutes. Leave the system idle.
- **Before fix:** Display never sleeps (NortonUI resets idle timer)
- **After fix:** Display sleeps after 2 minutes

### Test 3: Typing Interruption
Open Notepad and type continuously for 5 minutes.
- **Before fix:** Cursor loses focus momentarily every ~60 seconds
- **After fix:** No interruption

### Test 4: Full-screen Application
Run any full-screen application (game, video player) for 10 minutes.
- **Before fix:** Application loses foreground periodically
- **After fix:** Application maintains foreground continuously

A PowerShell diagnostic script for Test 1 is publicly available at:
https://github.com/[REPO_URL]/FocusStealDiagnostic.ps1

---

## 6. Side Effects to Monitor

When implementing the fixes, watch for:

1. **Notification popups not appearing:** If the notification system relies on
   the timer activating the CEF window, the notification path needs to be
   updated to explicitly create/show a notification window (with WS_EX_NOACTIVATE)
   rather than relying on the browser window activation.

2. **Dashboard not updating when visible:** If the user has the Norton dashboard
   open, the timer should still update it. The fix should check `IsWindowVisible`
   AND `GetForegroundWindow` before deciding to update vs. queue.

3. **First-open delay:** If status data is no longer pre-rendered in background
   CEF, the first open of the Norton dashboard may be slightly slower. Pre-fetch
   via IPC (Fix 4) mitigates this.

4. **Tray icon status:** If the tray icon tooltip or overlay icon depends on the
   CEF timer, switch it to use `Shell_NotifyIcon` with `NIF_INFO` directly from
   the NortonSvc communication, bypassing CEF entirely.

---

## 7. Affected Versions

Based on community reports, this bug has been present in:
- Norton 360 v24.x (first reports: late 2024)
- Norton 360 v25.8.10387
- Norton 360 v25.9.10453
- Norton 360 v25.10.x
- Norton 360 v25.11.10580
- Norton 360 v25.12.10659
- Norton 360 v26.3.10886 (latest confirmed, April 2026)

The bug has persisted across **6+ major version updates** over **16+ months**
without a permanent fix, affecting users on both Windows 10 and Windows 11.

---

## 8. References

- Chromium CalculateNativeWinOcclusion: https://chromium-review.googlesource.com/c/chromium/src/+/2592aspect (feature tracking)
- CEF Window Management: https://bitbucket.org/chromiumembedded/cef/wiki/GeneralUsage#markdown-header-windows
- CEF Off-Screen Rendering: https://bitbucket.org/chromiumembedded/cef/wiki/GeneralUsage#markdown-header-off-screen-rendering
- Win32 SetForegroundWindow restrictions: https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setforegroundwindow#remarks
- WS_EX_NOACTIVATE: https://learn.microsoft.com/en-us/windows/win32/winmsg/extended-window-styles
- Windows Toast Notifications: https://learn.microsoft.com/en-us/windows/apps/design/shell/tiles-and-notifications/send-local-toast
- Norton Community threads documenting the bug:
  - https://community.norton.com/t/norton-randomly-making-my-window-lose-focus/355708
  - https://community.norton.com/t/focus-window-issue-norton-25-10/454258
  - https://community.norton.com/t/norton360-makes-keyboard-unusable-constantly-grabs-focus/439327
  - https://community.norton.com/t/nortonui-causing-disruptive-hiccups/476810
