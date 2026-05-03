# Norton 360 NortonUI.exe Focus-Steal Bug — Follow-Up Analysis (UI v1.0.138)

## Status: PARTIALLY ADDRESSED, NOT FIXED — Second time

**Date:** May 2, 2026
**Tested version:** Norton 360 AV module **26.4.10932.0**, UI version **1.0.138**, installer 26.4.10843.0

This is a follow-up to the [original bug report](../Norton360_FocusSteal_BugReport.md). Norton/Gen Digital indicated that the focus-stealing issue should be resolved in UI version 1.0.138. After installing this version and running the same diagnostic methodology, **the bug is reduced in frequency but remains structurally identical**.

**Importantly, this is the second time Norton has shipped a "fix" that only adjusts the timer interval without fixing the root cause.** The first was UI v1.0.111 in November 2025 — see the timeline below.

---

## Norton's pattern of incomplete fixes

| Date | UI Version | Outcome |
|---|---|---|
| Nov 13, 2025 | **1.0.111** (with AV 25.11.10580) | <br>Multiple users explicitly confirmed it did NOT fix the focus issue. One affected user wrote: *"It seems that the only change was to delay the start of background operations and make the problem harder to reproduce rather than actually fixing the underlying bug."* The issue was reduced in some scenarios but the core defect remained. |
| Apr 28, 2026 | **1.0.138** (with AV 26.4.10932) | Frequency reduced ~78%, jitter introduced — but every timer tick still produces an invisible `CefHeaderWindow` activation. The CalculateNativeWinOcclusion flag is still in the CEF command lines. Same pattern as v1.0.111: *symptom mitigation, not root-cause fix*. |

---

## Summary of v1.0.138 testing

| Metric | UI before fix (Apr 4) | UI v1.0.138 (May 2) | Change |
|---|---|---|---|
| AV module version | 26.3.10886.0 | 26.4.10932.0 | bumped |
| UI version | (not exposed in older versions) | 1.0.138 | new |
| Total focus events in 30 min | 420 | 40 | -90% |
| NortonUI events | 178 | 40 | -78% |
| Invisible CefHeaderWindow activations | 178 | 20 | -89% |
| Average interval between Norton events | ~60s (constant) | ~85s (variable) | slower & jittery |
| StdDev of intervals | near zero | 65.5s | now jittered |
| Min / Max interval | ~60s / ~60s | 0.03s / 284.25s | wider range |
| Periodicity verdict | STRONG (timer-driven) | weakened by jitter, **but burst pattern intact** | timer still present |
| Bursts (<500ms apart) | many | 20 (out of 40 events) | unchanged ratio |
| `--disable-features=CalculateNativeWinOcclusion` flag | present | **still present** | unchanged |

## What appears to have been fixed

Norton's UI v1.0.138 has **reduced the frequency** of the background timer firing and **introduced jitter** in the interval. The clean ~60-second clockwork pattern is gone. Total invisible activations dropped from 178 to 20 in a 30-minute window. This is a genuine improvement and users should notice fewer interruptions.

## What has NOT been fixed — the underlying defect

The core CEF window-occlusion bug is unchanged. Every single time NortonUI activates its `GeniumWindow`, ~30-150 milliseconds later it activates an invisible `CefHeaderWindow`. This pair fires together, every single time, in 20 out of 20 cycles observed:

```
[22:53:08.028] PID=15024 NortonUI | Class=GeniumWindow      | Visible=True
[22:53:08.068] PID=15024 NortonUI | Class=CefHeaderWindow   | Visible=False  <-- 40ms later
[22:54:46.340] PID=15024 NortonUI | Class=GeniumWindow      | Visible=True
[22:54:46.391] PID=15024 NortonUI | Class=CefHeaderWindow   | Visible=False  <-- 51ms later
[22:55:03.275] PID=15024 NortonUI | Class=GeniumWindow      | Visible=True
[22:55:03.307] PID=15024 NortonUI | Class=CefHeaderWindow   | Visible=False  <-- 32ms later
... and so on for all 20 timer cycles
```

The `GeniumWindow` class (apparently a Norton-internal frame window — perhaps related to "Gen Digital" branding) is now visible. But the **invisible CefHeaderWindow steal is still happening every time**, indicating the CEF browser is still being asked to activate even though there is no visible UI to render.

## Updated process tree (v26.4.10932 / UI 1.0.138)

