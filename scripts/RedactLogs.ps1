#Requires -Version 5.1
<#
.SYNOPSIS
    Redact personally identifiable information from focus-steal diagnostic logs.
.DESCRIPTION
    Cleans diagnostic logs for safe public sharing. Three layers of redaction:

    1. STRING REDACTION — replaces:
       - Windows username (from $env:USERNAME)
       - User's full display name (from local account / Microsoft account)
       - User profile folder name (e.g. C:\Users\John D\...)
       - Computer name (from $env:COMPUTERNAME)
       - Any extra strings passed via -ExtraStrings

    2. WINDOW TITLE SCRUBBING — for processes that frequently leak info via
       the window title (browsers, Office apps, mail clients, IDEs):
       - Replaces the WindowTitle field in CSV files with "[REDACTED-TITLE]"
       - Replaces "Title=..." in detail TXT logs
       - The process name, window class, and timing data are preserved
         (so the focus-steal evidence is intact, but private info is not)

    3. OPTIONAL LINE REMOVAL — drop entire CSV rows or detail-log entries
       matching a process name or substring (use with care — this loses data).

    By default, browsers and Office/productivity apps have their titles scrubbed.
.PARAMETER Path
    File or wildcard to redact (e.g. "C:\System\*.csv").
.PARAMETER ExtraStrings
    Additional strings to redact (replaced with "REDACTED").
.PARAMETER ScrubTitlesFor
    Process names whose WindowTitle should be scrubbed. Defaults to a
    sensible set of browsers and productivity apps. Pass @() to disable.
.PARAMETER DropLinesFor
    Process names whose entire log lines should be REMOVED. Empty by default.
    Use this only when title scrubbing isn't enough (e.g. a custom internal
    tool whose mere presence is sensitive).
.PARAMETER DropLinesMatching
    Free-form substrings — any line containing one of these is dropped entirely.
.PARAMETER InPlace
    Overwrite the original files instead of creating "_redacted" copies.
.PARAMETER OutputSuffix
    Suffix for output files when -InPlace is not used. Default: "_redacted".
.EXAMPLE
    # Redact a single CSV with default settings (creates _redacted copy)
    .\RedactLogs.ps1 -Path "C:\System\FocusStealLog.csv"
.EXAMPLE
    # Redact all logs in a folder, in place, also remove an internal tool
    .\RedactLogs.ps1 -Path ".\logs\mine\*" -InPlace -DropLinesFor @("MyInternalTool")
.EXAMPLE
    # Pass extra strings (e.g. domain names) and disable title scrubbing
    .\RedactLogs.ps1 -Path ".\*.csv" -ExtraStrings @("acme.local") -ScrubTitlesFor @()
#>

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,
    [string[]]$ExtraStrings = @(),
    [string[]]$ScrubTitlesFor = @(
        # Browsers
        'chrome', 'firefox', 'msedge', 'opera', 'brave', 'vivaldi',
        'iexplore', 'safari', 'arc', 'librewolf', 'tor', 'waterfox',
        # Microsoft Office / 365
        'winword', 'excel', 'powerpnt', 'outlook', 'onenote', 'msaccess',
        'mspub', 'visio', 'project', 'lync', 'teams', 'ms-teams',
        'olk', 'onedrive', 'mso',
        # Google / web apps run as PWAs typically appear under chrome/msedge
        # WhatsApp, Discord, Slack — often show conversation titles
        'whatsapp', 'discord', 'slack', 'telegram', 'signal',
        'zoom', 'webex', 'gotomeeting',
        # Apple iCloud / iTunes
        'icloud', 'itunes',
        # Mail clients
        'thunderbird', 'mailbird', 'em_client', 'emclient',
        # Text editors / IDEs that can show document/file paths
        'code', 'cursor', 'devenv', 'rider', 'idea', 'pycharm',
        'webstorm', 'phpstorm', 'goland', 'clion', 'rubymine',
        'datagrip', 'notepad', 'notepad++', 'sublime_text',
        'atom', 'vim', 'gvim', 'emacs',
        # Note-taking apps
        'obsidian', 'notion', 'logseq', 'evernote', 'joplin',
        # PDF readers
        'acrord32', 'acrobat', 'foxitreader', 'sumatrapdf',
        # Other potentially-leaky apps
        'explorer', 'cmd', 'powershell', 'pwsh', 'windowsterminal'
    ),
    [string[]]$DropLinesFor = @(),
    [string[]]$DropLinesMatching = @(),
    [switch]$InPlace,
    [string]$OutputSuffix = "_redacted"
)

# ── Build PII string-replacement list ─────────────────────────────────────
$replacements = @{}

