# About this project

This is a non-commercial, hobbyist research project. The author has no business relationship with any vendor referenced here, accepts no payment for this work, and is not available for hire in connection with it.

The repository contains a personal-use diagnostic toolkit and a body of technical evidence documenting a specific reproducible defect in a widely-deployed software product. It exists for three reasons:

1. **To help end users.** Anyone experiencing the same symptoms — windows losing focus mid-typing, displays that won't sleep, full-screen apps interrupted at regular intervals — can run the diagnostic, see what's actually happening on their system, and decide what to do about it.
2. **To document the problem accurately.** A single user's "I think this is broken" can be brushed off. A reproducible diagnostic with millisecond-precision evidence, available for anyone to verify on their own machine, cannot.
3. **To make the defect addressable.** The [`docs_for_norton_devs/`](docs_for_norton_devs/) folder contains a code-level analysis of the root cause and a step-by-step fix guide. The objective of publishing the analysis is to enable the defect to be corrected.

## Disclaimer

- The scripts in this repo are intentionally simple and inspectable. Read them before running them. They use only documented Windows APIs (`SetWinEventHook`, `GetWindowText`, `NtQueryInformationProcess`) and standard .NET classes. There is no obfuscation, no telemetry, no network access.
- The diagnostic tool is read-only — it observes window focus changes; it does not modify processes, registry, or files outside the log it writes.
- The Norton-specific helper (`NortonFocusStealFix.ps1`) can optionally kill the `NortonUI.exe` process, but only when explicitly invoked with `-KillNortonUI`. Norton's actual security services keep running.
- Use at your own risk. None of this is a substitute for legitimate antivirus protection.

## Statement of intent

This is **independent technical research**, conducted on the author's own equipment, on software the author has lawfully purchased and installed. Specifically:

- All findings are based on **reproducible behavior** that any reader can verify with the tools provided.
- No reverse-engineering of compiled code is performed. The analysis relies entirely on **publicly observable facts**: process command lines, window classes, foreground-window events, and timing data, all gathered through documented Windows APIs.
- All conclusions are framed as factual descriptions of observed behavior. The project does not speculate about motive or intent.
- Personal information is actively scrubbed from all logs before publication via [`scripts/RedactLogs.ps1`](scripts/RedactLogs.ps1). Where the project references real individuals, only their public posts on public forums are cited.

## Good-faith research and coordinated disclosure

This project follows the conventions of the security-research community:

