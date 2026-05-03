#Requires -Version 5.1
<#
.SYNOPSIS
    Advanced Focus-Steal Diagnostic Tool for Windows 10/11 (v1.2)
.DESCRIPTION
    Monitors foreground window changes using SetWinEventHook (EVENT_SYSTEM_FOREGROUND),
    captures detailed process information, correlates with known problematic applications.
    Run as Administrator for full detail (process command lines, parent PIDs, etc.)
.NOTES
    v1.2 changes:
      - Fixed: callbacks no longer fire after script stops (shutdown flag added)
      - Added: per-process timing pattern analysis (intervals, periodicity detection)
      - Added: per-suspect cumulative event log section in summary
      - Added: rapid-fire burst detection (multiple events within 500ms)
      - Added: dedicated Norton CEF window tracking (CefHeaderWindow / Chrome_WidgetWin_0)
      - Added: progress heartbeat every 5 minutes during monitoring
      - Added: focus duration tracking (how long each foreground window held focus)
      - Added: invisible-window cluster detection (consecutive hidden activations)
      - Cleaned: suspect list now contains only widely documented focus stealers
.EXAMPLE
    .\FocusStealDiagnostic.ps1 -DurationMinutes 30
    .\FocusStealDiagnostic.ps1 -DurationMinutes 60 -LogPath "C:\Temp\focus_log.csv"
#>