$userName = $env:USERNAME
if ($userName) { $replacements[$userName] = "REDACTED" }

# Try to get the user's full display name
try {
    $userAccount = Get-CimInstance -ClassName Win32_UserAccount -Filter "Name='$userName' AND LocalAccount=True" -ErrorAction SilentlyContinue
    if ($userAccount -and $userAccount.FullName) {
        $replacements[$userAccount.FullName] = "REDACTED"
    }
}
catch { }

# User profile folder name (may differ from username if MS account)
try {
    $profileItems = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\*" -ErrorAction SilentlyContinue
    foreach ($item in $profileItems) {
        if ($item.ProfileImagePath -and $item.ProfileImagePath -like "C:\Users\*") {
            $folderName = Split-Path $item.ProfileImagePath -Leaf
            if ($folderName -and $folderName -ne $userName -and $folderName -notin @('Public', 'Default', 'Default User', 'All Users')) {
                $replacements[$folderName] = "REDACTED"
            }
        }
    }
}
catch { }

# Computer name
$computerName = $env:COMPUTERNAME
if ($computerName) { $replacements[$computerName] = "REDACTED-PC" }

# Extra strings
foreach ($s in $ExtraStrings) {
    if ($s) { $replacements[$s] = "REDACTED" }
}

# Build a set of process names (case-insensitive) for quick checks
$scrubTitlesLower = @{}
foreach ($p in $ScrubTitlesFor) {
    if ($p) { $scrubTitlesLower[$p.ToLower()] = $true }
}

$dropLinesForLower = @{}
foreach ($p in $DropLinesFor) {
    if ($p) { $dropLinesForLower[$p.ToLower()] = $true }
}

# ── Print plan ────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "Redaction plan:" -ForegroundColor Cyan
Write-Host "  String replacements:" -ForegroundColor Gray
foreach ($k in $replacements.Keys) {
    Write-Host "    '$k' -> '$($replacements[$k])'" -ForegroundColor DarkGray
}
if ($scrubTitlesLower.Count -gt 0) {
    Write-Host "  Scrub WindowTitle for processes: $($ScrubTitlesFor -join ', ')" -ForegroundColor Gray
}
if ($dropLinesForLower.Count -gt 0) {
    Write-Host "  DROP lines for processes: $($DropLinesFor -join ', ')" -ForegroundColor Yellow
}
if ($DropLinesMatching.Count -gt 0) {
    Write-Host "  DROP lines containing: $($DropLinesMatching -join ', ')" -ForegroundColor Yellow
}
Write-Host ""

# ── Resolve files ────────────────────────────────────────────────────────
$files = Get-ChildItem -Path $Path -File -ErrorAction SilentlyContinue
if (-not $files) {
    Write-Error "No files matched: $Path"
    exit 1
}

# ── Helper: should this row/line be dropped? ─────────────────────────────
function Test-ShouldDrop {
    param([string]$ProcessName, [string]$LineText)
    if ($ProcessName -and $dropLinesForLower.Count -gt 0) {
        if ($dropLinesForLower.ContainsKey($ProcessName.ToLower())) { return $true }
    }
    foreach ($substr in $DropLinesMatching) {
        if ($substr -and $LineText -like "*$substr*") { return $true }
    }
    return $false
}

# ── Helper: should this process's title be scrubbed? ─────────────────────
function Test-ShouldScrubTitle {
    param([string]$ProcessName)
    if (-not $ProcessName) { return $false }
    return $scrubTitlesLower.ContainsKey($ProcessName.ToLower())
}

