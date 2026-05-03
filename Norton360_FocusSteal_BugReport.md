# Norton 360 Bug Report: NortonUI.exe Steals Foreground Window Focus via Invisible CEF Windows

## Issue Abstract

NortonUI.exe periodically activates invisible Chromium Embedded Framework (CEF) windows into the foreground, stealing focus from the user's active application. The root cause is the `--disable-features=CalculateNativeWinOcclusion` flag in the CEF launch configuration combined with a periodic background timer that activates a hidden CefHeaderWindow.

**Status as of May 2, 2026:** Norton/Gen Digital released UI v1.0.138 which **partially mitigates** the issue (reducing frequency by ~78%) but does **not fix the root cause** — the CEF flag is still present, and invisible CefHeaderWindow activations still happen, just less often. This is the **second time** Norton has shipped a "fix" that only adjusts the timer interval without addressing the underlying defect (the first was UI v1.0.111 in November 2025).

This bug has been actively reported by users for **at least 18 months** (since October 2024), across at least 8 major Norton AV-module versions and multiple targeted UI patches.

---

https://github.com/litebito/windows-focus-steal-diagnostic

---

## Product Information

- **Product:** Norton 360
- **AV module versions tested:**
  - 26.3.10886.0 (April 4, 2026 — original test)
  - 26.4.10932.0 + UI v1.0.138 (May 2, 2026 — follow-up test)
- **Company:** Gen Digital Inc.
- **OS:** Windows 11 Pro 24H2

---

## Historical Timeline of This Bug

| Date | Norton version | Event |
|---|---|---|
| **Oct 10, 2024** | 24.x | Earliest known report on Norton Community ("Windows 10 Cursor looses focus while typing since install of new Norton version?") |
| **Dec 20, 2024** | 24.x | "Norton randomly making my window lose focus?" thread opens, multi-page, multiple users affected |
| **Dec 24, 2024** | 24.x | "Possibly NllToolsSvc.exe causes loosing focus on a window" — additional NortonUI sibling identified |
| **Jul 10, 2025** | 25.6.10221 | Japanese-language report identifies `CNortonTrayIcon` window class in NortonUI.exe |
| **Sep 22, 2025** | 25.9.10453 | "Norton360 Makes Keyboard unusable -- constantly grabs focus" — the largest active thread, described as making Windows 11 systems "completely unusable" |
| **Oct 15, 2025** | 25.10 | "Focus window issue Norton 25.10" thread opens |
| **Nov 13, 2025** | 25.11.10580 / **UI 1.0.111** | First named "fix" attempt. Multiple users explicitly confirm it does NOT resolve the issue. Quote: *"It seems that the only change was to delay the start of background operations and make the problem harder to reproduce rather than actually fixing the underlying bug."* |
| **Nov 26, 2025** | 25.11.x | "NortonUI causing disruptive Hiccups" — user reports focus steal every 30 seconds |
| **Dec 16, 2025** | 25.12 | "NortonUI.exe Silently Crashing in the Background" — related symptoms |
| **Dec 21, 2025** | 25.12.10659 | A user reports the issue resurfacing after an interim fix was overwritten by a newer build |
| **Feb 8, 2026** | 26.1 | New Japanese thread confirms the bug persists in 26.1 |
| **Mar 3, 2026** | 26.2.10802 | Released — bug still present |
| **Mar 31, 2026** | 26.3.10886 | Released — bug still present |
| **Apr 4, 2026** | 26.3.10886 | This investigation begins. Diagnostic captures 178 invisible NortonUI focus events in 30 minutes (42% of all events) with ~60s clockwork interval. Confirmed root cause: `--disable-features=CalculateNativeWinOcclusion` |
| **Apr 28, 2026** | 26.4.10932 / **UI 1.0.138** | Second named "fix" attempt — Norton support indicates the bug is resolved in this version |
| **May 2, 2026** | 26.4.10932 / UI 1.0.138 | Follow-up diagnostic shows frequency reduced 78% but the same defect pattern remains: every visible `GeniumWindow` activation still followed by invisible `CefHeaderWindow` activation. The CalculateNativeWinOcclusion flag is still present. |

**Affected versions reported across all sources:** 24.x, 25.6, 25.8, 25.9.10453, 25.10, 25.11.10580 (UI 1.0.111), 25.12.10659, 26.1, 26.2.10802, 26.3.10886, 26.4.10932 (UI 1.0.138).

**The "fix that doesn't fix" pattern has now happened twice** — UI v1.0.111 (Nov 2025) and UI v1.0.138 (Apr 2026). Both reduced symptoms without addressing root cause.

---

## Detailed Description

### Symptom
Periodically, the currently active foreground window loses focus for 1-2 seconds. This occurs regardless of which application is in use. The display never enters sleep mode because each focus change resets the Windows idle timer.