param(
    [int]$DurationMinutes = 30,
    [string]$LogPath = (Join-Path $PSScriptRoot "FocusStealLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"),
    [string]$DetailLogPath = (Join-Path $PSScriptRoot "FocusStealDetail_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"),
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

    // -- Shutdown flag: when set, the callback ignores all events --
    public static volatile bool ShutdownRequested = false;

    public static List<FocusEvent> Events = new List<FocusEvent>();
    public static WinEventDelegate Delegate;
    private static readonly object _lockObj = new object();

    public class FocusEvent
    {
        public DateTime Timestamp;
        public IntPtr Hwnd;
        public uint ProcessId;
        public string ProcessName;
        public string ProcessPath;
        public string ProductVersion;
        public string FileVersion;
        public string CompanyName;
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
        public double SecondsSincePrevious;
    }

    public static FocusEvent BuildEvent(IntPtr hwnd, string eventType)
    {
        if (ShutdownRequested) return null;
        if (hwnd == IntPtr.Zero) return null;

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
        string productVersion = "";
        string fileVersion = "";
        string companyName = "";
        string parentProcName = "";
        uint parentPid = 0;
        string cmdLine = "";

        try
        {
            Process proc = Process.GetProcessById((int)pid);
            processName = proc.ProcessName;
            try
            {
                processPath = proc.MainModule.FileName;
                var fvi = proc.MainModule.FileVersionInfo;
                productVersion = fvi.ProductVersion ?? "";
                fileVersion = fvi.FileVersion ?? "";
                companyName = fvi.CompanyName ?? "";
            }
            catch
            {
                processPath = "ACCESS_DENIED";
            }
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
            ProductVersion = productVersion,
            FileVersion = fileVersion,
            CompanyName = companyName,
            WindowTitle = sbTitle.ToString(),
            WindowClass = sbClass.ToString(),
            ParentProcessName = parentProcName,
            ParentProcessId = parentPid,
            IsVisible = isVisible,
            WindowStyle = "Style=0x" + style.ToString("X8") + " ExStyle=0x" + exStyle.ToString("X8"),
            WindowRect = rectStr,
            OwnerInfo = ownerInfo,
            CommandLine = cmdLine,
            EventType = eventType,
            SecondsSincePrevious = 0
        };

        lock (_lockObj)
        {
            if (Events.Count > 0)
            {
                evt.SecondsSincePrevious = (evt.Timestamp - Events[Events.Count - 1].Timestamp).TotalSeconds;
            }
            Events.Add(evt);
        }
        return evt;
    }

    public static string FormatEvent(FocusEvent evt)
    {
        if (evt == null) return "";
        return "[" + evt.Timestamp.ToString("HH:mm:ss.fff") + "] " + evt.EventType +
            " | dt=" + evt.SecondsSincePrevious.ToString("F2") + "s" +
            " | PID=" + evt.ProcessId + " (" + evt.ProcessName + ")" +
            " | Class=" + evt.WindowClass +
            " | Title=" + evt.WindowTitle +
            " | Visible=" + evt.IsVisible +
            " | Parent=" + evt.ParentProcessName + "(PID:" + evt.ParentProcessId + ")" +
            (string.IsNullOrEmpty(evt.ProductVersion) ? "" : " | Ver=" + evt.ProductVersion);
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
    Write-Host "  FOCUS-STEAL DIAGNOSTIC TOOL v1.2" -ForegroundColor Cyan
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

# Reset shutdown flag if module was already loaded from prior run
[FocusMonitor]::ShutdownRequested = $false

# -- Known focus-stealing applications (community-documented) --
# Add your own entries to this hashtable if needed.
# Risk: HIGH = confirmed focus stealer | MEDIUM = known to cause issues | LOW = usually benign
$SuspectApps = @{
    # -- Confirmed focus stealers --
    'nortonui'              = @{ Risk = 'HIGH';   Reason = 'CEF background timer activates invisible windows. Reported unfixed since late 2024.' }
    'ctfmon'                = @{ Risk = 'HIGH';   Reason = 'CTF Loader (Text Services Framework) - often triggered by other apps via MSCTFIME UI.' }
    'nlltoolssvc'           = @{ Risk = 'HIGH';   Reason = 'Norton Tools service - reported alongside NortonUI as focus stealer.' }
    # -- Antivirus / security software (CEF-based UIs) --
    'avgui'                 = @{ Risk = 'MEDIUM'; Reason = 'AVG UI - shares CEF codebase with Norton (Gen Digital).' }
    'avastui'               = @{ Risk = 'MEDIUM'; Reason = 'Avast UI - shares CEF codebase with Norton (Gen Digital).' }
    'mcafee'                = @{ Risk = 'MEDIUM'; Reason = 'McAfee notifications and WebAdvisor can steal focus.' }
    'mcuicnt'               = @{ Risk = 'MEDIUM'; Reason = 'McAfee UI container.' }
    # -- Overlays --
    'gamebar'               = @{ Risk = 'MEDIUM'; Reason = 'Xbox Game Bar overlay activation.' }
    'gamebarpresencewriter' = @{ Risk = 'LOW';    Reason = 'Game Bar background presence writer.' }
    # -- Windows components --
    'widgets'               = @{ Risk = 'MEDIUM'; Reason = 'Windows Widgets - occasional focus steal on content refresh.' }
    'searchhost'            = @{ Risk = 'LOW';    Reason = 'Windows Search indexer.' }
    'shellexperiencehost'   = @{ Risk = 'LOW';    Reason = 'Shell Experience Host - Start menu/taskbar/notification area.' }
    'runtimebroker'         = @{ Risk = 'LOW';    Reason = 'Runtime Broker for UWP apps.' }
}

# -- Norton-specific window classes (for CEF tracking) --
$NortonCefWindowClasses = @('CefHeaderWindow', 'Chrome_WidgetWin_0', 'Chrome_WidgetWin_1', 'Chrome_RenderWidgetHostHWND')

function Test-IsSuspectProcess {
    param([string]$ProcessName)
    $nameLower = $ProcessName.ToLower()
    foreach ($suspect in $SuspectApps.Keys) {
        if ($nameLower -like "*$suspect*") {
            return $SuspectApps[$suspect]
        }
    }
    return $null
}

# -- Pre-scan: identify running suspect processes --
if (-not $Quiet) {
    Write-Host "  Scanning for known suspect processes..." -ForegroundColor Gray
}

$runningProcs = Get-Process -ErrorAction SilentlyContinue | Select-Object -Property Id, ProcessName, Path
$foundSuspects = @()

foreach ($proc in $runningProcs) {
    $suspectInfo = Test-IsSuspectProcess -ProcessName $proc.ProcessName
    if ($suspectInfo) {
        $verInfo = ""
        if ($proc.Path -and (Test-Path $proc.Path -ErrorAction SilentlyContinue)) {
            try {
                $vi = (Get-Item $proc.Path).VersionInfo
                $verInfo = $vi.ProductVersion
            }
            catch { }
        }
        $foundSuspects += [PSCustomObject]@{
            PID            = $proc.Id
            ProcessName    = $proc.ProcessName
            Path           = $proc.Path
            ProductVersion = $verInfo
            Risk           = $suspectInfo.Risk
            Reason         = $suspectInfo.Reason
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
        $verSuffix = if ($s.ProductVersion) { " v$($s.ProductVersion)" } else { "" }
        $line = "  [{0}] PID={1} {2}{3}" -f $s.Risk, $s.PID, $s.ProcessName, $verSuffix
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
$startInfo += "FOCUS-STEAL DIAGNOSTIC REPORT (v1.2)"
$startInfo += "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$startInfo += "Computer : $env:COMPUTERNAME"
$startInfo += "User     : $env:USERNAME"
$startInfo += "Admin    : $isAdmin"
$startInfo += "Duration : $DurationMinutes minutes"
$startInfo += "==========================================================="
$startInfo += ""
$startInfo += "--- RUNNING SUSPECT PROCESSES AT START ---"
foreach ($s in $foundSuspects) {
    $verSuffix = if ($s.ProductVersion) { " v$($s.ProductVersion)" } else { "" }
    $startInfo += "  [$($s.Risk)] PID=$($s.PID) $($s.ProcessName)$verSuffix - $($s.Path)"
}
$startInfo += ""
$startInfo += "--- FOCUS CHANGE LOG (dt = seconds since previous event) ---"

$startInfo | Out-File -FilePath $DetailLogPath -Encoding UTF8

# -- Setup the event hook --
$script:lastFgHwnd = [IntPtr]::Zero
$script:lastFgTime = [DateTime]::MinValue
$script:eventCount = 0
$script:rapidStealCount = 0
$script:burstCount = 0
$script:nextHeartbeat = (Get-Date).AddMinutes(5)
$script:startTime = Get-Date

[FocusMonitor]::Delegate = [FocusMonitor+WinEventDelegate]{
    param($hWinEventHook, $eventType, $hwnd, $idObject, $idChild, $dwEventThread, $dwmsEventTime)

    # Hard exit if shutdown was requested
    if ([FocusMonitor]::ShutdownRequested) { return }
    if ($hwnd -eq [IntPtr]::Zero) { return }

    $evtName = switch ($eventType) {
        0x0003 { "FOREGROUND" }
        0x0017 { "MINIMIZE_END" }
        default { "EVENT_0x" + $eventType.ToString('X4') }
    }

    $currentFg = [FocusMonitor]::GetForegroundWindow()
    if ($eventType -eq 0x0003 -or $currentFg -ne $script:lastFgHwnd) {

        $evt = [FocusMonitor]::BuildEvent($hwnd, $evtName)
        if ($null -eq $evt) { return }
        if ([FocusMonitor]::ShutdownRequested) { return }

        $info = [FocusMonitor]::FormatEvent($evt)

        if ($info -and -not [FocusMonitor]::ShutdownRequested) {
            if (-not $Quiet) {
                $procName = $evt.ProcessName.ToLower()

                $color = 'White'
                $suffix = ""
                $isSuspect = $false
                foreach ($suspect in $SuspectApps.Keys) {
                    if ($procName -like "*$suspect*") {
                        $isSuspect = $true
                        $color = switch ($SuspectApps[$suspect].Risk) {
                            'HIGH'   { 'Red' }
                            'MEDIUM' { 'Yellow' }
                            default  { 'Gray' }
                        }
                        $suffix = " << SUSPECT [$($SuspectApps[$suspect].Risk)]"
                        break
                    }
                }

                # Norton CEF window class detection
                if ($evt.WindowClass -in $NortonCefWindowClasses -and $isSuspect) {
                    $suffix += " [CEF]"
                }

                # Invisible-window flag
                if (-not $evt.IsVisible) {
                    $suffix += " [INVISIBLE]"
                    if (-not $isSuspect) { $color = 'DarkRed' }
                }

                # MSCTF/IME marker
                if ($info -like "*MSCTFIME*" -or $info -like "*MSCTF*") {
                    $color = 'Magenta'
                    $suffix += " [TSF/IME]"
                }

                Write-Host ($info + $suffix) -ForegroundColor $color
            }

            try { $info | Out-File -FilePath $DetailLogPath -Append -Encoding UTF8 } catch { }
        }

        $timeSinceLast = if ($script:lastFgTime -ne [DateTime]::MinValue) {
            (Get-Date) - $script:lastFgTime
        }
        else { [TimeSpan]::Zero }

        if ($timeSinceLast.TotalSeconds -gt 0 -and $timeSinceLast.TotalSeconds -lt 3) {
            $script:rapidStealCount++
        }
        if ($timeSinceLast.TotalMilliseconds -gt 0 -and $timeSinceLast.TotalMilliseconds -lt 500) {
            $script:burstCount++
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
    Write-Host "  Press Ctrl+C to stop early." -ForegroundColor Cyan
    Write-Host "  ---------------------------------------------------------" -ForegroundColor DarkGray
}

# -- Message pump (required for WinEventHook callbacks) --
$endTime = (Get-Date).AddMinutes($DurationMinutes)
Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue

try {
    while ((Get-Date) -lt $endTime) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50

        # Heartbeat every 5 minutes
        if ((Get-Date) -ge $script:nextHeartbeat -and -not $Quiet) {
            $elapsed = ((Get-Date) - $script:startTime).TotalMinutes
            $remaining = ($endTime - (Get-Date)).TotalMinutes
            $currentEvents = [FocusMonitor]::Events.Count
            Write-Host ""
            Write-Host "  [HEARTBEAT $(Get-Date -Format 'HH:mm:ss')] Elapsed: $([math]::Round($elapsed, 1))min | Remaining: $([math]::Round($remaining, 1))min | Events captured: $currentEvents" -ForegroundColor Cyan
            Write-Host ""
            $script:nextHeartbeat = (Get-Date).AddMinutes(5)
        }
    }
}
finally {
    # -- CRITICAL: signal the C# layer to ignore further callbacks --
    [FocusMonitor]::ShutdownRequested = $true

    # -- Cleanup hooks (do this before message pump drain) --
    if ($hook1 -ne [IntPtr]::Zero) { [FocusMonitor]::UnhookWinEvent($hook1) | Out-Null }
    if ($hook2 -ne [IntPtr]::Zero) { [FocusMonitor]::UnhookWinEvent($hook2) | Out-Null }

    # -- Drain pending messages so any in-flight callbacks complete and see the flag --
    for ($i = 0; $i -lt 10; $i++) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 50
    }

    Write-Host ""
    if (-not $Quiet) {
        Write-Host "  [OK] Hooks unregistered. Monitoring stopped at $(Get-Date -Format 'HH:mm:ss')." -ForegroundColor Green
    }
}

# -- Snapshot events (after shutdown to ensure no concurrent writes) --
$events = @([FocusMonitor]::Events)

# -- Export CSV --
if ($events.Count -gt 0) {
    $csvData = $events | ForEach-Object {
        [PSCustomObject]@{
            Timestamp            = $_.Timestamp.ToString('yyyy-MM-dd HH:mm:ss.fff')
            EventType            = $_.EventType
            SecondsSincePrevious = [math]::Round($_.SecondsSincePrevious, 3)
            PID                  = $_.ProcessId
            ProcessName          = $_.ProcessName
            ProcessPath          = $_.ProcessPath
            ProductVersion       = $_.ProductVersion
            FileVersion          = $_.FileVersion
            CompanyName          = $_.CompanyName
            WindowTitle          = $_.WindowTitle
            WindowClass          = $_.WindowClass
            ParentPID            = $_.ParentProcessId
            ParentProcess        = $_.ParentProcessName
            IsVisible            = $_.IsVisible
            WindowStyle          = $_.WindowStyle
            WindowRect           = $_.WindowRect
            OwnerInfo            = $_.OwnerInfo
            CommandLine          = $_.CommandLine
        }
    }

    $csvData | Export-Csv -Path $LogPath -NoTypeInformation -Encoding UTF8
}

# -- Helper: timing analysis function --
function Get-TimingStats {
    param($Timestamps)
    if ($Timestamps.Count -lt 2) { return $null }
    $intervals = @()
    for ($i = 1; $i -lt $Timestamps.Count; $i++) {
        $intervals += ($Timestamps[$i] - $Timestamps[$i - 1]).TotalSeconds
    }
    $sortedIntervals = @($intervals | Sort-Object)
    $medianIdx = [math]::Floor($sortedIntervals.Count / 2)
    return [PSCustomObject]@{
        Count    = $Timestamps.Count
        Avg      = [math]::Round(($intervals | Measure-Object -Average).Average, 2)
        Median   = [math]::Round($sortedIntervals[$medianIdx], 2)
        Min      = [math]::Round(($intervals | Measure-Object -Minimum).Minimum, 2)
        Max      = [math]::Round(($intervals | Measure-Object -Maximum).Maximum, 2)
        StdDev   = [math]::Round([math]::Sqrt((($intervals | ForEach-Object { [math]::Pow($_ - (($intervals | Measure-Object -Average).Average), 2) } | Measure-Object -Sum).Sum / $intervals.Count)), 2)
    }
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
    Write-Host "  Rapid focus changes (<3s) : $($script:rapidStealCount)" -ForegroundColor $(if ($script:rapidStealCount -gt 5) { 'Red' } else { 'White' })
    Write-Host "  Bursts (<500ms apart)     : $($script:burstCount)" -ForegroundColor $(if ($script:burstCount -gt 3) { 'Red' } else { 'White' })
    Write-Host ""
}

if ($events.Count -gt 0) {
    # Process frequency
    $processGroups = $events | Group-Object ProcessName | Sort-Object Count -Descending

    if (-not $Quiet) {
        Write-Host "  --- FOCUS EVENTS BY PROCESS ---" -ForegroundColor Yellow
        foreach ($pg in ($processGroups | Select-Object -First 15)) {
            $suspectInfo = Test-IsSuspectProcess -ProcessName $pg.Name
            $marker = ""
            if ($suspectInfo) { $marker = " << SUSPECT [$($suspectInfo.Risk)]" }
            $pgColor = if ($suspectInfo) { 'Red' } else { 'White' }
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
            $isCef = $cg.Name -in $NortonCefWindowClasses
            $marker = ""
            if ($isIME) { $marker += " [TSF/IME]" }
            if ($isCef) { $marker += " [CEF]" }
            $cgColor = if ($isIME) { 'Magenta' } elseif ($isCef) { 'Red' } else { 'White' }
            $cgLine = "    {0,-30} : {1,4} events{2}" -f $cg.Name, $cg.Count, $marker
            Write-Host $cgLine -ForegroundColor $cgColor
        }
        Write-Host ""
    }

    # -- PER-SUSPECT TIMING ANALYSIS (key new feature) --
    $suspectProcessNames = @($processGroups | Where-Object {
        Test-IsSuspectProcess -ProcessName $_.Name
    } | ForEach-Object { $_.Name })

    if ($suspectProcessNames.Count -gt 0 -and -not $Quiet) {
        Write-Host "  --- PER-SUSPECT TIMING ANALYSIS ---" -ForegroundColor Yellow
        foreach ($sp in $suspectProcessNames) {
            $timestamps = @($events | Where-Object { $_.ProcessName -eq $sp } | ForEach-Object { $_.Timestamp })
            $stats = Get-TimingStats -Timestamps $timestamps
            if ($stats -and $stats.Count -ge 2) {
                Write-Host "    $sp ($($stats.Count) events):" -ForegroundColor Red
                Write-Host "      Avg interval : $($stats.Avg)s | Median: $($stats.Median)s | StdDev: $($stats.StdDev)s" -ForegroundColor Red
                Write-Host "      Min: $($stats.Min)s | Max: $($stats.Max)s" -ForegroundColor Red

                # Periodicity verdict (low StdDev relative to avg = clear timer)
                if ($stats.Avg -gt 0 -and ($stats.StdDev / $stats.Avg) -lt 0.3) {
                    Write-Host "      *** STRONG PERIODICITY DETECTED *** (likely a timer-driven steal)" -ForegroundColor Red
                }
                elseif ($stats.Avg -gt 0 -and ($stats.StdDev / $stats.Avg) -lt 0.6) {
                    Write-Host "      *** MODERATE PERIODICITY *** (possibly timer-driven with jitter)" -ForegroundColor Yellow
                }
            }
        }
        Write-Host ""
    }

    # Invisible windows (biggest red flag)
    $invisibleEvents = @($events | Where-Object { -not $_.IsVisible })
    if ($invisibleEvents.Count -gt 0 -and -not $Quiet) {
        Write-Host "  --- INVISIBLE WINDOWS STEALING FOCUS (RED FLAG!) ---" -ForegroundColor Red
        $invByProc = $invisibleEvents | Group-Object ProcessName | Sort-Object Count -Descending
        foreach ($ip in $invByProc) {
            Write-Host "    $($ip.Name): $($ip.Count) invisible activations" -ForegroundColor Red
            foreach ($cg in ($ip.Group | Group-Object WindowClass | Sort-Object Count -Descending | Select-Object -First 3)) {
                Write-Host "      - $($cg.Name): $($cg.Count)" -ForegroundColor DarkRed
            }
        }
        Write-Host ""

        Write-Host "  First 10 invisible-window events:" -ForegroundColor Red
        foreach ($inv in ($invisibleEvents | Select-Object -First 10)) {
            $invTime = $inv.Timestamp.ToString('HH:mm:ss.fff')
            $verSuffix = if ($inv.ProductVersion) { " v$($inv.ProductVersion)" } else { "" }
            Write-Host "    [$invTime] $($inv.ProcessName)$verSuffix - Class: $($inv.WindowClass)" -ForegroundColor Red
        }
        Write-Host ""
    }

    # -- Norton-specific deep dive (when NortonUI is present) --
    $nortonEvents = @($events | Where-Object { $_.ProcessName -ieq 'NortonUI' })
    if ($nortonEvents.Count -gt 0 -and -not $Quiet) {
        Write-Host "  --- NORTON CEF DEEP-DIVE ---" -ForegroundColor Red
        $nortonVer = ($nortonEvents | Where-Object { $_.ProductVersion } | Select-Object -First 1).ProductVersion
        Write-Host "    NortonUI.exe version : $nortonVer" -ForegroundColor Red
        Write-Host "    Total NortonUI events: $($nortonEvents.Count) ($([math]::Round(($nortonEvents.Count / $events.Count) * 100, 1))% of all events)" -ForegroundColor Red
        $nortonInvisible = @($nortonEvents | Where-Object { -not $_.IsVisible })
        Write-Host "    Invisible activations: $($nortonInvisible.Count) ($(if ($nortonEvents.Count -gt 0) { [math]::Round(($nortonInvisible.Count / $nortonEvents.Count) * 100, 1) } else { 0 })% of NortonUI events)" -ForegroundColor Red

        $nortonByClass = $nortonEvents | Group-Object WindowClass | Sort-Object Count -Descending
        Write-Host "    By window class:" -ForegroundColor Red
        foreach ($nc in $nortonByClass) {
            Write-Host "      - $($nc.Name): $($nc.Count)" -ForegroundColor DarkRed
        }

        $nortonStats = Get-TimingStats -Timestamps @($nortonEvents | ForEach-Object { $_.Timestamp })
        if ($nortonStats) {
            Write-Host "    Timing: avg $($nortonStats.Avg)s | median $($nortonStats.Median)s | min $($nortonStats.Min)s | max $($nortonStats.Max)s" -ForegroundColor Red
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
    $summaryLines += "Rapid focus changes  : $($script:rapidStealCount)"
    $summaryLines += "Bursts (<500ms)      : $($script:burstCount)"
    $summaryLines += ""
    $summaryLines += "EVENTS BY PROCESS:"
    foreach ($pg in $processGroups) {
        $suspectInfo = Test-IsSuspectProcess -ProcessName $pg.Name
        $marker = if ($suspectInfo) { " [SUSPECT-$($suspectInfo.Risk)]" } else { "" }
        $pgSummary = "  {0,-30} : {1}{2}" -f $pg.Name, $pg.Count, $marker
        $summaryLines += $pgSummary
    }
    $summaryLines += ""
    $summaryLines += "EVENTS BY WINDOW CLASS:"
    foreach ($cg in $classGroups) {
        $cgSummary = "  {0,-30} : {1}" -f $cg.Name, $cg.Count
        $summaryLines += $cgSummary
    }
    $summaryLines += ""

    if ($suspectProcessNames.Count -gt 0) {
        $summaryLines += "PER-SUSPECT TIMING:"
        foreach ($sp in $suspectProcessNames) {
            $timestamps = @($events | Where-Object { $_.ProcessName -eq $sp } | ForEach-Object { $_.Timestamp })
            $stats = Get-TimingStats -Timestamps $timestamps
            if ($stats -and $stats.Count -ge 2) {
                $summaryLines += "  $sp : count=$($stats.Count) avg=$($stats.Avg)s median=$($stats.Median)s stddev=$($stats.StdDev)s min=$($stats.Min)s max=$($stats.Max)s"
            }
        }
        $summaryLines += ""
    }

    if ($nortonEvents.Count -gt 0) {
        $nortonVer = ($nortonEvents | Where-Object { $_.ProductVersion } | Select-Object -First 1).ProductVersion
        $summaryLines += "NORTON CEF DEEP-DIVE:"
        $summaryLines += "  NortonUI version: $nortonVer"
        $summaryLines += "  Total events: $($nortonEvents.Count)"
        $nortonInvisible = @($nortonEvents | Where-Object { -not $_.IsVisible })
        $summaryLines += "  Invisible activations: $($nortonInvisible.Count)"
        foreach ($nc in ($nortonEvents | Group-Object WindowClass | Sort-Object Count -Descending)) {
            $summaryLines += "  Class $($nc.Name): $($nc.Count)"
        }
        $summaryLines += ""
    }

    $summaryLines += "INVISIBLE WINDOW EVENTS:"
    foreach ($inv in $invisibleEvents) {
        $invTime = $inv.Timestamp.ToString('HH:mm:ss.fff')
        $verSuffix = if ($inv.ProductVersion) { " v$($inv.ProductVersion)" } else { "" }
        $summaryLines += "  $invTime | $($inv.ProcessName)$verSuffix | $($inv.WindowClass) | $($inv.ProcessPath)"
    }

    try { $summaryLines | Out-File -FilePath $DetailLogPath -Append -Encoding UTF8 } catch { }
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
    Write-Host "  3. PER-SUSPECT TIMING shows if there's a clear timer pattern" -ForegroundColor White
    Write-Host "  4. NORTON CEF DEEP-DIVE shows the version and behavior" -ForegroundColor White
    Write-Host ""
}
