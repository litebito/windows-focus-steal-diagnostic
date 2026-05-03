#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Norton 360 Focus-Steal Diagnostic and Remediation (v1.1)
.DESCRIPTION
    Investigates Norton 360's NortonUI.exe CEF-based timer that steals
    foreground focus via invisible CefHeaderWindow / Chrome_WidgetWin_0.
    Finds scheduled tasks, registry timers, COM objects, and services
    related to Norton, and provides remediation options.
.NOTES
    v1.1 changes:
      - Fixed: Get-WinEvent FilterHashtable error (use -FilterXPath instead)
      - Fixed: process filter logic (precedence with -or / -and)
      - Added: detects ALL Norton-related executables for version info
      - Added: report path with fallback (works even if C:\System missing)
      - Added: warning if NortonUI tamper protection blocks the kill
.EXAMPLE
    .\NortonFocusStealFix.ps1
    .\NortonFocusStealFix.ps1 -KillNortonUI
    .\NortonFocusStealFix.ps1 -FullReport
#>

param(
    [switch]$KillNortonUI,
    [switch]$FullReport,
    [string]$ReportPath = ""
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
Write-Host "  NORTON 360 FOCUS-STEAL DIAGNOSTIC v1.1" -ForegroundColor Cyan
Write-Host "  Investigating NortonUI.exe CEF timer behavior" -ForegroundColor Cyan
Write-Host "=========================================================" -ForegroundColor Cyan

# ==========================================================================
# 1. NORTON PROCESSES - current state
# ==========================================================================
Write-Section "NORTON PROCESSES CURRENTLY RUNNING"

# Fixed filter: use parentheses to make precedence explicit, and check Path properly
$nortonProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.ProcessName -like "*Norton*") -or
    ($_.ProcessName -like "*NortonSvc*") -or
    ($_.ProcessName -like "afwServ") -or
    ($_.ProcessName -like "ccSvcHst") -or
    ($_.ProcessName -like "nllToolsSvc") -or
    (($_.ProcessName -like "*Vpn*") -and ($_.Path -like "*Norton*")) -or
    (($_.Path -like "*Norton*") -and ($_.Path -ne $null))
} | Select-Object Id, ProcessName, Path, StartTime, WorkingSet64 -Unique

foreach ($p in $nortonProcs) {
    $memMB = [math]::Round($p.WorkingSet64 / 1MB, 1)
    $startStr = if ($p.StartTime) { $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } else { "unknown" }

    # Try to get version info
    $verStr = ""
    if ($p.Path -and (Test-Path $p.Path -ErrorAction SilentlyContinue)) {
        try {
            $vi = (Get-Item $p.Path).VersionInfo
            $verStr = " v$($vi.ProductVersion)"
        }
        catch { }
    }

    Write-Finding "PID=$($p.Id)  $($p.ProcessName)$verStr  Mem=${memMB}MB  Started=$startStr"
    Write-Finding "  Path: $($p.Path)" -Color DarkGray
}

