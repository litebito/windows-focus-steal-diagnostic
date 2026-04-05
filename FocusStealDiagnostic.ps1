#Requires -Version 5.1
<#
.SYNOPSIS
    Advanced Focus-Steal Diagnostic Tool for Windows 11
.DESCRIPTION
    Monitors foreground window changes using SetWinEventHook (EVENT_SYSTEM_FOREGROUND),
    captures detailed process information, correlates with known problematic applications.
    Run as Administrator for full detail (process command lines, parent PIDs, etc.)
.EXAMPLE
    .\FocusStealDiagnostic.ps1 -DurationMinutes 30
    .\FocusStealDiagnostic.ps1 -DurationMinutes 60 -LogPath "C:\Temp\focus_log.csv"
#>

param(
    [int]$DurationMinutes = 30,
    [string]$LogPath = "$env:USERPROFILE\Desktop\FocusStealLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv",
    [string]$DetailLogPath = "$env:USERPROFILE\Desktop\FocusStealDetail_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt",
    [switch]$IncludeScheduledTaskCorrelation,
    [switch]$Quiet
)

# -- Elevation check --
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator
)
if (-not $isAdmin) {
    Write-Warning "NOT running as Administrator. Some process details (command line, parent PID) may be unavailable. For best results, run elevated."
}

# -- C# interop: Win32 API for foreground window monitoring --
$Win32Code = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
using System.Diagnostics;
using System.Collections.Generic;

public class FocusMonitor
{
    public delegate void WinEventDelegate(
        IntPtr hWinEventHook, uint eventType, IntPtr hwnd,
        int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);

    [DllImport("user32.dll")]
    public static extern IntPtr SetWinEventHook(
        uint eventMin, uint eventMax, IntPtr hmodWinEventProc,
        WinEventDelegate lpfnWinEventProc, uint idProcess,
        uint idThread, uint dwFlags);

    [DllImport("user32.dll")]
    public static extern bool UnhookWinEvent(IntPtr hWinEventHook);

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetParent(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hWnd, uint gaFlags);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    public const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    public const uint EVENT_SYSTEM_MINIMIZEEND = 0x0017;
    public const uint WINEVENT_OUTOFCONTEXT = 0x0000;
    public const int GWL_STYLE = -16;
    public const int GWL_EXSTYLE = -20;
    public const uint GA_ROOT = 2;

    public static List<FocusEvent> Events = new List<FocusEvent>();
    public static WinEventDelegate Delegate;

    public class FocusEvent
    {
        public DateTime Timestamp;
        public IntPtr Hwnd;
        public uint ProcessId;
        public string ProcessName;
        public string ProcessPath;
        public string WindowTitle;
        public string WindowClass;
        public string ParentProcessName;
        public uint ParentProcessId;
        public bool IsVisible;
        public string WindowStyle;
        public string WindowRect;
        public string OwnerInfo;
        public string CommandLine;
        public string EventType;
    }

