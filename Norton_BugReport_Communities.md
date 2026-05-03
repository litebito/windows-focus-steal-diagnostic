# Norton 360 NortonUI.exe Focus-Steal Bug - Diagnostic Analysis, Confirmed Root Cause, and v1.0.138 Follow-Up

**TL;DR: Norton 360's NortonUI.exe uses an outdated Chromium 91 CEF engine with a misconfigured flag (`--disable-features=CalculateNativeWinOcclusion`) that causes its invisible background windows to steal foreground focus. This prevents display sleep and disrupts all user input. Killing NortonUI.exe completely eliminates the problem while Norton's core protection (NortonSvc.exe) continues running unaffected. Norton's UI v1.0.138 (May 2026) reduced the frequency by ~78% but did NOT fix the underlying defect — invisible CefHeaderWindow activations still occur and the buggy CEF flag is still in use.**

---

https://github.com/litebito/windows-focus-steal-diagnostic/tree/main

---

## The Problem

My active window would lose focus for 1-2 seconds at regular intervals. Typing would be interrupted, games would pause, and my display would never go to sleep due to the idle timer being constantly reset. The earlier tool FocusLogger pointed to `explorer.exe` with a window class of "MSCTFIME UI" (the Text Services Framework IME), but that was a red herring - MSCTFIME was being *triggered* by something else.

## The Investigation

I built a custom PowerShell diagnostic tool using `SetWinEventHook` on `EVENT_SYSTEM_FOREGROUND` to capture every focus change with full process details, including process path, command line, parent process, window class, visibility state, and precise timestamps.

### Test 1: Normal Operation (with NortonUI running, AV module 26.3.10886.0 — April 2026)

After monitoring for ~30 minutes of normal use:

| Metric | Value |
|--------|-------|
| Total focus events | 420 |
| NortonUI events | **178 (42%)** |
| NortonUI events on invisible windows | **178 (100%)** |
| Idle/PID=0 events (deactivation) | 134 |
| Legitimate user window switches | ~108 |

The pattern was clockwork. Every ~60 seconds:

1. Active window deactivates (shows as PID=0 / Idle)
2. NortonUI.exe (PID 22188) activates an **invisible** `CefHeaderWindow` with title "Norton 360"
3. NortonUI switches to an invisible `Chrome_WidgetWin_0` window
4. Focus returns to the user's previous window

### Test 2: NortonUI Killed (protection still running via NortonSvc)

