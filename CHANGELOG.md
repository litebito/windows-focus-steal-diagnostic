# Changelog

All notable changes to this project will be documented in this file.

## [1.2.0] - 2026-05-02

### Repository structure changes
- Added [`logs/`](logs/) directory for **crowdsourced reproduction data** with per-contributor subfolders, a contribution README, and a `_template/` for new submissions.
- Added [`scripts/RedactLogs.ps1`](scripts/RedactLogs.ps1) helper for stripping PII from logs before publishing. Three layers of redaction:
  - **String replacement** — Windows username, full display name, user profile folder name, computer name, plus any custom `-ExtraStrings`.
  - **WindowTitle scrubbing** — replaces `WindowTitle` field with `[REDACTED-TITLE]` for browsers (chrome, firefox, msedge, etc.), Office apps (winword, excel, outlook, teams), chat apps (whatsapp, slack, discord), IDEs (code, devenv, idea), and other typically-leaky processes. Preserves the row's process name, window class, visibility flag, and timing data so the focus-steal evidence remains intact. Configurable via `-ScrubTitlesFor`.
  - **Optional line/row removal** — `-DropLinesFor` for entire-process removal, `-DropLinesMatching` for substring-based removal.
- Added baseline example logs from April 4, 2026 (with NortonUI running, and a clean comparison after killing NortonUI) at `logs/example_litebito_2026-04-04/`. All Chrome/WindowsTerminal/etc. window titles in these example logs are scrubbed; Norton titles preserved as evidence.
- Added follow-up example folder for May 2, 2026 v1.0.138 test at `logs/example_litebito_2026-05-02/`.

### Diagnostic findings
- Researched the **18-month historical timeline** of this bug. Earliest known report dates to October 10, 2024 (Norton Community thread, Norton 24.x). The bug has persisted across at least 8 major AV-module versions and 2 named UI patches:
  - **UI v1.0.111** (November 13, 2025) — first "fix" attempt, explicitly confirmed by multiple users to NOT resolve the issue. Quote: *"the only change was to delay the start of background operations and make the problem harder to reproduce rather than actually fixing the underlying bug."*
  - **UI v1.0.138** (April 28, 2026) — second "fix" attempt. Frequency reduced 78%, jitter introduced, but invisible `CefHeaderWindow` activations still occur on every timer tick. CalculateNativeWinOcclusion flag still present. Same pattern as v1.0.111.
- Both bug reports and the developer fix guide addendum updated with the full historical timeline.

### Documentation updates
- `README.md` — added timeline note, link to crowdsourced logs, link to redaction script, replaced broken `docs/...` paths with correct `docs_for_norton_devs/...`.
- `Norton360_FocusSteal_BugReport.md` — major rewrite incorporating both April baseline and May v1.0.138 follow-up data, full historical timeline with version-by-version status, and new sections on the recurring "fix that doesn't fix" pattern.
- `Norton_BugReport_Communities.md` — community post updated with full 18-month timeline, v1.0.111 precedent, and v1.0.138 follow-up data.
- `docs_for_norton_devs/Norton360_FollowUp_v1.0.138.md` — NEW. Detailed follow-up analysis of v1.0.138, including the v1.0.111 precedent and the GeniumWindow → CefHeaderWindow pattern.
- `docs_for_norton_devs/Norton360_Developer_Fix_Guide_Addendum.md` — NEW. Notes that none of the 5 original recommendations were implemented in v1.0.138 and the same is true for v1.0.111. Added a security exposure note (Chromium 91 + --no-sandbox).
- Removed `Norton360_Developer_Readme.md` (older draft duplicate of README.md).

### FocusStealDiagnostic.ps1 (v1.2)
- **Default log location changed** from `$env:USERPROFILE\Desktop\` to `$PSScriptRoot` (the folder where the script lives) — logs always land predictably next to the script. Override still possible via `-LogPath` / `-DetailLogPath`.
- Added `volatile bool ShutdownRequested` flag in C# — fixes the bug where callbacks continued firing after the script stopped.
- Wrapped log writes in try/catch to prevent shutdown crashes.
- Captures process `ProductVersion`, `FileVersion`, and `CompanyName` per event (visible in CSV and live console output).
- Added `SecondsSincePrevious` column to CSV for easier interval analysis.
- Live console now shows `dt=X.XXs` for each event.
- Added per-suspect timing analysis with periodicity verdict (STRONG / MODERATE / NONE based on StdDev/Avg ratio).
- Added Norton CEF deep-dive section in summary (version, % of events, % invisible, breakdown by window class).
- Added burst detection (events <500ms apart).
- Added 5-minute heartbeat during monitoring.
- Added Norton CEF window class detection (`CefHeaderWindow`, `Chrome_WidgetWin_0`, `Chrome_WidgetWin_1`, `Chrome_RenderWidgetHostHWND`, `GeniumWindow`).

### NortonFocusStealFix.ps1 (v1.1)
- **Default report location changed** to `$PSScriptRoot` (script folder) as primary, with Desktop and `%TEMP%` as fallbacks. Override possible via `-ReportPath`.
- Fixed `Get-WinEvent -FilterHashtable` error (wildcards in `ProviderName` aren't supported by that parameter; replaced with post-filter via `Where-Object`).
- Fixed process filter precedence around `-or` / `-and` operators.
- Added per-process version display inline.
- Added extended version inventory across all 9 Norton EXEs.
- Added smarter kill detection that distinguishes tamper-protection-block (same PIDs) from service-watchdog respawn (new PIDs).
- Added fallback save paths (`C:\System` → Desktop → `%TEMP%`).
- Fixed PowerShell parse error caused by stray backtick-backslash escape in a registry-command example string.

## [1.1.0] - 2026-04-04

### Initial public release
- `FocusStealDiagnostic.ps1` (v1.1) — generic focus-steal monitoring tool using Win32 `SetWinEventHook`.
- `NortonFocusStealFix.ps1` (v1.0) — Norton-specific investigation and remediation tool.
- Initial Norton 360 bug report (UI before v1.0.138, AV module 26.3.10886.0).
- Developer fix guide for Gen Digital engineers.
- Community/Reddit post.
