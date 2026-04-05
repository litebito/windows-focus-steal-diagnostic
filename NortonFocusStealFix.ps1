#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Norton 360 Focus-Steal Diagnostic and Remediation
.DESCRIPTION
    Investigates Norton 360's NortonUI.exe CEF-based timer that steals
    foreground focus via invisible CefHeaderWindow / Chrome_WidgetWin_0.
    Finds scheduled tasks, registry timers, COM objects, and services
    related to Norton, and provides remediation options.
.EXAMPLE
    .\NortonFocusStealFix.ps1
    .\NortonFocusStealFix.ps1 -KillNortonUI
    .\NortonFocusStealFix.ps1 -FullReport
#>

param(
    [switch]$KillNortonUI,
    [switch]$FullReport
)

$reportLines = @()

function Write-Section {
    param([string]$Title)
    $line = "--- $Title ---"
    Write-Host ""
    Write-Host $line -ForegroundColor Cyan
    $script:reportLines += ""
    $script:reportLines += $line
}

function Write-Finding {
    param(
        [string]$Text,
        [string]$Color = 'White'
    )
    Write-Host "  $Text" -ForegroundColor $Color
    $script:reportLines += "  $Text"
}

Write-Host ""
Write-Host "=========================================================" -ForegroundColor Cyan
Write-Host "  NORTON 360 FOCUS-STEAL DIAGNOSTIC" -ForegroundColor Cyan
Write-Host "  Investigating NortonUI.exe CEF timer behavior" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# ==========================================================================
# 1. NORTON PROCESSES - current state
# ==========================================================================
Write-Section "NORTON PROCESSES CURRENTLY RUNNING"

$nortonProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ProcessName -like "*Norton*" -or
    $_.ProcessName -like "*NortonSvc*" -or
    $_.ProcessName -like "*NS*" -or
    $_.ProcessName -like "*Vpn*" -and $_.Path -like "*Norton*"
} | Select-Object Id, ProcessName, Path, StartTime, WorkingSet64

foreach ($p in $nortonProcs) {
    $memMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
    $startStr = if ($p.StartTime) { $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } else { "unknown" }
    Write-Finding "PID=$($p.Id)  $($p.ProcessName)  Mem=${memMB}MB  Started=$startStr"
    Write-Finding "  Path: $($p.Path)" -Color DarkGray
}

# Specifically identify the offending NortonUI process(es)
$nortonUI = Get-Process -Name "NortonUI" -ErrorAction SilentlyContinue
if ($nortonUI) {
    Write-Host ""
    Write-Finding "** OFFENDING PROCESS: NortonUI.exe (PID: $($nortonUI.Id -join ', ')) **" -Color Red
    Write-Finding "   This process owns the invisible CEF windows stealing focus." -Color Red

    # Get command line for NortonUI
    foreach ($nui in $nortonUI) {
        try {
            $wmiProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($nui.Id)" -ErrorAction Stop
            Write-Finding "   Command Line: $($wmiProc.CommandLine)" -Color Yellow
            Write-Finding "   Parent PID: $($wmiProc.ParentProcessId)" -Color Yellow

            # Identify parent
            try {
                $parentProc = Get-Process -Id $wmiProc.ParentProcessId -ErrorAction Stop
                Write-Finding "   Parent Process: $($parentProc.ProcessName) ($($parentProc.Path))" -Color Yellow
            }
            catch {
                Write-Finding "   Parent Process: EXITED (PID $($wmiProc.ParentProcessId))" -Color DarkYellow
            }
        }
        catch {
            Write-Finding "   Could not retrieve WMI details for PID $($nui.Id)" -Color DarkGray
        }
    }
}

# ==========================================================================
# 2. NORTON SCHEDULED TASKS
# ==========================================================================
Write-Section "NORTON SCHEDULED TASKS"

