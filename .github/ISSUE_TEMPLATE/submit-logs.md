---
name: Submit diagnostic logs
about: Share your Focus-Steal Diagnostic logs so we can document the Norton 360 (or other) focus-steal bug across more systems
title: "[LOGS] <Norton or app name> <version> — <YYYY-MM-DD>"
labels: ["logs"]
assignees: []
---

Thanks for contributing diagnostic data! This helps build a public, reproducible body of evidence.

**Before submitting:** please run [`scripts/RedactLogs.ps1`](../../scripts/RedactLogs.ps1) on your logs first — it removes your username, computer name, and browser/Office window titles. You can review the redacted files yourself before attaching them.

---

## Environment

- **OS:** <!-- Windows 10 / 11 — build number, edition -->
- **Software being investigated:** <!-- Norton 360 / AVG / other -->
- **Application version:** <!-- e.g. 26.4.10932.0 -->
- **UI / sub-component version (if applicable):** <!-- e.g. UI 1.0.138 -->
- **Other notable software running:** <!-- AMD/Nvidia overlays, PowerToys, Loupedeck, etc. -->

## Test details

- **Test duration:** <!-- e.g. 30 minutes -->
- **What I was doing during the test:** <!-- typing, idle, browsing, gaming, etc. -->
- **Subjective observation:** <!-- Did focus get stolen during the test? -->
- **Display sleep behavior:** <!-- Did your display sleep when idle? -->

## Key numbers from the script's summary

- Total focus change events: <!-- ___ -->
- Suspect process events: <!-- ___ (___% of total) -->
- Invisible window activations: <!-- ___ -->
- Average interval between suspect events: <!-- ___s -->
- Periodicity verdict: <!-- STRONG / MODERATE / NONE -->

## Affiliation disclosure

- [ ] I am submitting on my own behalf
- [ ] I am affiliated with the vendor of the software being investigated (please specify in the comments)
- [ ] I am affiliated with another antivirus / security vendor (please specify)

## Redaction confirmation

- [ ] I ran `RedactLogs.ps1` against all CSV and TXT files
- [ ] I manually reviewed the redacted files and found no remaining personal information
- [ ] I am OK with these logs being added to the public `logs/` directory of this repository

## Attachments

Drag and drop your redacted log files below. GitHub Issues accept ZIPs if your file types aren't directly allowed.

Typical files:
- `FocusStealLog_*.csv`
- `FocusStealDetail_*.txt`
- `NortonDiagReport_*.txt` (if you ran the Norton-specific script)

<!-- Drag files here -->
