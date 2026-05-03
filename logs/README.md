# Diagnostic Logs — Crowdsourced Reproduction Data

This folder contains diagnostic logs from real users running `FocusStealDiagnostic.ps1` and `NortonFocusStealFix.ps1` on their systems. The goal is to build a **public, reproducible body of evidence** documenting the Norton 360 focus-steal bug across versions, configurations, and over time.

## Why crowdsource the logs?

A single user's report can be dismissed as edge-case or environmental. **Multiple independent reports with consistent data patterns cannot.** The more reproductions we collect:

- The harder it is for Norton/Gen Digital to claim the bug doesn't exist or is environmental
- The clearer the picture becomes of which versions are affected and to what degree
- The easier it is for fellow users to compare their own data against established baselines
- The stronger the case for a proper fix

## Folder structure

Each contributor gets their own subfolder, named with their GitHub username and the test date:

```
logs/
  example_litebito_2026-04-04/    <- original baseline (UI before 1.0.138)
  example_litebito_2026-05-02/    <- follow-up after Norton's "fix" claim
  yourname_YYYY-MM-DD/             <- your contribution
```

Inside each folder, you typically have:
- `FocusStealLog_*.csv` — full focus event data
- `FocusStealDetail_*.txt` — human-readable summary
- `NortonDiagReport_*.txt` — Norton process/scheduled-task/registry inventory
- `README.md` — context (Norton version, OS version, how long the test ran, observations)

## How to contribute your logs

### 1. Run the diagnostic tools

```powershell
# Inventory Norton state
.\NortonFocusStealFix.ps1

# Capture 30 minutes of focus events
.\FocusStealDiagnostic.ps1 -DurationMinutes 30
```

### 2. Redact your personal data

The logs contain your Windows username and computer name in process paths and command lines, **and many WindowTitle fields contain sensitive information** — Chrome tab titles, document names you have open, email subject lines, chat conversation names, and so on. **Always redact before publishing.** A helper script is included:

```powershell
# Run from the repo root, against the logs you generated
.\scripts\RedactLogs.ps1 -Path "C:\System\FocusStealLog_*.csv"
.\scripts\RedactLogs.ps1 -Path "C:\System\FocusStealDetail_*.txt"
.\scripts\RedactLogs.ps1 -Path "C:\System\NortonDiagReport_*.txt"

# Or in-place (overwrites originals - use with care):
.\scripts\RedactLogs.ps1 -Path "C:\System\*.csv" -InPlace
```

The script does three layers of cleaning:

**1. String redaction** — replaces:
- Your Windows username (e.g. `jdoe`)
- Your full display name from your account profile (e.g. `John Doe`)
- Your user profile folder name (e.g. `C:\Users\J. Doe\...`)
- Your computer name (e.g. `MYPC42`)
- Anything you pass via `-ExtraStrings @("MyHomeNetwork", "OtherSecret")`

**2. WindowTitle scrubbing** — replaces the WindowTitle field with `[REDACTED-TITLE]` for processes that frequently leak private info, while keeping the row's process name, window class, visibility flag, and timing data intact (so the focus-steal evidence is preserved). Default scrubbed processes include:

- Browsers: chrome, firefox, msedge, opera, brave, vivaldi, safari, arc, etc.
- Office: winword, excel, powerpnt, outlook, onenote, msaccess, mspub, visio, project, teams
- Mail: thunderbird, mailbird, em_client
- Chat: whatsapp, discord, slack, telegram, signal, zoom, webex
- IDEs/editors: code, cursor, devenv, rider, idea, pycharm, webstorm, notepad++, sublime_text
- Notes/PDF: obsidian, notion, evernote, joplin, acrobat, foxitreader
- Misc: explorer, cmd, powershell, windowsterminal

You can override with `-ScrubTitlesFor @(...)` or disable by passing an empty array.

**3. Optional line/row removal** — for cases where even the process name or window class is too revealing, you can drop entire rows:

```powershell
# Remove all rows for a specific process entirely
.\scripts\RedactLogs.ps1 -Path ".\logs\*" -DropLinesFor @("MyInternalTool")

# Remove any line containing a specific substring
.\scripts\RedactLogs.ps1 -Path ".\logs\*" -DropLinesMatching @("InternalDomain.local")
```

**Always review the output before pushing!** Open the redacted files and search for any remaining personal info (email addresses, license keys, IP addresses on local networks, network shares, etc.).

### 3. Add a small README

Create a `README.md` in your log folder describing the test. Use the [`_template/README.md`](_template/README.md) as a starting point.

### 4. Open a pull request

Fork the repo, add your folder under `logs/`, and open a PR. Include in the PR description:
- Date of the test
- Norton AV module version + UI version
- Windows version
- One sentence: did you observe focus stealing during the test? Yes / No / Sometimes

## Examples

- [`example_litebito_2026-04-04/`](example_litebito_2026-04-04/) — original baseline showing 178 invisible NortonUI focus events in 30 minutes (42% of all events) with AV module 26.3.10886.0
- [`example_litebito_2026-05-02/`](example_litebito_2026-05-02/) — follow-up after Norton released UI v1.0.138, showing the bug was reduced (78% fewer events) but not actually fixed (`CalculateNativeWinOcclusion` flag still present, invisible CefHeaderWindow activations still occurring on every timer tick)

## Privacy commitment

If you spot any personal information in someone's logs (yours or another contributor's), please open an issue immediately and we will redact and force-push to remove it from history.