$nortonTasks = Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
    $_.TaskPath -like "*Norton*" -or
    $_.TaskName -like "*Norton*" -or
    $_.TaskPath -like "*Symantec*" -or
    $_.TaskName -like "*Symantec*" -or
    $_.TaskPath -like "*NortonLifeLock*" -or
    $_.TaskName -like "*NortonLifeLock*" -or
    $_.TaskPath -like "*Gen Digital*" -or
    $_.TaskName -like "*Gen Digital*"
}

if ($nortonTasks) {
    foreach ($task in $nortonTasks) {
        $taskInfo = Get-ScheduledTaskInfo -TaskName $task.TaskName -TaskPath $task.TaskPath -ErrorAction SilentlyContinue
        $lastRun = if ($taskInfo.LastRunTime) { $taskInfo.LastRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { "Never" }
        $nextRun = if ($taskInfo.NextRunTime) { $taskInfo.NextRunTime.ToString('yyyy-MM-dd HH:mm:ss') } else { "None" }

        Write-Finding "Task: $($task.TaskPath)$($task.TaskName)" -Color Yellow
        Write-Finding "  State    : $($task.State)"
        Write-Finding "  Last Run : $lastRun"
        Write-Finding "  Next Run : $nextRun"

        # Check triggers
        foreach ($trigger in $task.Triggers) {
            $triggerType = $trigger.CimClass.CimClassName
            $rep = $trigger.Repetition
            if ($rep -and $rep.Interval) {
                Write-Finding "  Trigger  : $triggerType - REPEATS EVERY $($rep.Interval)" -Color Red
            }
            else {
                Write-Finding "  Trigger  : $triggerType"
            }
        }

        # Check actions
        foreach ($action in $task.Actions) {
            Write-Finding "  Action   : $($action.Execute) $($action.Arguments)" -Color DarkGray
        }
        Write-Finding ""
    }
}
else {
    Write-Finding "No Norton scheduled tasks found." -Color Green
}

# ==========================================================================
# 3. NORTON SERVICES
# ==========================================================================
Write-Section "NORTON SERVICES"

$nortonServices = Get-Service -ErrorAction SilentlyContinue | Where-Object {
    $_.DisplayName -like "*Norton*" -or
    $_.ServiceName -like "*Norton*" -or
    $_.DisplayName -like "*Symantec*" -or
    $_.ServiceName -like "*Symantec*" -or
    $_.DisplayName -like "*NortonLifeLock*" -or
    $_.DisplayName -like "*Gen Digital*"
}

foreach ($svc in $nortonServices) {
    $svcColor = switch ($svc.Status) {
        'Running' { 'Green' }
        'Stopped' { 'Gray' }
        default   { 'White' }
    }
    Write-Finding "$($svc.ServiceName) [$($svc.Status)] - $($svc.DisplayName)" -Color $svcColor

    # Get the service executable path
    $svcWmi = Get-CimInstance Win32_Service -Filter "Name = '$($svc.ServiceName)'" -ErrorAction SilentlyContinue
    if ($svcWmi) {
        Write-Finding "  Path: $($svcWmi.PathName)" -Color DarkGray
        Write-Finding "  Start: $($svcWmi.StartMode) | PID: $($svcWmi.ProcessId)" -Color DarkGray
    }
}

# ==========================================================================
# 4. NORTON REGISTRY - UI settings, timers, notification config
# ==========================================================================
Write-Section "NORTON REGISTRY SETTINGS"

$regPaths = @(
    'HKLM:\SOFTWARE\Norton',
    'HKLM:\SOFTWARE\Symantec',
    'HKLM:\SOFTWARE\NortonLifeLock',
    'HKLM:\SOFTWARE\Gen Digital',
    'HKLM:\SOFTWARE\WOW6432Node\Norton',
    'HKLM:\SOFTWARE\WOW6432Node\Symantec',
    'HKLM:\SOFTWARE\WOW6432Node\NortonLifeLock',
    'HKCU:\SOFTWARE\Norton',
    'HKCU:\SOFTWARE\Symantec',
    'HKCU:\SOFTWARE\NortonLifeLock'
)

foreach ($regPath in $regPaths) {
    if (Test-Path $regPath) {
        Write-Finding "Found: $regPath" -Color Yellow

        # List immediate subkeys
        $subKeys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue | Select-Object -First 10
        foreach ($sub in $subKeys) {
            Write-Finding "  Subkey: $($sub.PSChildName)" -Color DarkGray
        }

        if ($FullReport) {
            # Deep dive - look for timer/interval/refresh/notification values
            $allValues = Get-ChildItem -Path $regPath -Recurse -ErrorAction SilentlyContinue
            foreach ($item in $allValues) {
                $props = Get-ItemProperty -Path $item.PSPath -ErrorAction SilentlyContinue
                $propNames = $props.PSObject.Properties | Where-Object {
                    $_.Name -notlike "PS*" -and (
                        $_.Name -like "*Timer*" -or
                        $_.Name -like "*Interval*" -or
                        $_.Name -like "*Refresh*" -or
                        $_.Name -like "*Notify*" -or
                        $_.Name -like "*Alert*" -or
                        $_.Name -like "*UI*" -or
                        $_.Name -like "*Status*" -or
                        $_.Name -like "*Update*" -or
                        $_.Name -like "*Heartbeat*" -or
                        $_.Name -like "*Poll*" -or
                        $_.Name -like "*CEF*" -or
                        $_.Name -like "*Silent*"
                    )
                }
                foreach ($pn in $propNames) {
                    Write-Finding "  INTERESTING: $($item.PSPath) -> $($pn.Name) = $($pn.Value)" -Color Magenta
                }
            }
        }
    }
}

# ==========================================================================
# 5. NORTON COM OBJECTS (can trigger UI activation)
# ==========================================================================
Write-Section "NORTON COM / STARTUP ENTRIES"

# Check Run keys
$runPaths = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
    'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
)