After stopping NortonUI.exe (had to disable Norton's tamper protection first):

| Metric | Value |
|--------|-------|
| Total focus events | **23** |
| NortonUI events | **0** |
| Invisible window events | **0** |
| All events | Legitimate user-initiated switches only |

**Clean. Zero phantom focus steals.** Display started going to sleep again as expected.

## Root Cause Analysis

The NortonUI.exe process tree revealed the technical cause. The main process launches with `/nogui` and spawns CEF child processes (GPU, network, storage) with these critical flags:

```
--disable-features=CalculateNativeWinOcclusion
```

This Chromium flag **disables window occlusion detection**, which means CEF doesn't know its windows are hidden/occluded. When the internal timer fires (likely a status check, telemetry heartbeat, or notification poll), CEF activates its windows into the foreground because occlusion detection is turned off - it doesn't realize they should stay in the background.

Additional details from the command line:

- **Chromium 91** engine (from 2021!) - massively outdated
- User agent string contains "Avastium" (legacy Avast branding from the Norton/Avast merger)
- Running with `--no-sandbox` (twice!)
- GPU process forced to SwiftShader software rendering

---

## Update — May 2, 2026: Norton UI v1.0.138 Follow-Up

After Norton/Gen Digital released UI v1.0.138 (AV module 26.4.10932.0) and indicated the issue should be resolved, I re-tested with the same methodology.

### Test 3: AV module 26.4.10932.0 / UI v1.0.138 (May 2026)

| Metric | Value |
|--------|-------|
| Total focus events | 40 |
| NortonUI events | 40 (100% of all events) |
| **Invisible CefHeaderWindow activations** | **20 (50% of NortonUI events)** |
| Average interval | ~85 seconds (variable, StdDev 65.5s, range 16-284s) |

**Comparison:**

| Metric | Before (UI < 1.0.138) | After (UI 1.0.138) | Change |
|---|---|---|---|
| NortonUI events in 30 min | 178 | 40 | -78% |
| Invisible activations | 178 | 20 | -89% |
| Average interval | ~60s constant | ~85s variable | slower + jittery |
| `CalculateNativeWinOcclusion` flag | present | **STILL present** | unchanged |
| Chromium 91 engine | yes | **STILL yes** | unchanged |

### What Norton fixed

They reduced the polling frequency of the background timer and added jitter. Total invisible activations dropped 89%.

### What Norton did NOT fix

The underlying defect remains. Every visible `GeniumWindow` activation is still followed 30-150ms later by an invisible `CefHeaderWindow` activation:

```
[22:53:08.028] PID=15024 NortonUI | Class=GeniumWindow      | Visible=True
[22:53:08.068] PID=15024 NortonUI | Class=CefHeaderWindow   | Visible=False  <-- 40ms later, INVISIBLE
[22:54:46.340] PID=15024 NortonUI | Class=GeniumWindow      | Visible=True
[22:54:46.391] PID=15024 NortonUI | Class=CefHeaderWindow   | Visible=False  <-- 51ms later, INVISIBLE
... pattern repeats every cycle
```

Norton's fix appears to be a targeted change to the timer interval, not a fix to the code path that activates an invisible CEF window. The `CalculateNativeWinOcclusion` flag is still present in the CEF child process command lines. The Chromium engine is still version 91.

**This is mitigation, not a fix.** Users heavily impacted by the original ~60-second steal will see meaningful relief, but anyone working on tasks where even occasional focus loss is disruptive (typing-intensive work, gaming, presentations) will continue to encounter the issue. Display sleep is still affected.

---

## Environment

- **OS:** Windows 11 Pro 24H2
- **Norton versions tested:** 26.3.10886.0 (April 2026) and 26.4.10932.0 / UI 1.0.138 (May 2026)
- **NortonUI.exe:** Spawns 4-5 processes (main `/nogui` + GPU + network + storage + renderer in newer version)
- **All offending events:** On windows with `IsVisible=False`

## Known Issue — 18-Month Timeline

This is NOT an isolated case. Multiple threads on Norton Community document the same bug going back to **October 2024**:

- **Oct 10, 2024** — "Windows 10 Cursor looses focus while typing since install of new Norton version?" (Norton 24.x) — earliest known report
- **Dec 20, 2024** — "Norton randomly making my window lose focus?" (multi-page thread)
- **Dec 24, 2024** — "Possibly NllToolsSvc.exe causes loosing focus on a window"
- **Jul 10, 2025** — Japanese-language report identifies CNortonTrayIcon in NortonUI.exe (Norton 25.6.10221)
- **Sep 22, 2025** — "Norton360 Makes Keyboard unusable -- constantly grabs focus" (Norton 25.9.10453) — 4+ pages, the most active thread, described as making Windows 11 systems "completely unusable"
- **Oct 15, 2025** — "Focus window issue Norton 25.10" (multi-page)
- **Nov 13, 2025** — Norton ships **UI v1.0.111**, the first named "fix". Multiple users explicitly confirm it does NOT resolve the issue. One affected user: *"the only change was to delay the start of background operations and make the problem harder to reproduce rather than actually fixing the underlying bug."*
- **Nov 26, 2025** — "NortonUI causing disruptive Hiccups" (focus steal every 30 seconds)
- **Dec 16, 2025** — "NortonUI.exe Silently Crashing in the Background"
- **Feb 8, 2026** — Japanese thread "Nortonが不定期かつ一瞬だけアクティブになり、フォーカスを奪っていく"
- **Apr 28, 2026** — Norton ships **UI v1.0.138**, the second named "fix". Reduces frequency 78% but invisible CefHeaderWindow activations still occur on every timer tick. CalculateNativeWinOcclusion flag still present. Same pattern as v1.0.111.

Affected versions across all reports: 24.x, 25.6, 25.8, 25.9.10453, 25.10, 25.11.10580 (UI 1.0.111), 25.12.10659, 26.1, 26.2.10802, 26.3.10886, 26.4.10932 (UI 1.0.138).

**The "fix that doesn't fix" pattern has now happened twice.** Both UI patches reduced symptom frequency without addressing the root cause flag in the CEF configuration.

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
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'NortonUI.exe' -Value ''

# To re-enable later:
Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'NortonUI.exe' -Value '"C:\Program Files\Norton\Suite\AvLaunch.exe" /gui'
```

## What Norton / Gen Digital Should Fix (Still Unaddressed in v1.0.138)

1. **Remove `--disable-features=CalculateNativeWinOcclusion`** from the CEF launch flags, or replace it with proper occlusion-aware window management
2. **Update CEF from Chromium 91 to a modern version** - they're 5 years behind
3. **Don't call `SetForegroundWindow` or equivalent** on invisible/background windows during timer callbacks
4. **The background status check should use non-UI mechanisms** (WMI, named pipes, IPC) instead of activating CEF windows

Hope this helps others who are losing their minds over this. The diagnostic PowerShell script and full reports are public on the GitHub repo above — anyone can reproduce the analysis on their own machine.

**Reproduction logs are crowdsourced** — if you're affected, please run the diagnostic on your system, redact your logs (a helper script is included), and contribute them via PR. Every additional independent reproduction makes the bug harder for Norton to ignore. See the [`logs/`](https://github.com/litebito/windows-focus-steal-diagnostic/tree/main/logs) directory in the repo.