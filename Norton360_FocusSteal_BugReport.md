# Norton 360 Bug Report: NortonUI.exe Steals Foreground Window Focus via Invisible CEF Windows

## Issue Abstract

NortonUI.exe periodically activates invisible Chromium Embedded Framework (CEF) windows into the foreground, stealing focus from the user's active application approximately every 60 seconds. This causes input interruption, workflow disruption, and prevents Windows display sleep. The root cause is the `--disable-features=CalculateNativeWinOcclusion` flag in the CEF launch configuration combined with a periodic background timer.

\---
https://github.com/litebito/windows-focus-steal-diagnostic/tree/main
\---

## Product Information

* **Product:** Norton 360
* **Version:** 26.3.10886.0 (build 26.3.10886.0)
* **NortonUI.exe File Date:** 2026-03-31 07:49:07
* **Company:** Gen Digital Inc.
* **OS:** Windows 11 Pro 24H2
* **Computer Name:** PLATINUM

## Detailed Description

### Symptom

Every \~60 seconds, the currently active foreground window loses focus for 1-2 seconds. This occurs regardless of which application is in use. The display never enters sleep mode because each focus change resets the Windows idle timer.

### Diagnostic Method

A custom PowerShell diagnostic tool was developed using `SetWinEventHook` (hooking `EVENT\_SYSTEM\_FOREGROUND`) to capture every foreground window change with full process metadata including:

* Process ID, name, and full path
* Window class and title
* Window visibility state (IsVisible)
* Parent process information
* Full command line (via WMI)
* Precise millisecond timestamps

### Findings: With NortonUI Running

Monitoring period: \~30 minutes of normal desktop use.

* **Total focus change events:** 420
* **NortonUI.exe events:** 178 (42% of all events)
* **NortonUI events on INVISIBLE windows:** 178 out of 178 (100%)
* **Window classes involved:** `CefHeaderWindow` (79 events), `Chrome\_WidgetWin\_0` (99 events)
* **Window title:** "Norton 360" (on CefHeaderWindow), empty string (on Chrome\_WidgetWin\_0)
* **Offending PID:** 22188 (main NortonUI process launched with /nogui flag)
* **Interval:** Approximately 58-70 seconds between cycles

Each focus-steal cycle follows this pattern:

1. User's active window deactivates (captured as PID=0 / Idle)
2. NortonUI PID 22188 activates invisible `CefHeaderWindow` (Title: "Norton 360")
3. NortonUI PID 22188 activates invisible `Chrome\_WidgetWin\_0` (Title: empty)
4. Focus returns to user's previously active window

### Findings: With NortonUI Stopped

NortonUI.exe was terminated (after temporarily disabling tamper protection). NortonSvc.exe and all other Norton services continued running.

* **Total focus change events:** 23
* **NortonUI events:** 0
* **Invisible window events:** 0
* **All 23 events:** Legitimate user-initiated window switches (Chrome, WhatsApp, Notepad, Calculator, Task Manager)

This confirms NortonUI.exe is the sole cause of the focus stealing behavior.

## NortonUI Process Tree at Time of Issue

```
PID 22188 - NortonUI.exe /nogui                    \[259.8 MB] \[MAIN - Parent of all below]
  PID 18044 - NortonUI.exe --type=utility (network)  \[41 MB]
  PID 20716 - NortonUI.exe --type=utility (storage)  \[33.4 MB]
  PID 29984 - NortonUI.exe --type=gpu-process         \[43.4 MB]
```

## Root Cause: CEF Configuration Issue

The NortonUI.exe CEF child processes are launched with the following critical flag:

```
--disable-features=CalculateNativeWinOcclusion
```

`CalculateNativeWinOcclusion` is a Chromium feature (introduced in Chromium 86) that enables the browser to detect when its windows are hidden, minimized, or covered by other windows. When this feature is **disabled**, the CEF engine does not recognize that its windows are occluded/invisible. Consequently, when an internal timer fires (such as a status poll, telemetry check, or notification refresh), CEF activates its windows into the foreground as if they need to be displayed - even though they are invisible.

### Additional Concerning Observations

1. **Outdated Chromium Engine:** The user-agent string reveals Chromium 91 (released June 2021):

```
   Chrome/91.0.4472.101
   ```

   This is over 4 years behind the current Chromium stable channel.

2. **Legacy Branding:** The user-agent contains "Avastium (0.0.0)" suggesting legacy code from the Norton/Avast merger.
3. **Sandbox Disabled:** The processes run with `--no-sandbox` (specified twice in some command lines).
4. **GPU disabled but GPU process spawned:** Multiple `--disable-gpu` flags are set, yet a dedicated GPU process is still spawned using SwiftShader software rendering.

   ## Impact

* **Productivity:** Any text input, code editing, document writing, or form filling is interrupted every \~60 seconds
* **Gaming:** Full-screen applications lose focus, causing game menus to appear or gameplay to pause
* **Display Sleep:** The idle timer is reset with every focus change, preventing the monitor from entering power-saving mode
* **User Trust:** The behavior mimics malware (invisible processes stealing focus) and causes users to suspect a security compromise

  ## Existing Community Reports

  This issue has been reported by multiple users across several Norton Community threads spanning over a year:

1. **"Norton randomly making my window lose focus?"** - community.norton.com (December 20, 2024) - 3+ pages, multiple affected users
2. **"Possibly NllToolsSvc.exe causes loosing focus on a window"** - community.norton.com (December 24, 2024)
3. **"Norton360 Makes Keyboard unusable -- constantly grabs focus"** - community.norton.com (September 22, 2025) - described as making "Windows 11 systems completely unusable"
4. **"Focus window issue Norton 25.10"** - community.norton.com (October 15, 2025) - 2+ pages with ongoing discussion
5. **"NortonUI causing disruptive Hiccups"** - community.norton.com (November 26, 2025) - reports focus steal every 30 seconds

   Affected versions reported across all threads: 24.x, 25.8, 25.9, 25.10, 25.11, 25.12, 26.3.

   No permanent fix has been delivered in any of these versions.

   ## Recommended Fix

1. **Remove `--disable-features=CalculateNativeWinOcclusion`** from all CEF launch parameters, or implement proper occlusion-aware window management that prevents hidden windows from requesting foreground activation.
2. **Replace foreground window activation** in the background timer callback with a non-UI IPC mechanism (named pipes, WMI, COM, or Windows messages) for status checks and telemetry.
3. **Update the CEF/Chromium engine** from version 91 to a current release. Chromium 91 reached end-of-life in 2021 and contains known security vulnerabilities.
4. **Ensure `SetForegroundWindow` or equivalent Win32 API calls** are not invoked on hidden/minimized/occluded windows during background operations.

   ## Workaround

   Killing NortonUI.exe while leaving NortonSvc.exe running eliminates the issue entirely. Core antivirus protection, firewall (afwServ.exe), and VPN (VpnSvc.exe) continue to function without NortonUI. Users lose the system tray icon and real-time visual notifications but retain full protection.

   ## Attachments Available

   The following diagnostic artifacts are available upon request:

* FocusStealLog.csv (420 events with full process metadata - with NortonUI)
* FocusStealLog\_NoNorton.csv (23 events - without NortonUI, clean baseline)
* FocusStealDetail.txt (timestamped detail log with process tree)
* NortonDiagReport.txt (Norton process tree, scheduled tasks, services, registry, version info)
* FocusStealDiagnostic.ps1 (the PowerShell diagnostic tool used for this investigation)

  \---