foreach ($runPath in $runPaths) {
    if (Test-Path $runPath) {
        $entries = Get-ItemProperty -Path $runPath -ErrorAction SilentlyContinue
        $nortonEntries = $entries.PSObject.Properties | Where-Object {
            $_.Value -like "*Norton*" -or $_.Value -like "*Symantec*"
        }
        foreach ($entry in $nortonEntries) {
            Write-Finding "Startup: [$runPath] $($entry.Name) = $($entry.Value)" -Color Yellow
        }
    }
}

# ==========================================================================
# 6. NORTON VERSION INFO
# ==========================================================================
Write-Section "NORTON INSTALLATION INFO"

$nortonExe = "C:\Program Files\Norton\Suite\NortonUI.exe"
if (Test-Path $nortonExe) {
    $verInfo = (Get-Item $nortonExe).VersionInfo
    Write-Finding "NortonUI.exe Version: $($verInfo.ProductVersion)" -Color Yellow
    Write-Finding "  File Version  : $($verInfo.FileVersion)"
    Write-Finding "  Product Name  : $($verInfo.ProductName)"
    Write-Finding "  Company       : $($verInfo.CompanyName)"
    Write-Finding "  File Date     : $((Get-Item $nortonExe).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))"
}

$nortonSvcExe = Get-Process -Name "NortonSvc" -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Path
if ($nortonSvcExe -and (Test-Path $nortonSvcExe)) {
    $svcVer = (Get-Item $nortonSvcExe).VersionInfo
    Write-Finding "NortonSvc.exe Version: $($svcVer.ProductVersion)" -Color Yellow
}

# ==========================================================================
# 7. RECENT NORTON EVENT LOG ENTRIES
# ==========================================================================
Write-Section "RECENT NORTON EVENT LOG ACTIVITY"

$nortonEvents = Get-WinEvent -FilterHashtable @{
    LogName      = 'Application'
    ProviderName = '*Norton*', '*Symantec*'
} -MaxEvents 10 -ErrorAction SilentlyContinue

if ($nortonEvents) {
    foreach ($evt in $nortonEvents) {
        Write-Finding "[$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] ID=$($evt.Id) $($evt.Message.Substring(0, [math]::Min(120, $evt.Message.Length)))" -Color DarkGray
    }
}
else {
    Write-Finding "No recent Norton events in Application log." -Color DarkGray
}