# ── Helper: apply string replacements to text ────────────────────────────
function Invoke-StringReplacements {
    param([string]$Text)
    foreach ($search in $replacements.Keys) {
        if ([string]::IsNullOrEmpty($search)) { continue }
        $pattern = [regex]::Escape($search)
        $Text = [regex]::Replace($Text, $pattern, $replacements[$search],
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }
    return $Text
}

# ── Process each file ────────────────────────────────────────────────────
foreach ($file in $files) {
    Write-Host "Processing: $($file.FullName)" -ForegroundColor Yellow

    $isCsv = $file.Extension -ieq ".csv"
    $stats = @{
        StringReplacements = 0
        TitlesScrubbed = 0
        LinesDropped = 0
    }

    try {
        if ($isCsv) {
            # CSV: parse, redact, re-export
            $rows = Import-Csv -Path $file.FullName -Encoding UTF8 -ErrorAction Stop

            $newRows = New-Object System.Collections.Generic.List[object]
            $hasProcessName = $false
            $hasWindowTitle = $false
            if ($rows.Count -gt 0) {
                $hasProcessName = $rows[0].PSObject.Properties.Name -contains 'ProcessName'
                $hasWindowTitle = $rows[0].PSObject.Properties.Name -contains 'WindowTitle'
            }

            foreach ($row in $rows) {
                $procName = if ($hasProcessName) { $row.ProcessName } else { "" }

                # Drop?
                if (Test-ShouldDrop -ProcessName $procName -LineText ($row | Out-String)) {
                    $stats.LinesDropped++
                    continue
                }

                # Scrub title?
                if ($hasWindowTitle -and (Test-ShouldScrubTitle -ProcessName $procName)) {
                    if (-not [string]::IsNullOrEmpty($row.WindowTitle)) {
                        $row.WindowTitle = "[REDACTED-TITLE]"
                        $stats.TitlesScrubbed++
                    }
                }

                # Apply string replacements to ALL string fields
                foreach ($prop in $row.PSObject.Properties) {
                    if ($prop.Value -is [string] -and $prop.Value) {
                        $original = $prop.Value
                        $redacted = Invoke-StringReplacements -Text $original
                        if ($original -ne $redacted) {
                            $row.($prop.Name) = $redacted
                            $stats.StringReplacements++
                        }
                    }
                }

                $newRows.Add($row)
            }

            # Determine output path
            if ($InPlace) {
                $outPath = $file.FullName
            }
            else {
                $base = $file.BaseName
                $ext = $file.Extension
                $outPath = Join-Path $file.DirectoryName "$base$OutputSuffix$ext"
            }

            $newRows | Export-Csv -Path $outPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        }
        else {
            # Text file: process line by line
            $lines = Get-Content -Path $file.FullName -Encoding UTF8 -ErrorAction Stop

            $newLines = New-Object System.Collections.Generic.List[string]

            foreach ($line in $lines) {
                # Try to extract process name from focus-event detail format:
                # "[HH:mm:ss.fff] FOREGROUND | dt=... | PID=#### (procname) | Class=... | Title=... | ..."
                # Older format:
                # "[HH:mm:ss.fff] FOREGROUND | PID=#### (procname) | Class=... | Title=... | ..."
                $procName = ""
                if ($line -match 'PID=\d+\s*\(([^)]+)\)') {
                    $procName = $Matches[1]
                }

                # Drop?
                if (Test-ShouldDrop -ProcessName $procName -LineText $line) {
                    $stats.LinesDropped++
                    continue
                }

                # Scrub title in detail-log lines: "Title=<text> | Visible=..."
                # We replace everything between "Title=" and the next " | " separator
                if ((Test-ShouldScrubTitle -ProcessName $procName) -and $line -match 'Title=') {
                    $newLine = [regex]::Replace($line,
                        '(Title=)([^|]*?)(\s*\|)',
                        '${1}[REDACTED-TITLE]${3}')
                    if ($newLine -ne $line) {
                        $line = $newLine
                        $stats.TitlesScrubbed++
                    }
                }

                # Apply string replacements
                $original = $line
                $line = Invoke-StringReplacements -Text $line
                if ($line -ne $original) { $stats.StringReplacements++ }

                $newLines.Add($line)
            }

            if ($InPlace) {
                $outPath = $file.FullName
            }
            else {
                $base = $file.BaseName
                $ext = $file.Extension
                $outPath = Join-Path $file.DirectoryName "$base$OutputSuffix$ext"
            }

            Set-Content -Path $outPath -Value $newLines -Encoding UTF8 -ErrorAction Stop
        }

        $totalChanges = $stats.StringReplacements + $stats.TitlesScrubbed + $stats.LinesDropped
        if ($totalChanges -eq 0) {
            Write-Host "  No PII found - file passed through unchanged" -ForegroundColor Green
        }
        else {
            Write-Host "  Wrote: $outPath" -ForegroundColor Green
            Write-Host "    String replacements: $($stats.StringReplacements)" -ForegroundColor DarkGray
            Write-Host "    Window titles scrubbed: $($stats.TitlesScrubbed)" -ForegroundColor DarkGray
            if ($stats.LinesDropped -gt 0) {
                Write-Host "    Lines DROPPED: $($stats.LinesDropped)" -ForegroundColor Yellow
            }
        }
    }
    catch {
        Write-Warning "  Could not process file: $_"
    }
}

Write-Host ""
Write-Host "Done. Always review the redacted files before sharing publicly." -ForegroundColor Cyan
Write-Host "  Open them, search for any of: your name, email, network shares, IP addresses," -ForegroundColor Cyan
Write-Host "  license keys, internal hostnames or domain names." -ForegroundColor Cyan
Write-Host ""
