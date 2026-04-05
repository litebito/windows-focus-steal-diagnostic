# Norton 360 NortonUI.exe Focus-Steal Bug - Deep Diagnostic Analysis and Confirmed Root Cause

**TL;DR: Norton 360's NortonUI.exe uses an outdated Chromium 91 CEF engine with a misconfigured flag (`--disable-features=CalculateNativeWinOcclusion`) that causes its invisible background windows to steal foreground focus approximately every 60 seconds. This prevents display sleep and disrupts all user input. Killing NortonUI.exe completely eliminates the problem while Norton's core protection (NortonSvc.exe) continues running unaffected. This bug has been reported since late 2024 and remains unfixed as of version 26.3.10886.0 (March 2026).**

\---

## The Problem

My active window would lose focus for 1-2 seconds at regular intervals. Typing would be interrupted, games would pause, and my display would never go to sleep due to the idle timer being constantly reset. The earlier tool FocusLogger pointed to `explorer.exe` with a window class of "MSCTFIME UI" (the Text Services Framework IME), but that was a red herring - MSCTFIME was being *triggered* by something else.

## The Investigation

I built a custom PowerShell diagnostic tool using `SetWinEventHook` on `EVENT\\\_SYSTEM\\\_FOREGROUND` to capture every focus change with full process details, including process path, command line, parent process, window class, visibility state, and precise timestamps.

### Test 1: Normal Operation (with NortonUI running)

After monitoring for \~30 minutes of normal use:

|Metric|Value|
|-|-|
|Total focus events|420|
|NortonUI events|**178 (42%)**|
|NortonUI events on invisible windows|**178 (100%)**|
|Idle/PID=0 events (deactivation)|134|
|Legitimate user window switches|\~108|

The pattern was clockwork. Every \~60 seconds:

1. Active window deactivates (shows as PID=0 / Idle)
2. NortonUI.exe (PID 22188) activates an **invisible** `CefHeaderWindow` with title "Norton 360"
3. NortonUI switches to an invisible `Chrome\\\_WidgetWin\\\_0` window
4. Focus returns to the user's previous window

### Test 2: NortonUI Killed (protection still running via NortonSvc)

After stopping NortonUI.exe (had to disable Norton's tamper protection first):

|Metric|Value|
|-|-|
|Total focus events|**23**|
|NortonUI events|**0**|
|Invisible window events|**0**|
|All events|Legitimate user-initiated switches only|

**Clean. Zero phantom focus steals.**

## Root Cause Analysis

The NortonUI.exe process tree revealed the technical cause. The main process launches with `/nogui` and spawns CEF child processes (GPU, network, storage) with these critical flags:

```
--disable-features=CalculateNativeWinOcclusion
```

This Chromium flag **disables window occlusion detection**, which means CEF doesn't know its windows are hidden/occluded. When the internal timer fires (likely a status check, telemetry heartbeat, or notification poll), CEF activates its windows into the foreground because occlusion detection is turned off - it doesn't realize they should stay in the background.

Additional details from the command line:

* **Chromium 91** engine (from 2021!) - massively outdated
* User agent string contains "Avastium" (legacy Avast branding from the Norton/Avast merger)
* Running with `--no-sandbox` (twice!)
* GPU process forced to SwiftShader software rendering

## Environment

* **OS:** Windows 11 Pro
* **Norton version:** 26.3.10886.0 (Norton 360, updated March 31, 2026)
* **NortonUI.exe:** Spawns 4 processes (main `/nogui` + GPU + network + storage child processes)
* **All invisible:** Every single NortonUI focus event was on a window with `IsVisible=False`

## Known Issue

This is NOT an isolated case. Multiple threads on Norton Community document the same bug going back to late 2024:

* "Norton randomly making my window lose focus?" (Dec 2024, multi-page thread)
* "NortonUI causing disruptive Hiccups" (Nov 2025) - user reports focus steal every 30 seconds
* "Focus window issue Norton 25.10" (Oct 2025)
* "Norton360 Makes Keyboard unusable -- constantly grabs focus" (Sep 2025) - describes the system becoming "completely unusable"
* A Japanese-language report of the same issue

Users have reported this across Norton versions 24.x, 25.8, 25.9, 25.10, 25.11, 25.12, and now 26.3. Norton has not fixed it despite over a year of reports.

## Workaround

**Kill NortonUI.exe** - Norton's core AV engine (NortonSvc.exe), firewall (afwServ.exe), and VPN (VpnSvc.exe) all run as independent services. They do NOT need NortonUI to function. You lose the tray icon and real-time visual notifications, but protection continues.

Steps:

1. Open Norton 360 > Settings > Administrative Settings / Product Security
2. Temporarily disable Tamper Protection
3. In an elevated PowerShell: `Stop-Process -Name "NortonUI" -Force`
4. Re-enable Tamper Protection

To prevent NortonUI from starting at boot:

```powershell
# Disable autostart (run as admin)
Set-ItemProperty -Path 'HKLM:\\\\SOFTWARE\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run' -Name 'NortonUI.exe' -Value ''

# To re-enable later:
Set-ItemProperty -Path 'HKLM:\\\\SOFTWARE\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\Run' -Name 'NortonUI.exe' -Value '"C:\\\\Program Files\\\\Norton\\\\Suite\\\\AvLaunch.exe" /gui'
```

## What Norton / Gen Digital Should Fix

1. **Remove `--disable-features=CalculateNativeWinOcclusion`** from the CEF launch flags, or replace it with proper occlusion-aware window management
2. **Update CEF from Chromium 91 to a modern version** - they're 5 years behind
3. **Don't call `SetForegroundWindow` or equivalent** on invisible/background windows during timer callbacks
4. **The background status check should use non-UI mechanisms** (WMI, named pipes, IPC) instead of activating CEF windows

Hope this helps others who are losing their minds over this. Happy to share the diagnostic PowerShell script if anyone wants to verify on their system.