# ==========================================================================
# 8. KILL NortonUI (optional)
# ==========================================================================
if ($KillNortonUI) {
    Write-Section "KILLING NortonUI PROCESS"

    $nortonUI = Get-Process -Name "NortonUI" -ErrorAction SilentlyContinue
    if ($nortonUI) {
        foreach ($nui in $nortonUI) {
            Write-Finding "Killing NortonUI.exe PID=$($nui.Id)..." -Color Red
            Stop-Process -Id $nui.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2

        # Check if it respawned
        $respawned = Get-Process -Name "NortonUI" -ErrorAction SilentlyContinue
        if ($respawned) {
            Write-Finding "WARNING: NortonUI respawned immediately (PID=$($respawned.Id -join ', '))!" -Color Red
            Write-Finding "Norton's service watchdog is restarting it." -Color Red
            Write-Finding "You may need to disable Norton's service or use Norton's own settings." -Color Yellow
        }
        else {
            Write-Finding "NortonUI killed successfully. It did NOT respawn." -Color Green
            Write-Finding "Monitor if focus stealing has stopped." -Color Green
            Write-Finding "Note: NortonSvc (core protection) is still running." -Color Green
        }
    }
    else {
        Write-Finding "NortonUI is not currently running." -Color Gray
    }
}

# ==========================================================================
# RECOMMENDATIONS
# ==========================================================================
Write-Section "RECOMMENDATIONS"

Write-Finding "1. QUICK TEST: Run this script with -KillNortonUI to kill the UI process" -Color Cyan
Write-Finding "   and confirm the focus stealing stops:"
Write-Finding "     .\NortonFocusStealFix.ps1 -KillNortonUI" -Color White
Write-Finding ""
Write-Finding "2. NORTON SETTINGS: Open Norton 360 and go to:" -Color Cyan
Write-Finding "   Settings -> Administrative Settings -> Special Features"
Write-Finding "   - Turn OFF 'Norton Notification Center'"
Write-Finding "   - Turn OFF 'Special Offer Notification'"
Write-Finding "   - Turn OFF 'Norton Community Watch'"
Write-Finding "   Also check: Settings -> Administrative Settings -> Product Security"
Write-Finding "   - Look for any auto-refresh or status check interval settings"
Write-Finding ""
Write-Finding "3. SILENT MODE: Enable Norton Silent Mode temporarily" -Color Cyan
Write-Finding "   Right-click Norton tray icon -> Enable Silent Mode"
Write-Finding "   If focus stealing stops in Silent Mode, the culprit is"
Write-Finding "   Norton's notification/status refresh system."
Write-Finding ""
Write-Finding "4. NORTON UPDATE: Check for Norton product updates" -Color Cyan
Write-Finding "   This CEF focus-steal bug may be fixed in a newer version."
Write-Finding ""
Write-Finding "5. FULL REGISTRY SCAN: Run with -FullReport for deep registry analysis:" -Color Cyan
Write-Finding "     .\NortonFocusStealFix.ps1 -FullReport" -Color White
Write-Finding ""
Write-Finding "6. NUCLEAR OPTION: If nothing else works, consider uninstalling" -Color Cyan
Write-Finding "   Norton 360 and using Windows Defender (built-in, no focus issues)."

# ==========================================================================
# SAVE REPORT
# ==========================================================================
$reportPath = "C:\System\NortonDiagReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
try {
    $reportLines | Out-File -FilePath $reportPath -Encoding UTF8
    Write-Host ""
    Write-Host "  [OK] Report saved to: $reportPath" -ForegroundColor Green
}
catch {
    $fallbackPath = "$env:TEMP\NortonDiagReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
    $reportLines | Out-File -FilePath $fallbackPath -Encoding UTF8
    Write-Host ""
    Write-Host "  [OK] Report saved to: $fallbackPath" -ForegroundColor Green
}

Write-Host ""
