# Test Submission — litebito — 2026-04-04

## Environment

- **OS:** Windows 11 Pro 24H2
- **Norton 360 AV module version:** 26.3.10886.0
- **Norton UI version:** unknown (between 1.0.111 and 1.0.138 — Norton doesn't expose this clearly in older versions)
- **Tamper protection:** enabled (had to be temporarily disabled to kill NortonUI for the comparison test)
- **Norton Silent Mode:** off
- **Other notable software running:** PowerToys, AMD Radeon Software, Loupedeck — all confirmed NOT to be the cause via this same data

## Test details

- **Test duration:** 30 minutes
- **What I was doing during the test:** normal desktop use — Chrome browsing, terminal work, occasional WhatsApp, Calculator
- **Subjective observation:** focus stealing felt constant — typing was disrupted regularly, display would never sleep
- **Display sleep behavior:** display NEVER slept while NortonUI was running; slept normally after killing NortonUI

## Files in this folder

- `FocusStealLog.csv` — main event log with NortonUI running (420 events)
- `FocusStealDetail.txt` — detail log
- `FocusStealLog_NoNorton.csv` — clean baseline after killing NortonUI (23 events)
- `FocusStealDetail_NoNorton.txt` — detail log of the clean run
- `NortonDiagReport_20260404_202121.txt` — Norton state inventory (processes, scheduled tasks, registry, version info)

## Key numbers from this run

**With NortonUI running:**
- Total focus change events: **420**
- NortonUI events: **178 (42% of total)**
- Invisible window activations: **178 (100% of NortonUI events)**
- Window classes: `CefHeaderWindow` (79 events), `Chrome_WidgetWin_0` (99 events)
- Approximate interval: ~60 seconds, near-zero jitter
- Periodicity verdict: STRONG (clearly timer-driven)

**With NortonUI killed (NortonSvc protection still running):**
- Total focus change events: **23**
- NortonUI events: **0**
- Invisible window activations: **0**
- All 23 events were legitimate user-initiated window switches

This A/B comparison conclusively identifies NortonUI.exe as the sole cause.

## Personal observations

This was the original investigation that started this entire repo. The pattern was so consistent — every minute, like clockwork — that once I correlated the timing with NortonUI it was obvious. The bug had been present for months before I started seriously investigating, possibly longer.

What surprised me was how completely killing NortonUI eliminated the issue while keeping all of Norton's actual protection running. That tells you the entire UI layer is non-essential to the security function.

## Redaction confirmation

- [x] Ran `RedactLogs.ps1` against all CSV and TXT files before committing
- [x] Manually reviewed the redacted files
- [x] Computer name and Windows username replaced with `REDACTED-PC` and `REDACTED`