```
NortonUI.exe /nogui                              [PID 15024 - main, 310MB]
  +-- NortonUI.exe --type=gpu-process            [PID 37468, 41.9MB]
  +-- NortonUI.exe --type=utility (storage)      [PID 37568, 7MB]
  +-- NortonUI.exe --type=utility (network)      [PID 37592, 15.4MB]
  +-- NortonUI.exe --type=renderer               [PID 70436, 150MB] *** NEW since April ***
```

The `--type=renderer` is new since the April test. This is the CEF child process that runs the Norton dashboard's HTML/JavaScript. It started ~4 hours after the main process, suggesting it's spawned on-demand (perhaps when notification content needs to be pre-rendered).

A new sibling process `aswEngSrv.exe` (Avast scanning engine, 308MB) is now also running alongside Norton's services, confirming further integration of the Avast/Norton codebases under Gen Digital.

## Updated CEF command-line analysis

The CEF child processes still launch with:

```
--disable-features=CalculateNativeWinOcclusion
```

This is the root cause flag from the original report. **It is still present in v1.0.138.** Until this flag is removed (or replaced with proper occlusion-aware handling), the underlying defect cannot be considered fixed — Norton has only reduced how often the buggy code path is exercised.

The user-agent string still reads:

```
Chrome/91.0.4472.101 ... Avastium (0.0.0) (Windows 10.0)
```

CEF/Chromium engine is still **Chromium 91** (released May 2021, EOL September 2021). No engine upgrade in v1.0.138.

## Stale component detected

`wsc_proxy.exe` (the Windows Security Center reporter) is still at version **23.1.38320.0 from 2024-11-26**, while every other Norton component is on 26.4.10932.0 from 2026-04-28. This is either an oversight or an intentional pin to an older WSC integration, but worth flagging.

## What this proves

1. Norton CAN modify the timer behavior (they reduced frequency and added jitter — twice, in 1.0.111 and 1.0.138).
2. Norton has NOT addressed the underlying invisible-window-activation defect in either patch.
3. The `CalculateNativeWinOcclusion` disable is still active.
4. Both fixes were almost certainly targeted changes to the timer's repeat interval, not a fix to the code path that activates an invisible CEF window when the timer fires.

The repeated pattern across two named patches over six months strongly suggests the development team is treating this as a "make it less noticeable" issue rather than a "find and fix the root cause" issue.

## What still needs to happen (unchanged from original report)

The fixes recommended in [`Norton360_Developer_Fix_Guide.md`](Norton360_Developer_Fix_Guide.md) all still apply:

1. **Remove `--disable-features=CalculateNativeWinOcclusion`** from the CEF launch flags
2. **Add `IsWindowVisible()` and `GetForegroundWindow()` checks** before any code that activates the CEF browser window from a timer callback
3. **Use Off-Screen Rendering (OSR)** for background CEF operations
4. **Replace the CEF-based timer with non-UI IPC** (named pipes, WMI, shared memory)
5. **Upgrade CEF/Chromium** from version 91 to a current LTS branch

Until at least #1 and #2 are implemented, the bug will continue to manifest, just less frequently each time Norton tweaks the timer.

## Reproduction

Anyone can reproduce this analysis using the public diagnostic tools:

```powershell
# 1. Inventory Norton's current state
.\NortonFocusStealFix.ps1

# 2. Capture 30 minutes of focus events
.\FocusStealDiagnostic.ps1 -DurationMinutes 30

# 3. Examine the Norton CEF Deep-Dive section in the output
```

Tools available at: https://github.com/litebito/windows-focus-steal-diagnostic

Raw logs from the May 2, 2026 test that produced this report: [`logs/example_litebito_2026-05-02/`](../logs/example_litebito_2026-05-02/)

Other users are encouraged to add their own logs to [`logs/`](../logs/) to build crowdsourced reproduction evidence.

## Conclusion

Norton 360 UI v1.0.138 should be treated as a **mitigation, not a fix** — and as the second instance of mitigation-without-fix in six months (after UI v1.0.111). Users who were heavily impacted by the original ~60-second focus steal will experience meaningful relief, but anyone working on tasks where even occasional focus loss is disruptive (typing-intensive work, gaming, full-screen video, presentations) will continue to encounter the issue. Display sleep is still affected.

The bug should remain open until the CEF occlusion handling is properly addressed at the architectural level. With 18+ months of accumulated user reports, two named UI patches that didn't fully address it, and clear technical evidence of the root cause flag still being present, this should be treated as a high-priority defect rather than a recurring "make it less annoying" task.