### Diagnostic Method
A custom PowerShell diagnostic tool was developed using `SetWinEventHook` (hooking `EVENT_SYSTEM_FOREGROUND`) to capture every foreground window change with full process metadata including:

- Process ID, name, and full path
- Window class and title
- Window visibility state (IsVisible)
- Parent process information
- Full command line (via WMI)
- Precise millisecond timestamps

The tool is publicly available at https://github.com/litebito/windows-focus-steal-diagnostic for independent reproduction. Crowdsourced reproduction logs from multiple users are accumulating in the [`logs/`](https://github.com/litebito/windows-focus-steal-diagnostic/tree/main/logs) directory.

### Original Findings (April 4, 2026 — AV module 26.3.10886.0)

Monitoring period: ~30 minutes of normal desktop use.

- **Total focus change events:** 420
- **NortonUI.exe events:** 178 (42% of all events)
- **NortonUI events on INVISIBLE windows:** 178 out of 178 (100%)
- **Window classes involved:** `CefHeaderWindow` (79 events), `Chrome_WidgetWin_0` (99 events)
- **Window title:** "Norton 360" (on CefHeaderWindow), empty string (on Chrome_WidgetWin_0)
- **Interval:** Approximately 58-70 seconds between cycles, near-zero jitter

Each focus-steal cycle follows this pattern:

1. User's active window deactivates (captured as PID=0 / Idle)
2. NortonUI activates invisible `CefHeaderWindow` (Title: "Norton 360")
3. NortonUI activates invisible `Chrome_WidgetWin_0` (Title: empty)
4. Focus returns to user's previously active window

### Confirmation: With NortonUI Stopped

NortonUI.exe was terminated (after temporarily disabling tamper protection). NortonSvc.exe and all other Norton services continued running.

- **Total focus change events:** 23
- **NortonUI events:** 0
- **Invisible window events:** 0
- **All 23 events:** Legitimate user-initiated window switches

This confirms NortonUI.exe is the sole cause of the focus stealing behavior.