- The defect documented here was first observable in publicly released production software, on the author's own system, during ordinary use. It was not discovered by exploiting access to internal systems, source code, or non-public information.
- Initial reports through the vendor's public support channels did not produce a fix; subsequent vendor-issued patches (UI v1.0.111, v1.0.138) reduced the symptom frequency without addressing the root cause. Public documentation followed only after these channels had been exercised.
- If the vendor of any software referenced in this repository wishes to coordinate a private fix-and-disclose timeline before further public updates, the author is willing to discuss that. Contact via a [private GitHub security advisory](https://github.com/litebito/windows-focus-steal-diagnostic/security/advisories/new) — see [SECURITY.md](SECURITY.md). A reasonable timeline for a complete fix, with a defined endpoint, is acceptable.
- Vendors, researchers, journalists, and regulators are welcome to verify any finding here independently. Issues and pull requests with technical corrections, additional evidence, or counter-evidence are accepted on the same terms as any other contribution. See [CONTRIBUTING.md](CONTRIBUTING.md).

---

# Windows Focus-Steal Diagnostic Tool

A PowerShell-based diagnostic tool for detecting and identifying applications that steal foreground window focus on Windows 10/11. Uses Win32 API hooks (`SetWinEventHook`) to monitor every focus change in real-time with full process forensics.

> **Status (May 2, 2026):** Norton 360 UI v1.0.138 partially addressed the focus-steal bug — frequency dropped roughly 78%, but the underlying CEF occlusion defect remains. See [`docs_for_norton_devs/Norton360_FollowUp_v1.0.138.md`](docs_for_norton_devs/Norton360_FollowUp_v1.0.138.md).

## Background

This tool was developed to investigate a persistent focus-stealing issue on Windows 11, which was traced to **Norton 360's NortonUI.exe** in April 2026. The full analysis and bug report is available in [`Norton360_FocusSteal_BugReport.md`](Norton360_FocusSteal_BugReport.md), and the developer fix guide is in [`docs_for_norton_devs/Norton360_Developer_Fix_Guide.md`](docs_for_norton_devs/Norton360_Developer_Fix_Guide.md).

While this tool was built for the Norton investigation, it is **generic and works for any focus-stealing application** — antivirus software, overlay tools, game launchers, input method editors, or any process that activates windows in the background. It also prevented my displays from going into sleep mode, because my desktop was always "active".

## What It Captures

For every foreground window change, the tool logs:

- **Process details** — PID, name, full path, command line, **product/file version, company name** (requires elevation)
- **Window details** — class name, title, visibility state, window styles, dimensions
- **Parent process** — name and PID (via `NtQueryInformationProcess`)
- **Owner window** — PID and class of the owning window
- **Timing** — millisecond-precision timestamps with `SecondsSincePrevious` for easy interval analysis
- **Suspect flagging** — known problematic applications are highlighted in real-time

## Key Features

- **Real-time color-coded console output** — RED for high-risk suspects, YELLOW for medium, MAGENTA for TSF/IME related events
- **Invisible window detection** — flags hidden windows stealing focus (the strongest indicator of a bug)
- **Per-suspect timing analysis with periodicity verdict** — calculates count, average, median, standard deviation, min, max intervals; flags STRONG / MODERATE periodicity (timer-driven steals) vs random
- **Norton CEF deep-dive** — dedicated section showing NortonUI version, % of all events, % invisible, breakdown by window class
- **Burst detection** — counts events <500ms apart (rapid-fire double activations)
- **5-minute heartbeat** — periodic progress updates during long monitoring runs
- **Suspect app database** — pre-configured detection for Norton, AVG/Avast, McAfee, Xbox Game Bar, Widgets and other known offenders
- **Pre-scan** — identifies suspect processes, CTF Loader state, and installed input methods before monitoring begins
- **Dual output** — CSV for data analysis + detailed text log for human review
- **No external dependencies** — pure PowerShell + inline C# (Win32 P/Invoke), no modules to install

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or later
- **Administrator** (elevated) recommended for full process details (command lines, parent PIDs)

## Usage

### Recommended workflow

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

# 1. (If you have Norton) - inventory Norton's state and version info
.\NortonFocusStealFix.ps1

# 2. Capture 30 minutes of focus events
.\FocusStealDiagnostic.ps1 -DurationMinutes 30
```

### Custom log location

```powershell
.\FocusStealDiagnostic.ps1 -DurationMinutes 15 -LogPath "C:\Temp\FocusLog.csv" -DetailLogPath "C:\Temp\FocusDetail.txt"
```

### Include scheduled task correlation

```powershell
.\FocusStealDiagnostic.ps1 -DurationMinutes 30 -IncludeScheduledTaskCorrelation
```

### Quiet mode (log only, minimal console output)

```powershell
.\FocusStealDiagnostic.ps1 -DurationMinutes 60 -Quiet
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-DurationMinutes` | int | 30 | How long to monitor (in minutes) |
| `-LogPath` | string | `<script folder>\FocusStealLog_<timestamp>.csv` | Path for the CSV output |
| `-DetailLogPath` | string | `<script folder>\FocusStealDetail_<timestamp>.txt` | Path for the detailed text log |
| `-IncludeScheduledTaskCorrelation` | switch | off | Also capture recent scheduled task executions |
| `-Quiet` | switch | off | Suppress most console output |

## Output Files

### CSV log (`FocusStealLog_*.csv`)

One row per focus change event with columns: Timestamp, EventType, **SecondsSincePrevious**, PID, ProcessName, ProcessPath, **ProductVersion**, **FileVersion**, **CompanyName**, WindowTitle, WindowClass, ParentPID, ParentProcess, IsVisible, WindowStyle, WindowRect, OwnerInfo, CommandLine.

`IsVisible=False` on a focus event is a major red flag — visible windows taking focus might be notifications, but invisible ones are almost always bugs.

### Detail log (`FocusStealDetail_*.txt`)

Human-readable report containing:
- System info and running suspect processes at start
- Real-time focus change log with timestamps and `dt=` intervals
- Summary with event counts by process and window class
- **Per-suspect timing pattern analysis** with periodicity verdict
- **Norton CEF deep-dive** (when NortonUI is present)
- List of invisible windows that stole focus

## Interpreting Results

### Red Flags

1. **Invisible windows stealing focus** (`IsVisible=False` on FOREGROUND events) — This is the strongest indicator. A visible window taking focus might be a notification; an invisible one is almost always a bug.
2. **Regular intervals** — If a process steals focus every N seconds with consistent timing, it has a background timer. The Per-Suspect Timing section flags this with a periodicity verdict.
3. **High event count from a single process** — If one process accounts for >20% of all focus events and you didn't interact with it, it's the culprit.
4. **PID=0 / Idle events preceding the steal** — A burst of Idle events followed by a background process indicates the active window was forcibly deactivated.

### Normal Behavior

- Focus events from applications you actively switched to (Chrome, Terminal, File Explorer)
- `Shell_TrayWnd` (taskbar) events when clicking the taskbar
- `WhatsApp` / messaging apps restoring from minimized state on incoming messages

## The Norton 360 Bug

This tool was created to diagnose a focus-stealing issue caused by Norton 360 (NortonUI.exe). Original (April 2026) findings:

- **178 out of 420 focus events (42%)** were from NortonUI.exe
- **100% of NortonUI events were on invisible windows**
- The pattern repeated every ~60 seconds with near-zero jitter
- Root cause: Norton's CEF (Chromium Embedded Framework) engine uses the `--disable-features=CalculateNativeWinOcclusion` flag, preventing it from recognizing its windows are hidden
- Norton ships with **Chromium 91** (from 2021), which is massively outdated
- Killing NortonUI.exe eliminated 100% of phantom focus events; Norton's core protection (NortonSvc.exe) continued functioning

After killing NortonUI, the focus stealing events were gone, and my displays went into sleep mode as expected after not using my workstation for 15 minutes.

### Update — May 2, 2026 (Norton 360 UI v1.0.138)

Norton/Gen Digital released UI v1.0.138 indicating the issue was resolved. After installing and re-testing:

- Focus-steal frequency dropped **78%** (from 178 to 40 NortonUI events in 30 minutes)
- Invisible CefHeaderWindow activations dropped **89%** (from 178 to 20)
- Average interval between events grew from ~60s to ~85s with high jitter (StdDev 65.5s)
- **The underlying defect remains:** every visible `GeniumWindow` activation is still followed within 30-150 ms by an invisible `CefHeaderWindow` activation
- The `--disable-features=CalculateNativeWinOcclusion` flag is **still present** in the CEF child process command lines
- CEF/Chromium engine is **still Chromium 91**

Norton's fix appears to have only adjusted the timer interval, not the underlying CEF occlusion handling. See [`docs_for_norton_devs/Norton360_FollowUp_v1.0.138.md`](docs_for_norton_devs/Norton360_FollowUp_v1.0.138.md) for the full follow-up analysis.

A detailed **developer fix guide** with root cause analysis, code-level fixes, and CEF configuration changes is available at [`docs_for_norton_devs/Norton360_Developer_Fix_Guide.md`](docs_for_norton_devs/Norton360_Developer_Fix_Guide.md). This document is intended for Norton/Gen Digital engineers and covers the specific CEF flags, timer patterns, Win32 API calls, and architectural changes needed to resolve the issue.

**This bug has been actively reported by users for at least 18 months** — the earliest known thread on Norton Community dates to October 10, 2024 (Norton 24.x). Across that time Norton has shipped at least 8 major AV-module versions and at least 2 named UI patches (v1.0.111 in November 2025, v1.0.138 in April 2026). Both UI patches reduced symptom frequency without fixing the underlying defect.

## Crowdsourced reproduction logs

Real diagnostic logs from affected systems are accumulating in [`logs/`](logs/). Each contributor has their own subfolder with their CSV/text logs and a brief README documenting their environment.

**If you're affected by this bug, please contribute your logs.** There are three ways to do it, ranked by how much Git knowledge they need:

1. **Open an issue and drag-and-drop your files** — no Git knowledge required. Use the [Submit diagnostic logs](https://github.com/litebito/windows-focus-steal-diagnostic/issues/new/choose) template.
2. **Use GitHub's web file uploader** — opens a fork + PR for you automatically.
3. **Submit a regular pull request** — for those comfortable with Git.

Full details in [CONTRIBUTING.md](CONTRIBUTING.md). A redaction helper script is at [`scripts/RedactLogs.ps1`](scripts/RedactLogs.ps1) — please run it (and review the output) before publishing your logs.

Every additional independent reproduction strengthens the case for a proper fix.

## Known Suspect Applications

The tool includes a built-in list of applications known to cause focus stealing issues:

| Application | Risk | Reason |
|-------------|------|--------|
| Norton 360 (NortonUI) | HIGH | CEF background timer activates invisible windows ~every 60s |
| ctfmon.exe (CTF Loader) | HIGH | Text Services Framework - often triggered by other apps |
| Norton Tools (NllToolsSvc) | HIGH | Reported alongside NortonUI as focus stealer |
| AVG UI | MEDIUM | Shares CEF codebase with Norton (Gen Digital) |
| Avast UI | MEDIUM | Shares CEF codebase with Norton (Gen Digital) |
| McAfee | MEDIUM | Notifications and WebAdvisor can steal focus |
| Xbox Game Bar | MEDIUM | Overlay activation |
| Windows Widgets | MEDIUM | Occasional focus steal on content refresh |
| SearchHost | LOW | Windows Search indexer |
| ShellExperienceHost | LOW | Start menu / taskbar / notification area |
| RuntimeBroker | LOW | UWP app permission broker |

You can extend this database by editing the `$SuspectApps` hashtable in the script.

## Norton-Specific Tools

The repository also includes `NortonFocusStealFix.ps1`, which provides:

- Norton process tree analysis with command line extraction
- Scheduled task inventory (Norton 360 Patcher, Overseer, Emergency Update, etc.)
- Norton service status (NortonSvc, Norton Firewall, Norton Tools, NortonVpn, NortonWscReporter)
- Registry key inspection for timer/notification settings
- Startup entry analysis
- Version information across all 9 Norton EXEs
- Option to kill NortonUI.exe for testing (`-KillNortonUI`)
- Deep registry scan for timer/interval/heartbeat settings (`-FullReport`)

```powershell
# Diagnose Norton's configuration
.\NortonFocusStealFix.ps1

# Kill NortonUI to test if focus stealing stops
.\NortonFocusStealFix.ps1 -KillNortonUI

# Full registry deep-dive
.\NortonFocusStealFix.ps1 -FullReport
```

## Contributing

If you've identified another application that steals focus, feel free to open an issue or PR with the process name, window class, and behavior pattern so it can be added to the suspect database.

## License

MIT License - See [LICENSE](LICENSE) for details.
