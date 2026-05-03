# Test Submission — [Your GitHub username] — [YYYY-MM-DD]

## Environment

- **OS:** Windows 10 / 11 (build #####, edition)
- **Norton 360 AV module version:** 26.x.xxxxx.x
- **Norton UI version:** 1.0.xxx
- **Virus definitions:** YYMMDD-N (from Norton > Help > About)
- **Tamper protection:** enabled / disabled during test
- **Norton Silent Mode:** on / off
- **Other notable software running:** (Loupedeck, AMD/Nvidia overlays, PowerToys, etc.)

## Test details

- **Test duration:** 30 minutes (or other)
- **What I was doing during the test:** typing in browser, light office work, idle, gaming, etc.
- **Subjective observation:** did focus get stolen during the test? Yes / No / A few times
- **Display sleep behavior:** did your display sleep when idle? Yes / No

## Files in this folder

- `FocusStealLog_<version>.csv` — main event log
- `FocusStealDetail_<version>.txt` — human-readable detail log
- `NortonDiagReport_*.txt` — Norton state at start of test
- (optional) `screenshot_*.png` — screenshots of relevant Norton UI dialogs

## Key numbers from this run

Fill these in from the script's summary output:

- Total focus change events: ___
- NortonUI events: ___ (___% of total)
- Invisible CefHeaderWindow activations: ___
- Average interval between NortonUI events: ___s
- Periodicity verdict: STRONG / MODERATE / NONE

## Personal observations

Anything not captured by the script — workflow impact, frustrations, things you tried that helped or didn't, support tickets you've opened, etc.

## Redaction confirmation

- [ ] I ran `RedactLogs.ps1` against all CSV and TXT files before committing
- [ ] I manually reviewed the redacted files and found no remaining personal info
- [ ] I removed any screenshots that contained PII (subscription keys, email addresses, etc.)