    public static string GetWindowInfo(IntPtr hwnd, string eventType)
    {
        if (hwnd == IntPtr.Zero) return "";

        uint pid = 0;
        GetWindowThreadProcessId(hwnd, out pid);

        StringBuilder sbTitle = new StringBuilder(512);
        GetWindowText(hwnd, sbTitle, 512);

        StringBuilder sbClass = new StringBuilder(256);
        GetClassName(hwnd, sbClass, 256);

        bool isVisible = IsWindowVisible(hwnd);
        int style = GetWindowLong(hwnd, GWL_STYLE);
        int exStyle = GetWindowLong(hwnd, GWL_EXSTYLE);

        RECT rect;
        GetWindowRect(hwnd, out rect);
        string rectStr = rect.Left + "," + rect.Top + "," + rect.Right + "," + rect.Bottom;

        IntPtr ownerHwnd = GetWindow(hwnd, 4);

        string processName = "";
        string processPath = "";
        string parentProcName = "";
        uint parentPid = 0;
        string cmdLine = "";

        try
        {
            Process proc = Process.GetProcessById((int)pid);
            processName = proc.ProcessName;
            try { processPath = proc.MainModule.FileName; } catch { processPath = "ACCESS_DENIED"; }
            try { cmdLine = GetCommandLine((int)pid); } catch { cmdLine = "ACCESS_DENIED"; }
        }
        catch { processName = "EXITED_PID_" + pid; }

        try
        {
            parentPid = GetParentProcessId((int)pid);
            if (parentPid > 0)
            {
                try
                {
                    Process pp = Process.GetProcessById((int)parentPid);
                    parentProcName = pp.ProcessName;
                }
                catch { parentProcName = "EXITED"; }
            }
        }
        catch { }

        string ownerInfo = "";
        if (ownerHwnd != IntPtr.Zero)
        {
            uint ownerPid = 0;
            GetWindowThreadProcessId(ownerHwnd, out ownerPid);
            StringBuilder ownerClass = new StringBuilder(256);
            GetClassName(ownerHwnd, ownerClass, 256);
            ownerInfo = "OwnerPID=" + ownerPid + ",OwnerClass=" + ownerClass.ToString();
        }

        var evt = new FocusEvent
        {
            Timestamp = DateTime.Now,
            Hwnd = hwnd,
            ProcessId = pid,
            ProcessName = processName,
            ProcessPath = processPath,
            WindowTitle = sbTitle.ToString(),
            WindowClass = sbClass.ToString(),
            ParentProcessName = parentProcName,
            ParentProcessId = parentPid,
            IsVisible = isVisible,
            WindowStyle = "Style=0x" + style.ToString("X8") + " ExStyle=0x" + exStyle.ToString("X8"),
            WindowRect = rectStr,
            OwnerInfo = ownerInfo,
            CommandLine = cmdLine,
            EventType = eventType
        };

        Events.Add(evt);

        return "[" + evt.Timestamp.ToString("HH:mm:ss.fff") + "] " + eventType +
            " | PID=" + pid + " (" + processName + ")" +
            " | Class=" + sbClass.ToString() +
            " | Title=" + sbTitle.ToString() +
            " | Visible=" + isVisible +
            " | Parent=" + parentProcName + "(PID:" + parentPid + ")";
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr processHandle, int processInformationClass,
        ref PROCESS_BASIC_INFORMATION processInformation,
        int processInformationLength, out int returnLength);

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_BASIC_INFORMATION
    {
        public IntPtr Reserved1;
        public IntPtr PebBaseAddress;
        public IntPtr Reserved2_0;
        public IntPtr Reserved2_1;
        public IntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    public static uint GetParentProcessId(int pid)
    {
        try
        {
            Process proc = Process.GetProcessById(pid);
            PROCESS_BASIC_INFORMATION pbi = new PROCESS_BASIC_INFORMATION();
            int returnLength;
            int status = NtQueryInformationProcess(proc.Handle, 0, ref pbi,
                Marshal.SizeOf(pbi), out returnLength);
            if (status == 0)
                return (uint)pbi.InheritedFromUniqueProcessId.ToInt32();
        }
        catch { }
        return 0;
    }

    public static string GetCommandLine(int pid)
    {
        try
        {
            var searcher = new System.Management.ManagementObjectSearcher(
                "SELECT CommandLine FROM Win32_Process WHERE ProcessId = " + pid);
            foreach (System.Management.ManagementObject obj in searcher.Get())
            {
                var cl = obj["CommandLine"];
                if (cl != null) return cl.ToString();
            }
        }
        catch { }
        return "";
    }
}
'@

# -- Compile the C# code --
if (-not $Quiet) {
    Write-Host ""
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host "  FOCUS-STEAL DIAGNOSTIC TOOL v1.1" -ForegroundColor Cyan
    Write-Host "  Windows 10/11 Deep Diagnostics" -ForegroundColor Cyan
    Write-Host "=========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Duration  : $DurationMinutes minutes" -ForegroundColor Yellow
    Write-Host "  CSV Log   : $LogPath" -ForegroundColor Yellow
    Write-Host "  Detail Log: $DetailLogPath" -ForegroundColor Yellow
    Write-Host "  Admin     : $isAdmin" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Compiling Win32 interop..." -ForegroundColor Gray
}

try {
    Add-Type -TypeDefinition $Win32Code -ReferencedAssemblies @('System.Management') -ErrorAction Stop
}
catch {
    if ($_.Exception.Message -notlike "*already exists*") {
        Write-Error "Failed to compile Win32 interop code: $_"
        exit 1
    }
}

# -- Known focus-stealing applications (community-reported) --
# Add your own entries to this hashtable if needed.
# Risk levels: HIGH = confirmed focus stealer, MEDIUM = known to cause issues,
#              LOW = occasionally involved but usually benign.
$SuspectApps = @{
    # -- Confirmed focus stealers (community-documented) --
    'nortonui'             = @{ Risk = 'HIGH';   Reason = 'CEF background timer activates invisible windows ~every 60s. Reported unfixed since late 2024.' }
    'ctfmon'               = @{ Risk = 'HIGH';   Reason = 'CTF Loader (Text Services Framework) - often triggered by other apps via MSCTFIME UI.' }
    'nlltoolssvc'          = @{ Risk = 'HIGH';   Reason = 'Norton Tools service - reported as focus stealer alongside NortonUI.' }
    # -- Antivirus / security software --
    'avgui'                = @{ Risk = 'MEDIUM'; Reason = 'AVG UI - shares CEF codebase with Norton (Gen Digital). May exhibit same behavior.' }
    'avastui'              = @{ Risk = 'MEDIUM'; Reason = 'Avast UI - shares CEF codebase with Norton (Gen Digital). May exhibit same behavior.' }
    'mcafee'               = @{ Risk = 'MEDIUM'; Reason = 'McAfee notifications and WebAdvisor can steal focus.' }
    'mcuicnt'              = @{ Risk = 'MEDIUM'; Reason = 'McAfee UI container process.' }
    # -- Overlays and game bars --
    'gamebar'              = @{ Risk = 'MEDIUM'; Reason = 'Xbox Game Bar overlay activation.' }
    'gamebarpresencewriter'= @{ Risk = 'LOW';    Reason = 'Game Bar background presence writer.' }
    # -- Windows components --
    'widgets'              = @{ Risk = 'MEDIUM'; Reason = 'Windows Widgets - known to occasionally steal focus on content refresh.' }
    'searchhost'           = @{ Risk = 'LOW';    Reason = 'Windows Search - indexer may briefly activate.' }
    'shellexperiencehost'  = @{ Risk = 'LOW';    Reason = 'Shell Experience Host - Start menu/taskbar/notification area.' }
    'runtimebroker'        = @{ Risk = 'LOW';    Reason = 'Runtime Broker - manages UWP app permissions.' }
}

# -- Pre-scan: identify running suspect processes --
if (-not $Quiet) {
    Write-Host "  Scanning for known suspect processes..." -ForegroundColor Gray
}

$runningProcs = Get-Process -ErrorAction SilentlyContinue | Select-Object -Property Id, ProcessName, Path
$foundSuspects = @()

foreach ($proc in $runningProcs) {
    $nameLower = $proc.ProcessName.ToLower()
    foreach ($suspect in $SuspectApps.Keys) {
        if ($nameLower -like "*$suspect*") {
            $foundSuspects += [PSCustomObject]@{
                PID         = $proc.Id
                ProcessName = $proc.ProcessName
                Path        = $proc.Path
                Risk        = $SuspectApps[$suspect].Risk
                Reason      = $SuspectApps[$suspect].Reason
            }
        }
    }
}

if (-not $Quiet -and $foundSuspects.Count -gt 0) {
    Write-Host ""
    Write-Host "  --- SUSPECT PROCESSES CURRENTLY RUNNING ---" -ForegroundColor Red
    foreach ($s in $foundSuspects) {
        $riskColor = switch ($s.Risk) {
            'HIGH'   { 'Red' }
            'MEDIUM' { 'Yellow' }
            default  { 'Gray' }
        }
        $line = "  [{0}] PID={1} {2}" -f $s.Risk, $s.PID, $s.ProcessName
        Write-Host $line -ForegroundColor $riskColor
        Write-Host "          $($s.Reason)" -ForegroundColor DarkGray
    }
    Write-Host "  -------------------------------------------" -ForegroundColor Red
}

# -- Pre-scan: check TSF/CTF state --
if (-not $Quiet) {
    Write-Host ""
    Write-Host "  Checking Text Services Framework (TSF/CTF) state..." -ForegroundColor Gray

    $ctfmonProc = Get-Process -Name "ctfmon" -ErrorAction SilentlyContinue
    if ($ctfmonProc) {
        Write-Host "  CTF Loader (ctfmon.exe) is running - PID: $($ctfmonProc.Id)" -ForegroundColor Yellow
    }

    $inputMethods = Get-WinUserLanguageList -ErrorAction SilentlyContinue
    if ($inputMethods) {
        Write-Host "  Installed input methods:" -ForegroundColor Gray
        foreach ($lang in $inputMethods) {
            $tips = $lang.InputMethodTips -join ', '
            Write-Host "    - $($lang.LanguageTag): $tips" -ForegroundColor DarkGray
        }
    }
}

# -- Scheduled task correlation (optional) --
if ($IncludeScheduledTaskCorrelation) {
    if (-not $Quiet) {
        Write-Host ""
        Write-Host "  Collecting recent scheduled task executions..." -ForegroundColor Gray
    }

    $recentTasks = Get-WinEvent -LogName 'Microsoft-Windows-TaskScheduler/Operational' -MaxEvents 50 -ErrorAction SilentlyContinue |
        Where-Object { $_.Id -eq 100 -or $_.Id -eq 102 } |
        Sort-Object TimeCreated -Descending |
        Select-Object -First 10

    if ($recentTasks -and -not $Quiet) {
        Write-Host "  Last 10 scheduled task executions:" -ForegroundColor Gray
        foreach ($task in $recentTasks) {
            $taskName = "Unknown"
            if ($task.Message -match '"(.+?)"') { $taskName = $Matches[1] }
            Write-Host "    [$($task.TimeCreated.ToString('HH:mm:ss'))] $taskName" -ForegroundColor DarkGray
        }
    }
}

# -- Initialize detail log --
$startInfo = @()
$startInfo += "==========================================================="
$startInfo += "FOCUS-STEAL DIAGNOSTIC REPORT"
$startInfo += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$startInfo += "Computer : $env:COMPUTERNAME"
$startInfo += "User     : $env:USERNAME"
$startInfo += "Admin    : $isAdmin"
$startInfo += "Duration : $DurationMinutes minutes"
$startInfo += "==========================================================="
$startInfo += ""
$startInfo += "--- RUNNING SUSPECT PROCESSES AT START ---"
foreach ($s in $foundSuspects) {
    $startInfo += "  [$($s.Risk)] PID=$($s.PID) $($s.ProcessName) - $($s.Path)"
}
$startInfo += ""
$startInfo += "--- FOCUS CHANGE LOG ---"

$startInfo | Out-File -FilePath $DetailLogPath -Encoding UTF8

# -- Setup the event hook --
$script:lastFgHwnd = [IntPtr]::Zero
$script:lastFgTime = [DateTime]::MinValue
$script:eventCount = 0
$script:stealCount = 0

[FocusMonitor]::Delegate = [FocusMonitor+WinEventDelegate]{
    param($hWinEventHook, $eventType, $hwnd, $idObject, $idChild, $dwEventThread, $dwmsEventTime)

    if ($hwnd -eq [IntPtr]::Zero) { return }

    $evtName = switch ($eventType) {
        0x0003 { "FOREGROUND" }
        0x0017 { "MINIMIZE_END" }
        default { "EVENT_0x" + $eventType.ToString('X4') }
    }

    $currentFg = [FocusMonitor]::GetForegroundWindow()
    if ($eventType -eq 0x0003 -or $currentFg -ne $script:lastFgHwnd) {
        $info = [FocusMonitor]::GetWindowInfo($hwnd, $evtName)

        if ($info) {
            if (-not $Quiet) {
                $lastEvent = [FocusMonitor]::Events | Select-Object -Last 1
                $procName = ""
                if ($lastEvent) { $procName = $lastEvent.ProcessName.ToLower() }

                $color = 'White'
                $suffix = ""
                foreach ($suspect in $SuspectApps.Keys) {
                    if ($procName -like "*$suspect*") {
                        $color = switch ($SuspectApps[$suspect].Risk) {
                            'HIGH'   { 'Red' }
                            'MEDIUM' { 'Yellow' }
                            default  { 'Gray' }
                        }
                        $suffix = " << SUSPECT [$($SuspectApps[$suspect].Risk)]"
                        break
                    }
                }

                if ($info -like "*MSCTFIME*" -or $info -like "*MSCTF*") {
                    $color = 'Magenta'
                    $suffix = " << TSF/IME RELATED"
                }

                Write-Host ($info + $suffix) -ForegroundColor $color
            }

            $info | Out-File -FilePath $DetailLogPath -Append -Encoding UTF8
        }

        $timeSinceLast = if ($script:lastFgTime -ne [DateTime]::MinValue) {
            (Get-Date) - $script:lastFgTime
        }
        else { [TimeSpan]::Zero }

        if ($timeSinceLast.TotalSeconds -gt 0 -and $timeSinceLast.TotalSeconds -lt 3) {
            $script:stealCount++
        }

        $script:lastFgHwnd = $currentFg
        $script:lastFgTime = Get-Date
        $script:eventCount++
    }
}

# Install hooks
$hook1 = [FocusMonitor]::SetWinEventHook(
    [FocusMonitor]::EVENT_SYSTEM_FOREGROUND,
    [FocusMonitor]::EVENT_SYSTEM_FOREGROUND,
    [IntPtr]::Zero,
    [FocusMonitor]::Delegate,
    0, 0,
    [FocusMonitor]::WINEVENT_OUTOFCONTEXT
)

$hook2 = [FocusMonitor]::SetWinEventHook(
    [FocusMonitor]::EVENT_SYSTEM_MINIMIZEEND,
    [FocusMonitor]::EVENT_SYSTEM_MINIMIZEEND,
    [IntPtr]::Zero,
    [FocusMonitor]::Delegate,
    0, 0,
    [FocusMonitor]::WINEVENT_OUTOFCONTEXT
)

if ($hook1 -eq [IntPtr]::Zero) {
    Write-Error "Failed to set WinEvent hook. Try running as Administrator."
    exit 1
}

if (-not $Quiet) {
    Write-Host ""
    Write-Host "  [OK] Focus monitoring hooks installed." -ForegroundColor Green
    $endTimeDisplay = ((Get-Date).AddMinutes($DurationMinutes)).ToString('HH:mm:ss')
    Write-Host "  [OK] Monitoring started at $(Get-Date -Format 'HH:mm:ss')" -ForegroundColor Green
    Write-Host "  [OK] Will run for $DurationMinutes minutes (until $endTimeDisplay)" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Work normally. Focus changes will appear below:" -ForegroundColor Cyan
    Write-Host "  (RED=high-risk, YELLOW=medium-risk, MAGENTA=TSF/IME)" -ForegroundColor Cyan
    Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
}

# -- Message pump (required for WinEventHook callbacks) --
$endTime = (Get-Date).AddMinutes($DurationMinutes)
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

while ((Get-Date) -lt $endTime) {
    [System.Windows.Forms.Application]::DoEvents()
    Start-Sleep -Milliseconds 50
}

# -- Cleanup hooks --
[FocusMonitor]::UnhookWinEvent($hook1) | Out-Null
if ($hook2 -ne [IntPtr]::Zero) {
    [FocusMonitor]::UnhookWinEvent($hook2) | Out-Null
}

# -- Export CSV --
$events = [FocusMonitor]::Events

if ($events.Count -gt 0) {
    $csvData = $events | ForEach-Object {
        [PSCustomObject]@{
            Timestamp     = $_.Timestamp.ToString('yyyy-MM-dd HH:mm:ss.fff')
            EventType     = $_.EventType
            PID           = $_.ProcessId
            ProcessName   = $_.ProcessName
            ProcessPath   = $_.ProcessPath
            WindowTitle   = $_.WindowTitle
            WindowClass   = $_.WindowClass
            ParentPID     = $_.ParentProcessId
            ParentProcess = $_.ParentProcessName
            IsVisible     = $_.IsVisible
            WindowStyle   = $_.WindowStyle
            WindowRect    = $_.WindowRect
            OwnerInfo     = $_.OwnerInfo
            CommandLine   = $_.CommandLine
        }
    }

    $csvData | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
}

# -- Analysis and Summary --
if (-not $Quiet) {
    Write-Host ""
    Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  =========================================================" -ForegroundColor Cyan
    Write-Host "  ANALYSIS SUMMARY" -ForegroundColor Cyan
    Write-Host "  =========================================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Total focus change events : $($events.Count)" -ForegroundColor White
    $stealColor = if ($script:stealCount -gt 5) { 'Red' } else { 'White' }
    Write-Host "  Rapid focus changes (<3s) : $($script:stealCount)" -ForegroundColor $stealColor
    Write-Host ""
}

if ($events.Count -gt 0) {
    # Process frequency
    $processGroups = $events | Group-Object ProcessName | Sort-Object Count -Descending

    if (-not $Quiet) {
        Write-Host "  --- FOCUS EVENTS BY PROCESS ---" -ForegroundColor Yellow
        foreach ($pg in ($processGroups | Select-Object -First 15)) {
            $isSuspect = $false
            foreach ($suspect in $SuspectApps.Keys) {
                if ($pg.Name.ToLower() -like "*$suspect*") { $isSuspect = $true; break }
            }
            $marker = ""
            if ($isSuspect) { $marker = " << SUSPECT" }
            $pgColor = if ($isSuspect) { 'Red' } else { 'White' }
            $pgLine = "    {0,-30} : {1,4} events{2}" -f $pg.Name, $pg.Count, $marker
            Write-Host $pgLine -ForegroundColor $pgColor
        }
        Write-Host ""
    }

    # Window class frequency
    $classGroups = $events | Group-Object WindowClass | Sort-Object Count -Descending

    if (-not $Quiet) {
        Write-Host "  --- FOCUS EVENTS BY WINDOW CLASS ---" -ForegroundColor Yellow
        foreach ($cg in ($classGroups | Select-Object -First 15)) {
            $isIME = ($cg.Name -like "*MSCTF*") -or ($cg.Name -like "*IME*") -or ($cg.Name -like "*CTF*")
            $marker = ""
            if ($isIME) { $marker = " << TSF/IME" }
            $cgColor = if ($isIME) { 'Magenta' } else { 'White' }
            $cgLine = "    {0,-30} : {1,4} events{2}" -f $cg.Name, $cg.Count, $marker
            Write-Host $cgLine -ForegroundColor $cgColor
        }
        Write-Host ""
    }

    # Timing pattern analysis for IME events
    if ($events.Count -gt 2) {
        $imeTimestamps = @($events |
            Where-Object { ($_.WindowClass -like "*MSCTF*") -or ($_.WindowClass -like "*IME*") } |
            ForEach-Object { $_.Timestamp })

        if ($imeTimestamps.Count -gt 2) {
            $intervals = @()
            for ($i = 1; $i -lt $imeTimestamps.Count; $i++) {
                $intervals += ($imeTimestamps[$i] - $imeTimestamps[$i - 1]).TotalSeconds
            }

            $avgInterval = ($intervals | Measure-Object -Average).Average
            $sortedIntervals = @($intervals | Sort-Object)
            $medianIdx = [math]::Floor($sortedIntervals.Count / 2)
            $medianInterval = $sortedIntervals[$medianIdx]
            $minInterval = ($intervals | Measure-Object -Minimum).Minimum
            $maxInterval = ($intervals | Measure-Object -Maximum).Maximum

            if (-not $Quiet) {
                Write-Host "  --- TSF/IME TIMING PATTERN ---" -ForegroundColor Magenta
                Write-Host "    TSF/IME focus events : $($imeTimestamps.Count)" -ForegroundColor Magenta
                Write-Host "    Average interval     : $([math]::Round($avgInterval, 1)) seconds" -ForegroundColor Magenta
                Write-Host "    Median interval      : $([math]::Round($medianInterval, 1)) seconds" -ForegroundColor Magenta
                Write-Host "    Min interval         : $([math]::Round($minInterval, 1)) seconds" -ForegroundColor Magenta
                Write-Host "    Max interval         : $([math]::Round($maxInterval, 1)) seconds" -ForegroundColor Magenta
                Write-Host ""
            }
        }
    }

    # Invisible windows (biggest red flag)
    $invisibleEvents = @($events | Where-Object { -not $_.IsVisible })
    if ($invisibleEvents.Count -gt 0 -and -not $Quiet) {
        Write-Host "  --- INVISIBLE WINDOWS STEALING FOCUS (RED FLAG!) ---" -ForegroundColor Red
        foreach ($inv in ($invisibleEvents | Select-Object -First 10)) {
            $invTime = $inv.Timestamp.ToString('HH:mm:ss.fff')
            Write-Host "    [$invTime] $($inv.ProcessName) - Class: $($inv.WindowClass)" -ForegroundColor Red
            Write-Host "      Path: $($inv.ProcessPath)" -ForegroundColor DarkRed
        }
        Write-Host ""
    }

    # -- Write summary to detail log --
    $summaryLines = @()
    $summaryLines += ""
    $summaryLines += "==========================================================="
    $summaryLines += "SUMMARY"
    $summaryLines += "==========================================================="
    $summaryLines += "Total events         : $($events.Count)"
    $summaryLines += "Rapid focus changes  : $($script:stealCount)"
    $summaryLines += ""
    $summaryLines += "EVENTS BY PROCESS:"
    foreach ($pg in $processGroups) {
        $pgSummary = "  {0,-30} : {1}" -f $pg.Name, $pg.Count
        $summaryLines += $pgSummary
    }
    $summaryLines += ""
    $summaryLines += "EVENTS BY WINDOW CLASS:"
    foreach ($cg in $classGroups) {
        $cgSummary = "  {0,-30} : {1}" -f $cg.Name, $cg.Count
        $summaryLines += $cgSummary
    }
    $summaryLines += ""
    $summaryLines += "INVISIBLE WINDOW EVENTS:"
    foreach ($inv in $invisibleEvents) {
        $invTime = $inv.Timestamp.ToString('HH:mm:ss.fff')
        $summaryLines += "  $invTime | $($inv.ProcessName) | $($inv.WindowClass) | $($inv.ProcessPath)"
    }

    $summaryLines | Out-File -FilePath $DetailLogPath -Append -Encoding UTF8
}

if (-not $Quiet) {
    Write-Host "  =========================================================" -ForegroundColor Green
    Write-Host "  [OK] CSV log saved to   : $LogPath" -ForegroundColor Green
    Write-Host "  [OK] Detail log saved to: $DetailLogPath" -ForegroundColor Green
    Write-Host "  =========================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  NEXT STEPS:" -ForegroundColor Cyan
    Write-Host "  1. Share the CSV and Detail log files for analysis" -ForegroundColor White
    Write-Host "  2. Look for patterns in the SUSPECT and TSF/IME entries" -ForegroundColor White
    Write-Host "  3. If a regular interval appears, we can identify the timer source" -ForegroundColor White
    Write-Host ""
}