Raw log data available in [`logs/example_litebito_2026-04-04/`](https://github.com/litebito/windows-focus-steal-diagnostic/tree/main/logs/example_litebito_2026-04-04).

---

## NortonUI Process Tree

### April 4, 2026 (AV module 26.3.10886)
```
PID 22188 - NortonUI.exe /nogui                    [259.8 MB] [MAIN - Parent of all below]
  PID 18044 - NortonUI.exe --type=utility (network)  [41 MB]
  PID 20716 - NortonUI.exe --type=utility (storage)  [33.4 MB]
  PID 29984 - NortonUI.exe --type=gpu-process         [43.4 MB]
```

### May 2, 2026 (AV module 26.4.10932 / UI 1.0.138)
```
PID 15024 - NortonUI.exe /nogui                    [310.5 MB] [MAIN]
  PID 37468 - NortonUI.exe --type=gpu-process       [41.9 MB]
  PID 37568 - NortonUI.exe --type=utility (storage) [7 MB]
  PID 37592 - NortonUI.exe --type=utility (network) [15.4 MB]
  PID 70436 - NortonUI.exe --type=renderer          [150.5 MB] *** NEW ***

(also new: aswEngSrv.exe — Avast scanning engine, 308 MB)
```

The new `--type=renderer` process is the CEF tab content process. It was spawned ~4 hours after the main NortonUI process started, suggesting on-demand rendering.

---

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

5. **Stale `wsc_proxy.exe`:** While every other Norton component is at 26.4.10932.0 (April 28, 2026), `wsc_proxy.exe` (the Windows Security Center reporter) is still at 23.1.38320.0 from November 2024.

---

## Impact

- **Productivity:** Any text input, code editing, document writing, or form filling is interrupted periodically
- **Gaming:** Full-screen applications lose focus, causing game menus to appear or gameplay to pause
- **Display Sleep:** The idle timer is reset with every focus change, preventing the monitor from entering power-saving mode
- **User Trust:** The behavior mimics malware (invisible processes stealing focus) and causes users to suspect a security compromise

---

## Existing Community Reports

The full timeline above documents 12+ distinct community threads across English and Japanese forums spanning 18+ months. Key threads:

1. "Windows 10 Cursor looses focus while typing since install of new Norton version?" (community.norton.com, Oct 10, 2024) — earliest report identified
2. "Norton randomly making my window lose focus?" (community.norton.com, Dec 20, 2024) — multi-page
3. "Possibly NllToolsSvc.exe causes loosing focus on a window" (community.norton.com, Dec 24, 2024)
4. "Norton becomes active for a moment and steals focus / Nortonがフォーカスを奪う" (community.norton.com, July 10, 2025) — Japanese
5. "Norton360 Makes Keyboard unusable -- constantly grabs focus" (community.norton.com, Sep 22, 2025) — most active, 4+ pages
6. "Focus window issue Norton 25.10" (community.norton.com, Oct 15, 2025) — multi-page
7. "NortonUI causing disruptive Hiccups" (community.norton.com, Nov 26, 2025)
8. "NortonUI.exe Silently Crashing in the Background" (community.norton.com, Dec 16, 2025)
9. "Nortonが不定期かつ一瞬だけアクティブになり、フォーカスを奪っていく" (community.norton.com, Feb 8, 2026)

No permanent fix has been delivered in any of these versions.

---

## Recommended Fix

1. **Remove `--disable-features=CalculateNativeWinOcclusion`** from all CEF launch parameters, or implement proper occlusion-aware window management that prevents hidden windows from requesting foreground activation.
2. **Replace foreground window activation** in the background timer callback with a non-UI IPC mechanism (named pipes, WMI, COM, or Windows messages) for status checks and telemetry.
3. **Update the CEF/Chromium engine** from version 91 to a current release. Chromium 91 reached end-of-life in 2021 and contains known security vulnerabilities.
4. **Ensure `SetForegroundWindow` or equivalent Win32 API calls** are not invoked on hidden/minimized/occluded windows during background operations.

Detailed code-level guidance with C++ examples is available in [`docs_for_norton_devs/Norton360_Developer_Fix_Guide.md`](docs_for_norton_devs/Norton360_Developer_Fix_Guide.md).

---

## Workaround

Killing NortonUI.exe while leaving NortonSvc.exe running eliminates the issue entirely. Core antivirus protection, firewall (afwServ.exe), and VPN (VpnSvc.exe) continue to function without NortonUI. Users lose the system tray icon and real-time visual notifications but retain full protection.

To make this persistent across reboots:
```powershell
# Disable NortonUI autostart (run as admin)
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'NortonUI.exe' -Value ''

# To re-enable later:
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'NortonUI.exe' -Value '"C:\Program Files\Norton\Suite\AvLaunch.exe" /gui'
```

---

## Follow-Up: Test of UI v1.0.138 (May 2, 2026)

| Metric | Before (UI < 1.0.138) | After (UI 1.0.138) | Change |
|---|---|---|---|
| Total focus events | 420 | 40 | -90% |
| NortonUI events | 178 | 40 | -78% |
| **Invisible CefHeaderWindow activations** | **178** | **20** | **-89%** |
| Average interval | ~60s constant | ~85s variable | slower & jittery |
| StdDev of intervals | near zero | 65.5s | now jittered |
| `--disable-features=CalculateNativeWinOcclusion` | present | **still present** | unchanged |

### What was fixed
Norton reduced the polling frequency of the background timer and added jitter to the interval.

### What was NOT fixed
Every visible `GeniumWindow` activation is still followed 30-150 milliseconds later by an invisible `CefHeaderWindow` activation:

```
[22:53:08.028] PID=15024 NortonUI | Class=GeniumWindow      | Visible=True
[22:53:08.068] PID=15024 NortonUI | Class=CefHeaderWindow   | Visible=False  <-- 40ms later
[22:54:46.340] PID=15024 NortonUI | Class=GeniumWindow      | Visible=True
[22:54:46.391] PID=15024 NortonUI | Class=CefHeaderWindow   | Visible=False  <-- 51ms later
... pattern repeats for all 20 timer cycles
```

The fix appears to have been a targeted change to the timer's repeat interval, not a fix to the code path that activates an invisible CEF window when the timer fires. **This issue should remain open until the CEF occlusion handling is properly addressed.**

This is the **second** "fix that doesn't fix" — UI v1.0.111 (November 2025) had the same outcome, with users explicitly noting at the time that *"the only change was to delay the start of background operations and make the problem harder to reproduce rather than actually fixing the underlying bug."*

For the full v1.0.138 follow-up analysis, see [`docs_for_norton_devs/Norton360_FollowUp_v1.0.138.md`](docs_for_norton_devs/Norton360_FollowUp_v1.0.138.md). Raw logs available in [`logs/example_litebito_2026-05-02/`](https://github.com/litebito/windows-focus-steal-diagnostic/tree/main/logs/example_litebito_2026-05-02).

---

## Reproduction & Crowdsourced Data

The diagnostic tools and a structured logs directory for crowdsourced reproduction are available at:

https://github.com/litebito/windows-focus-steal-diagnostic

Other affected users can run the diagnostic tools, redact PII, and contribute their results — building a public, reproducible body of evidence across versions and configurations.

---

**Original date:** April 4, 2026
**Updated:** May 2, 2026 (added v1.0.138 follow-up + 18-month historical timeline)