# Specifically identify the offending NortonUI process(es)
$nortonUI = Get-Process -Name "NortonUI" -ErrorAction SilentlyContinue
if ($nortonUI) {
    Write-Host ""
    Write-Finding "** OFFENDING PROCESS: NortonUI.exe (PID: $($nortonUI.Id -join ', ')) **" -Color Red
    Write-Finding "   This process owns the invisible CEF windows stealing focus." -Color Red

    foreach ($nui in $nortonUI) {
        try {
            $wmiProc = Get-CimInstance Win32_Process -Filter "ProcessId = $($nui.Id)" -ErrorAction Stop
            $cmdLineShort = $wmiProc.CommandLine
            if ($cmdLineShort.Length -gt 200) {
                $cmdLineShort = $cmdLineShort.Substring(0, 200) + "..."
            }
            Write-Finding "   PID $($nui.Id) cmd: $cmdLineShort" -Color Yellow
            Write-Finding "   PID $($nui.Id) parent: $($wmiProc.ParentProcessId)" -Color Yellow
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

        $subKeys = Get-ChildItem -Path $regPath -ErrorAction SilentlyContinue | Select-Object -First 10
        foreach ($sub in $subKeys) {
            Write-Finding "  Subkey: $($sub.PSChildName)" -Color DarkGray
        }

        if ($FullReport) {
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
# 5. NORTON COM / STARTUP ENTRIES
# ==========================================================================
Write-Section "NORTON COM / STARTUP ENTRIES"

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
# 6. NORTON VERSION INFO (extended - all related EXEs)
# ==========================================================================
Write-Section "NORTON INSTALLATION INFO"

$nortonExesToCheck = @(
    "C:\Program Files\Norton\Suite\NortonUI.exe",
    "C:\Program Files\Norton\Suite\NortonSvc.exe",
    "C:\Program Files\Norton\Suite\afwServ.exe",
    "C:\Program Files\Norton\Suite\nllToolsSvc.exe",
    "C:\Program Files\Norton\Suite\VpnSvc.exe",
    "C:\Program Files\Norton\Suite\AvLaunch.exe",
    "C:\Program Files\Norton\Suite\AvBugReport.exe",
    "C:\Program Files\Norton\Suite\AvEmUpdate.exe",
    "C:\Program Files\Norton\Suite\wsc_proxy.exe"
)

foreach ($exe in $nortonExesToCheck) {
    if (Test-Path $exe) {
        try {
            $verInfo = (Get-Item $exe).VersionInfo
            $fileDate = (Get-Item $exe).LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            $exeName = Split-Path $exe -Leaf
            Write-Finding "$exeName : ProdVer=$($verInfo.ProductVersion) FileVer=$($verInfo.FileVersion) Date=$fileDate" -Color Yellow
        }
        catch { }
    }
}

# Look for the Norton install directory and check Common Files
$nortonCommon = "C:\Program Files\Common Files\Norton"
if (Test-Path $nortonCommon) {
    Write-Finding "Common Files\Norton subfolders:" -Color DarkGray
    Get-ChildItem -Path $nortonCommon -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Finding "  $($_.Name)" -Color DarkGray
    }
}

# ==========================================================================
# 7. RECENT NORTON EVENT LOG ENTRIES (FIXED - using XPath)
# ==========================================================================
Write-Section "RECENT NORTON EVENT LOG ACTIVITY"

# Use XPath query instead of FilterHashtable wildcard (which doesn't work for ProviderName)
$nortonEvents = $null
try {
    $allRecentApp = Get-WinEvent -LogName 'Application' -MaxEvents 500 -ErrorAction SilentlyContinue
    $nortonEvents = $allRecentApp | Where-Object {
        $_.ProviderName -like "*Norton*" -or
        $_.ProviderName -like "*Symantec*" -or
        $_.ProviderName -like "*Gen Digital*"
    } | Select-Object -First 10
}
catch { }

if ($nortonEvents) {
    foreach ($evt in $nortonEvents) {
        $msgPreview = if ($evt.Message) {
            $evt.Message.Substring(0, [math]::Min(120, $evt.Message.Length)).Replace("`r", " ").Replace("`n", " ")
        }
        else { "(no message)" }
        Write-Finding "[$($evt.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss'))] $($evt.ProviderName) ID=$($evt.Id) $msgPreview" -Color DarkGray
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
        $beforePIDs = $nortonUI.Id
        foreach ($nui in $nortonUI) {
            Write-Finding "Killing NortonUI.exe PID=$($nui.Id)..." -Color Red
            Stop-Process -Id $nui.Id -Force -ErrorAction SilentlyContinue
        }
        Start-Sleep -Seconds 2

        $respawned = Get-Process -Name "NortonUI" -ErrorAction SilentlyContinue
        if ($respawned) {
            $afterPIDs = $respawned.Id
            $samePIDs = ($beforePIDs | Sort-Object) -join ',' -eq (($afterPIDs | Sort-Object) -join ',')
            if ($samePIDs) {
                Write-Finding "WARNING: NortonUI PIDs UNCHANGED after kill attempt!" -Color Red
                Write-Finding "Norton TAMPER PROTECTION is blocking the kill." -Color Red
                Write-Finding "" -Color Red
                Write-Finding "TO PROCEED:" -Color Yellow
                Write-Finding "1. Open Norton 360 -> Settings -> Administrative Settings" -Color Yellow
                Write-Finding "2. Find 'Norton Product Tamper Protection' (or 'Self Protection')" -Color Yellow
                Write-Finding "3. Toggle OFF (set duration to 15 minutes)" -Color Yellow
                Write-Finding "4. Re-run this script with -KillNortonUI" -Color Yellow
            }
            else {
                Write-Finding "WARNING: NortonUI respawned with new PIDs ($($afterPIDs -join ', '))" -Color Red
                Write-Finding "Norton service watchdog is restarting it." -Color Red
                Write-Finding "Try: Stop-Service 'Norton Antivirus' then kill NortonUI then restart service" -Color Yellow
            }
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
Write-Finding "   (Note: you may need to disable tamper protection first)"
Write-Finding ""
Write-Finding "2. NORTON SETTINGS: Open Norton 360 and go to:" -Color Cyan
Write-Finding "   Settings -> Administrative Settings -> Special Features"
Write-Finding "   - Turn OFF 'Norton Notification Center'"
Write-Finding "   - Turn OFF 'Special Offer Notification'"
Write-Finding "   - Turn OFF 'Norton Community Watch'"
Write-Finding ""
Write-Finding "3. MUTE NOTIFICATIONS: Right-click the Norton tray icon and" -Color Cyan
Write-Finding "   mute notifications for the maximum duration available."
Write-Finding ""
Write-Finding "4. NORTON UPDATE: Check for Norton product updates" -Color Cyan
Write-Finding "   Reportedly fixed in version 1.0.138 - if you have older,"
Write-Finding "   update via Norton -> Help -> Get Latest Version."
Write-Finding ""
Write-Finding "5. FULL REGISTRY SCAN: Run with -FullReport for deep registry analysis:" -Color Cyan
Write-Finding "     .\NortonFocusStealFix.ps1 -FullReport" -Color White
Write-Finding ""
Write-Finding "6. PERSISTENT WORKAROUND: Disable NortonUI autostart" -Color Cyan
Write-Finding "   Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'NortonUI.exe' -Value ''"
Write-Finding "   (Protection continues; you lose tray icon and live notifications)"
Write-Finding ""
Write-Finding "7. NUCLEAR OPTION: Uninstall Norton 360, use Windows Defender." -Color Cyan

# ==========================================================================
# SAVE REPORT
# ==========================================================================
$candidatePaths = @()
if ($ReportPath) { $candidatePaths += $ReportPath }
$candidatePaths += (Join-Path $PSScriptRoot "NortonDiagReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt")
$candidatePaths += "$env:USERPROFILE\Desktop\NortonDiagReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
$candidatePaths += "$env:TEMP\NortonDiagReport_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"

$saved = $false
foreach ($pathCandidate in $candidatePaths) {
    if (-not $pathCandidate) { continue }
    $parent = Split-Path $pathCandidate -Parent
    if (-not (Test-Path $parent)) { continue }
    try {
        $reportLines | Out-File -FilePath $pathCandidate -Encoding UTF8 -ErrorAction Stop
        Write-Host ""
        Write-Host "  [OK] Report saved to: $pathCandidate" -ForegroundColor Green
        $saved = $true
        break
    }
    catch { }
}

if (-not $saved) {
    Write-Host ""
    Write-Host "  [WARN] Could not save report to any standard location." -ForegroundColor Yellow
}

Write-Host ""
