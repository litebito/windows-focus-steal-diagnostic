# Test Submission — litebito — 2026-05-02 (UI v1.0.138 follow-up)

## Environment

- **OS:** Windows 11 Pro 24H2
- **Norton 360 AV module version:** 26.4.10932.0 (build 26.4.10932.0)
- **Installer version:** 26.4.10843.0
- **Norton UI version:** **1.0.138**
- **Virus definitions:** 260502-2
- **Tamper protection:** enabled
- **Norton Silent Mode:** off (not available as a tray menu option in this version — only "mute notifications" for max 1 day)
- **Other notable software running:** PowerToys, AMD Radeon Software, Loupedeck — same as April

## Test details

- **Test duration:** 30 minutes
- **What I was doing during the test:** normal use, deliberately ran the diagnostic to test if Norton's UI 1.0.138 fixed the issue
- **Subjective observation:** focus stealing is noticeably less frequent than April but still happens — typing is no longer constantly interrupted but it's not gone
- **Display sleep behavior:** still does not sleep reliably; idle timer keeps getting reset

## Files to be uploaded

These files should be uploaded by the repo owner after a test run:
- `FocusStealLog_UI1.0.138.csv` — main event log under v1.0.138
- `FocusStealDetail_UI1.0.138.txt` — detail log
- `NortonDiagReport_20260502_*.txt` — Norton state inventory

## Key numbers from this run

- Total focus change events: **40**
- NortonUI events: **40 (100% of total — nothing else stole focus)**
- Invisible CefHeaderWindow activations: **20 (50% of NortonUI events)**
- Window classes: `GeniumWindow` (20 events, visible), `CefHeaderWindow` (20 events, invisible)
- Approximate interval: ~85 seconds (variable, StdDev 65.5s, range 16-284s)
- Periodicity verdict: timer still timer-driven, just with reduced frequency and added jitter
- `--disable-features=CalculateNativeWinOcclusion` flag: **still present**
- Chromium engine: **still version 91**

## Comparison to April baseline

| Metric | April 4 (no UI fix) | May 2 (UI 1.0.138) | Change |
|---|---|---|---|
| Total focus events | 420 | 40 | -90% |
| NortonUI events | 178 | 40 | -78% |
| Invisible activations | 178 | 20 | -89% |
| Avg interval | ~60s constant | ~85s variable | slower + jittery |
| Root cause flag | present | **still present** | unchanged |

## Personal observations

Norton's UI v1.0.138 reduces the frequency of the timer firing and adds jitter, but does not address the underlying defect. Every visible `GeniumWindow` activation is still followed within 30-150 ms by an invisible `CefHeaderWindow` activation — exactly the same pattern as before, just less often. This is the second time this has happened (UI v1.0.111 in November 2025 had the same "fix that doesn't fix" outcome).

This is mitigation, not a fix.

## Redaction confirmation

- [x] Ran `RedactLogs.ps1` against all CSV and TXT files before committing
- [x] Manually reviewed the redacted files
