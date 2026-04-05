# Windows Focus-Steal Diagnostic Tool

A PowerShell-based diagnostic tool for detecting and identifying applications that steal foreground window focus on Windows 10/11. Uses Win32 API hooks (`SetWinEventHook`) to monitor every focus change in real-time with full process forensics.

## Background

This tool was developed to investigate a persistent focus-stealing issue on Windows 11, which was ultimately traced to **Norton 360's NortonUI.exe**. The full analysis and bug report is available in [`docs/Norton360_FocusSteal_BugReport.md`](docs/Norton360_FocusSteal_BugReport.md).

While this tool was built for the Norton investigation, it is **generic and works for any focus-stealing application** — antivirus software, overlay tools, game launchers, input method editors, or any process that activates windows in the background.

## What It Captures

For every foreground window change, the tool logs:

- **Process details** — PID, name, full path, and command line (requires elevation)
- **Window details** — class name, title, visibility state, window styles, dimensions
- **Parent process** — name and PID (via `NtQueryInformationProcess`)
- **Owner window** — PID and class of the owning window
- **Timing** — millisecond-precision timestamps for interval analysis
- **Suspect flagging** — known problematic applications are highlighted in real-time

## Key Features

- **Real-time color-coded console output** — RED for high-risk suspects, YELLOW for medium, MAGENTA for TSF/IME related events
- **Invisible window detection** — flags hidden windows stealing focus (the strongest indicator of a bug)
- **Timing pattern analysis** — calculates intervals between TSF/IME events to detect periodic timers
- **Suspect app database** — pre-configured detection for Norton, Loupedeck, PowerToys, AMD Software, and other known offenders
- **Pre-scan** — identifies suspect processes, CTF Loader state, and installed input methods before monitoring begins
- **Dual output** — CSV for data analysis + detailed text log for human review
- **No external dependencies** — pure PowerShell + inline C# (Win32 P/Invoke), no modules to install

## Requirements

- Windows 10 or Windows 11
- PowerShell 5.1 or later
- **Administrator** (elevated) recommended for full process details (command lines, parent PIDs)

## Usage

### Basic Usage (30-minute monitoring)

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\FocusStealDiagnostic.ps1 -DurationMinutes 30
```

### Custom Log Location

```powershell
.\FocusStealDiagnostic.ps1 -DurationMinutes 15 -LogPath "C:\Temp\FocusLog.csv" -DetailLogPath "C:\Temp\FocusDetail.txt"
```

### Include Scheduled Task Correlation

```powershell
.\FocusStealDiagnostic.ps1 -DurationMinutes 30 -IncludeScheduledTaskCorrelation
```

### Quiet Mode (log only, minimal console output)

```powershell
.\FocusStealDiagnostic.ps1 -DurationMinutes 60 -Quiet
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `-DurationMinutes` | int | 30 | How long to monitor (in minutes) |
| `-LogPath` | string | Desktop\FocusStealLog_*.csv | Path for the CSV output |
| `-DetailLogPath` | string | Desktop\FocusStealDetail_*.txt | Path for the detailed text log |
| `-IncludeScheduledTaskCorrelation` | switch | off | Also capture recent scheduled task executions |
| `-Quiet` | switch | off | Suppress most console output |

## Output Files

### CSV Log (`FocusStealLog_*.csv`)

One row per focus change event with columns:

| Column | Description |
|--------|-------------|
| Timestamp | yyyy-MM-dd HH:mm:ss.fff |
| EventType | FOREGROUND, MINIMIZE_END, or EVENT_0x#### |
| PID | Process ID |
| ProcessName | e.g., NortonUI, chrome, explorer |
| ProcessPath | Full executable path |
| WindowTitle | Window title text |
| WindowClass | Win32 window class name |
| ParentPID | Parent process ID |
| ParentProcess | Parent process name |
| IsVisible | True/False - **False on a focus event is a red flag** |
| WindowStyle | Hex style + extended style flags |
| WindowRect | Left,Top,Right,Bottom coordinates |
| OwnerInfo | Owner window PID and class (if applicable) |
| CommandLine | Full command line (requires elevation) |

### Detail Log (`FocusStealDetail_*.txt`)

Human-readable report containing:
- System info and running suspect processes at start
- Real-time focus change log with timestamps
- Summary with event counts by process and window class
- TSF/IME timing pattern analysis (average, median, min, max intervals)
- List of invisible windows that stole focus

## Interpreting Results

### Red Flags

1. **Invisible windows stealing focus** (`IsVisible=False` on FOREGROUND events) — This is the strongest indicator. A visible window taking focus might be a notification; an invisible one is almost always a bug.

2. **Regular intervals** — If a process steals focus every N seconds with consistent timing, it has a background timer. The TSF/IME Timing Pattern section in the summary helps identify this.

3. **High event count from a single process** — If one process accounts for >20% of all focus events and you didn't interact with it, it's the culprit.

4. **PID=0 / Idle events preceding the steal** — A burst of Idle events followed by a background process indicates the active window was forcibly deactivated.

### Normal Behavior

- Focus events from applications you actively switched to (Chrome, Terminal, File Explorer)
- `Shell_TrayWnd` (taskbar) events when clicking the taskbar
- `WhatsApp` / messaging apps restoring from minimized state on incoming messages

## The Norton 360 Bug

This tool was created to diagnose a focus-stealing issue that turned out to be caused by Norton 360 (NortonUI.exe). Key findings:

- **178 out of 420 focus events (42%)** were from NortonUI.exe
- **100% of NortonUI events were on invisible windows**
- The pattern repeated every ~60 seconds
- Root cause: Norton's CEF (Chromium Embedded Framework) engine uses the `--disable-features=CalculateNativeWinOcclusion` flag, preventing it from recognizing its windows are hidden
- Norton ships with **Chromium 91** (from 2021), which is massively outdated
- Killing NortonUI.exe eliminated 100% of phantom focus events; Norton's core protection (NortonSvc.exe) continued functioning

For the full technical analysis, see [`docs/Norton360_FocusSteal_BugReport.md`](docs/Norton360_FocusSteal_BugReport.md).

**This bug has been reported by multiple users on Norton Community since December 2024 across versions 24.x through 26.3, and remains unfixed as of April 2026.**

## Known Suspect Applications

The tool includes a built-in database of applications known to cause focus issues:

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
- Version information
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
