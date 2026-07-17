# ================================================================
# Windows Auto-Install Script v0.1.0 (TUI Refactored with Advanced Log Levels)
# This program was co-developed with the help of an AI coding assistant.
# ================================================================

#region ── Automatic elevation to administrator (before log creation)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    Start-Process $exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
#endregion

# Logging folder and file definitions (logs under the script root folder)
$SCRIPT_VERSION = "0.1.0"

# Winget exit code constants
# Source: winget-cli (Microsoft.WinGet.Client) public error codes and standard Windows system exit codes.
# Re-verify these when winget has a major version update (last verified: 2026-07-17, against v0.0.11 behavior).
#   -1978335189 (0x8A15005B, APPINSTALLER_CLI_ERROR_PACKAGE_ALREADY_INSTALLED): returned when re-attempting to install an already-installed package
#   3010          (ERROR_SUCCESS_REBOOT_REQUIRED): standard Windows code; install succeeded but a reboot is required
#   1641          (ERROR_SUCCESS_REBOOT_INITIATED): install succeeded and the installer itself triggered a reboot
$script:EXIT_ALREADY_INSTALLED = -1978335189
$script:EXIT_REBOOT_REQUIRED = 3010
$script:EXIT_REBOOT_INITIATED = 1641
$LOG_DIR = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $LOG_DIR)) {
    New-Item -ItemType Directory -Path $LOG_DIR -Force | Out-Null
}
$timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
$LOG_FILE = Join-Path $LOG_DIR "auto-install-log-$timestamp.txt"

"=== Windows Auto-Install v$SCRIPT_VERSION Log ===" | Out-File $LOG_FILE -Force -Encoding UTF8
"Started at: $(Get-Date)" | Out-File $LOG_FILE -Append -Encoding UTF8

# Load shared core functions (logging / visual-width helpers / install detection / error classification).
# Pure logic that does not depend on Windows-only APIs lives in its own file so it can be unit-tested
# independently with Pester (see tests/Core.Tests.ps1).
$CORE_MODULE_PATH = Join-Path $PSScriptRoot "AutoInstaller.Core.ps1"
if (-not (Test-Path $CORE_MODULE_PATH)) {
    Write-Host "Error: could not find the core module file (AutoInstaller.Core.ps1). It must sit next to the script." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}
. $CORE_MODULE_PATH

Write-Log -Level "INFO" -Message "Administrator privileges confirmed."

# Force UTF-8 console code page and I/O encoding (prevents TUI emoji and winget output corruption)
if (Get-Command chcp -ErrorAction SilentlyContinue) {
    $null = & chcp 65001
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

# Force TLS 1.2 (avoids GitHub API and web download errors)
Write-Log -Level "DEBUG" -Message "Setting SecurityProtocol to TLS 1.2."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# (Get-VisualWidth and Get-VisualPadRight now live in AutoInstaller.Core.ps1)

# Box-line output helper for CJK-friendly rendering
function Write-BorderLine {
    param([string]$Content, [string]$Color = "White", [int]$Width = 64)
    $visualWidth = Get-VisualWidth $Content
    $padNeeded = $Width - $visualWidth
    $paddedContent = $Content + (" " * [Math]::Max(0, $padNeeded))
    Write-Host "║$paddedContent║" -ForegroundColor $Color
}

# Safe cursor-position helper (avoids buffer boundary exceptions)
function Set-SafeCursor {
    param([int]$Left, [int]$Top)
    try {
        $maxHeight = [Console]::BufferHeight
        $maxWidth = [Console]::BufferWidth
        $safeLeft = [Math]::Max(0, [Math]::Min($Left, $maxWidth - 1))
        $safeTop = [Math]::Max(0, [Math]::Min($Top, $maxHeight - 1))
        [Console]::SetCursorPosition($safeLeft, $safeTop)
    }
    catch {}
}

# Refresh environment variables (PATH)
function Refresh-EnvironmentPaths {
    Write-Host "  -> Refreshing environment PATH in real time..." -ForegroundColor DarkGray
    Write-Log -Level "DEBUG" -Message "Refreshing session Environment PATH."
    try {
        $machinePath = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey("System\CurrentControlSet\Control\Session Manager\Environment").GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $userPath = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment").GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

        $expandedMachine = [System.Environment]::ExpandEnvironmentVariables($machinePath)
        $expandedUser = [System.Environment]::ExpandEnvironmentVariables($userPath)
        
        $newPath = @()
        if ($expandedMachine) { $newPath += $expandedMachine -split ';' }
        if ($expandedUser) { $newPath += $expandedUser -split ';' }
        
        $uniquePaths = @()
        foreach ($p in $newPath) {
            $trimmed = $p.Trim()
            if ($trimmed -and -not $uniquePaths.Contains($trimmed)) {
                $uniquePaths += $trimmed
            }
        }
        
        $env:PATH = $uniquePaths -join ';'
        Write-Log -Level "INFO" -Message "Environment PATH successfully refreshed."
    }
    catch {
        Write-Log -Level "ERROR" -Message "Environment PATH refresh failed." -Detail $_.Exception.Message
    }
}

# Winget bootstrap when not installed
Write-Log -Level "INFO" -Message "Checking if winget is available on system PATH."
Write-Host "Checking package manager (winget) availability..." -ForegroundColor DarkGray
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Log -Level "WARN" -Message "winget not found on PATH. Attempting automatic bootstrap installation."
    Write-Host "winget was not found, so automatic installation will start..." -ForegroundColor Yellow
    $msixUrl = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    $msixPath = Join-Path $env:TEMP "Microsoft.DesktopAppInstaller.msixbundle"
    
    try {
        Write-Log -Level "INFO" -Message "Downloading winget package." -Detail "URL: $msixUrl`nTarget: $msixPath"
        Write-Host "Downloading winget package..." -ForegroundColor Gray
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $msixUrl -OutFile $msixPath -UseBasicParsing
        $ProgressPreference = 'Continue'
        
        Write-Log -Level "INFO" -Message "Installing downloaded AppInstaller msixbundle."
        Write-Host "Installing winget package..." -ForegroundColor Gray
        Add-AppxPackage -Path $msixPath
        Remove-Item $msixPath -Force -ErrorAction SilentlyContinue
        
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Log -Level "INFO" -Message "winget successfully installed and verified."
            Write-Host "winget installation complete!" -ForegroundColor Green
        }
        else {
            Write-Log -Level "WARN" -Message "winget installed but command is not immediately visible on current session."
        }
    }
    catch {
        $err = $_.Exception.Message
        Write-Log -Level "ERROR" -Message "winget bootstrap installation failed." -Detail $err
        Write-Host "winget automatic installation failed: $err" -ForegroundColor Red
        Write-Host "Please update 'App Installer' from Microsoft Store." -ForegroundColor Yellow
    }
}
else {
    Write-Log -Level "INFO" -Message "winget verified on system PATH."
}

# Scan installed apps and refresh the global hashtables
$script:installedIds = @{}
$script:installedNames = @{}

# (Get-VisualSubstring and Get-SafeContentTail now live in AutoInstaller.Core.ps1)

function Scan-InstalledApps {
    Write-Log -Level "INFO" -Message "Querying installed apps using winget list."
    Write-Host "Querying the list of installed programs..." -ForegroundColor DarkGray
    
    $script:installedIds = @{}
    $script:installedNames = @{}
    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            $listOutput = & winget list --accept-source-agreements 2>&1
            
            # Dynamic parser that uses the separator line (----) to detect the header/data boundary and supports both Korean and English locale headers
            $separatorIdx = -1
            for ($idx = 0; $idx -lt $listOutput.Count; $idx++) {
                if ($null -eq $listOutput[$idx]) { continue }
                $str = $listOutput[$idx].ToString()
                if ($str -match '^-{5,}') {
                    $separatorIdx = $idx
                    break
                }
            }
            
            if ($separatorIdx -gt 0) {
                $headerLine = $listOutput[$separatorIdx - 1].ToString()
                
# Korean locale: "장치 ID", English locale: "Id" (case-insensitive and locale-aware)
                $krIdPos = $headerLine.IndexOf("장치 ID", [System.StringComparison]::OrdinalIgnoreCase)
                $enIdPos = $headerLine.IndexOf("Id", [System.StringComparison]::OrdinalIgnoreCase)
                $rawIdPos = if ($krIdPos -ge 0) { $krIdPos } else { $enIdPos }
                
                # Korean locale: "버전", English locale: "Version"
                $krVerPos = $headerLine.IndexOf("버전", [System.StringComparison]::OrdinalIgnoreCase)
                $enVerPos = $headerLine.IndexOf("Version", [System.StringComparison]::OrdinalIgnoreCase)
                $rawVerPos = if ($krVerPos -ge 0) { $krVerPos } else { $enVerPos }
                
                if ($rawIdPos -ge 0 -and $rawVerPos -gt $rawIdPos) {
                    # Correct using visual-width indices instead of raw string indices
                    $idStartWidth = Get-VisualWidth ($headerLine.Substring(0, $rawIdPos))
                    $versionStartWidth = Get-VisualWidth ($headerLine.Substring(0, $rawVerPos))
                    $idLengthWidth = $versionStartWidth - $idStartWidth
                    
                    Write-Log -Level "DEBUG" -Message "winget list header parsed in Visual Widths: idStartWidth=$idStartWidth versionStartWidth=$versionStartWidth idLengthWidth=$idLengthWidth"
                    
                    for ($i = $separatorIdx + 1; $i -lt $listOutput.Count; $i++) {
                        if ($null -eq $listOutput[$i]) { continue }
                        $line = $listOutput[$i].ToString()
                        if (-not $line -or $line.Trim() -eq "") { continue }
                        
                        # Use visual-width substrings to split Name and ID without drift
                        $nameToken = Get-VisualSubstring -String $line -StartWidth 0 -LengthWidth $idStartWidth
                        $idToken = Get-VisualSubstring -String $line -StartWidth $idStartWidth -LengthWidth $idLengthWidth
                        
                        if ($nameToken) {
                            $script:installedNames[$nameToken.ToLower()] = $true
                        }
                        if ($idToken -and $idToken -notmatch '^-+$') {
                            $script:installedIds[$idToken.ToLower()] = $true
                        }
                    }
                }
                else {
                    Write-Log -Level "WARN" -Message "Could not parse Id/Version columns from winget list header."
                }
            }
            else {
                Write-Log -Level "WARN" -Message "Could not find separator line in winget list output."
            }
            
            Write-Log -Level "INFO" -Message "Found $($script:installedIds.Count) installed IDs, $($script:installedNames.Count) installed Names via winget list."
        }
        catch {
            Write-Log -Level "ERROR" -Message "Failed to query installed apps." -Detail $_.Exception.Message
        }
    }
}

# (Test-IsAppInstalled now lives in AutoInstaller.Core.ps1, with WARN logging added around its
#  heuristic fallback stages so false-positive matches can be spotted after the fact.)

# ================================================================
#region ── App catalog (loaded from catalog.json)
# ================================================================
$CATALOG_PATH = Join-Path $PSScriptRoot "catalog.json"
if (-not (Test-Path $CATALOG_PATH)) {
    Write-Log -Level "ERROR" -Message "Could not find the catalog file: $CATALOG_PATH"
    Write-Host "Error: catalog.json must sit next to the script." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

try {
    $catalogRaw = Get-Content -Path $CATALOG_PATH -Raw -Encoding UTF8 | ConvertFrom-Json
}
catch {
    Write-Log -Level "ERROR" -Message "Failed to parse catalog.json." -Detail $_.Exception.Message
    Write-Host "Error: catalog.json is not valid JSON." -ForegroundColor Red
    Read-Host "Press Enter to exit"
    exit 1
}

# Convert JSON arrays (order-preserving) into [ordered] hashtables compatible with the rest of the script
function ConvertTo-OrderedAppTable {
    param($Items)
    $table = [ordered]@{}
    if (-not $Items) { return $table }
    foreach ($item in $Items) {
        $info = @{}
        foreach ($prop in $item.PSObject.Properties) {
            if ($prop.Name -ne "name") { $info[$prop.Name] = $prop.Value }
        }
        $table[$item.name] = $info
    }
    return $table
}

$WINGET = ConvertTo-OrderedAppTable $catalogRaw.winget
$STORE = ConvertTo-OrderedAppTable $catalogRaw.store
$GITHUB = ConvertTo-OrderedAppTable $catalogRaw.github
$MANUAL = ConvertTo-OrderedAppTable $catalogRaw.manual

# Custom alternate ID / display-name mappings (JSON object -> hashtable)
$script:APP_CUSTOM_MAPPINGS = @{}
if ($catalogRaw.customMappings) {
    foreach ($prop in $catalogRaw.customMappings.PSObject.Properties) {
        $script:APP_CUSTOM_MAPPINGS[$prop.Name] = @($prop.Value)
    }
}

Write-Log -Level "INFO" -Message "Catalog loaded." -Detail "winget=$($WINGET.Count) store=$($STORE.Count) github=$($GITHUB.Count) manual=$($MANUAL.Count) customMappings=$($script:APP_CUSTOM_MAPPINGS.Count)"
#endregion

# ================================================================
#region ── Selection TUI UI
# ================================================================
function Show-TUISelectionMenu {
    Write-Log -Level "DEBUG" -Message "Loading TUI selection menu."
    
    $categories = [ordered]@{}
    $addApp = {
        param($name, $appInfo, $source)
        $cat = $appInfo.cat
        if (-not $cat) {
            if ($source -eq "manual") { $cat = "Manual setup" }
            else { $cat = "Others" }
        }
        if (-not $categories.Contains($cat)) {
            $categories[$cat] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        
        # Check whether the app is already installed (manual installs are always treated as not installed)
        $isInstalled = $false
        if ($source -ne "manual") {
            $detectId = if ($appInfo.id) { $appInfo.id } else { $name }
            if ($detectId) {
                if (Test-IsAppInstalled -AppId $detectId) {
                    $isInstalled = $true
                }
            }
        }
        
        # If already installed, deselect by default (manual installs remain checked by default)
        $defaultSelect = if ($isInstalled) { $false } else { $true }
        
        $categories[$cat].Add([PSCustomObject]@{
                Name        = $name
                Info        = $appInfo
                Source      = $source
                Selected    = $defaultSelect
                IsInstalled = $isInstalled
                IsHeader    = $false
            })
    }

    foreach ($name in $WINGET.Keys) { & $addApp $name $WINGET[$name] "winget" }
    foreach ($name in $STORE.Keys) { & $addApp $name $STORE[$name] "store" }
    foreach ($name in $GITHUB.Keys) { & $addApp $name $GITHUB[$name] "github" }
    foreach ($name in $MANUAL.Keys) { & $addApp $name $MANUAL[$name] "manual" }

    # Flatten into a single array
    $listLines = [System.Collections.Generic.List[PSCustomObject]]::new()
    foreach ($cat in $categories.Keys) {
        $listLines.Add([PSCustomObject]@{
                Text     = $cat
                IsHeader = $true
            })
        foreach ($app in $categories[$cat]) {
            $listLines.Add($app)
        }
    }

    $cursorIndex = 0
    for ($i = 0; $i -lt $listLines.Count; $i++) {
        if (-not $listLines[$i].IsHeader) {
            $cursorIndex = $i
            break
        }
    }

    # Auto-adjust page height based on the console window (adds margin so $pageSize + 10 output lines do not exceed WindowHeight)
    $pageSize = 12
    try {
        $dynamicSize = [Console]::WindowHeight - 12
        if ($dynamicSize -ge 5 -and $dynamicSize -le 20) {
            $pageSize = $dynamicSize
        }
        elseif ($dynamicSize -gt 20) {
            $pageSize = 20
        }
        elseif ($dynamicSize -lt 5) {
            $pageSize = 5
        }
    }
    catch {}
    
    $scrollOffset = 0
    
    $oldCursorVisible = [Console]::CursorVisible
    try { [Console]::CursorVisible = $false } catch {}

    try { [Console]::Clear() } catch { Clear-Host }
    $running = $true
    $canceled = $false

    while ($running) {
        if ($cursorIndex -lt $scrollOffset) {
            $scrollOffset = $cursorIndex
        }
        elseif ($cursorIndex -ge ($scrollOffset + $pageSize)) {
            $scrollOffset = $cursorIndex - $pageSize + 1
        }

        if ($scrollOffset -lt 0) { $scrollOffset = 0 }
        $maxOffset = $listLines.Count - $pageSize
        if ($maxOffset -lt 0) { $maxOffset = 0 }
        if ($scrollOffset -gt $maxOffset) { $scrollOffset = $maxOffset }

        Set-SafeCursor 0 0
        
        Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
        Write-Host "║               Windows Auto-Install Program v$SCRIPT_VERSION              ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host " [↑/↓] Move  [←/→] Jump section  [Space] Toggle  [A] Select all  [N] Deselect all  [Enter] Start  [Esc] Cancel" -ForegroundColor DarkGray
        Write-Host " This program was developed with the help of an AI coding assistant." -ForegroundColor DarkGray
        Write-Host "----------------------------------------------------------------" -ForegroundColor Gray

        for ($i = 0; $i -lt $pageSize; $i++) {
            $lineIdx = $scrollOffset + $i
            if ($lineIdx -lt $listLines.Count) {
                $line = $listLines[$lineIdx]
                if ($line.IsHeader) {
                    $prefix = if ($lineIdx -eq $cursorIndex) { " > " } else { "   " }
                    
                    # Compute the selection state of child items
                    $subApps = @()
                    for ($idx = $lineIdx + 1; $idx -lt $listLines.Count; $idx++) {
                        if ($listLines[$idx].IsHeader) { break }
                        $subApps += $listLines[$idx]
                    }
                    
                    $selectedCount = ($subApps | Where-Object { $_.Selected }).Count
                    $headerCheck = if ($subApps.Count -eq 0) { "[ ]" }
                    elseif ($selectedCount -eq $subApps.Count) { "[x]" }
                    elseif ($selectedCount -gt 0) { "[-]" }
                    else { "[ ]" }
                    
                    $headerText = "$($line.Text.ToUpper()) ($($subApps.Count) apps)"
                    $displayLine = "$prefix$headerCheck 📂 $headerText "
                    $fillerLength = [Math]::Max(2, 60 - (Get-VisualWidth $displayLine))
                    $displayLine += ("─" * $fillerLength)
                    
                    if ($lineIdx -eq $cursorIndex) {
                        Write-Host (Get-VisualPadRight $displayLine 64) -ForegroundColor Cyan -BackgroundColor DarkBlue
                    }
                    else {
                        Write-Host (Get-VisualPadRight $displayLine 64) -ForegroundColor Yellow
                    }
                }
                else {
                    $prefix = if ($lineIdx -eq $cursorIndex) { " > " } else { "   " }
                    $check = if ($line.Selected) { "[x]" } else { "[ ]" }
                    
                    # Manual installs are always DarkYellow, regular apps are Cyan when focused, DarkGreen when already installed, and White when not installed
                    $fg = if ($lineIdx -eq $cursorIndex) { "Cyan" }
                    elseif ($line.Source -eq "manual") { "DarkYellow" }
                    elseif ($line.IsInstalled) { "DarkGreen" }
                    else { "White" }
                          
                    $srcText = switch ($line.Source) {
                        "winget" { "Winget" }
                        "store" { "MS Store" }
                        "github" { "GitHub" }
                        "manual" { "Manual" }
                    }
                    
                    $nameText = "$($line.Name) ($srcText)"
                    # Manual install apps never show the [already installed] label, even when detected
                    if ($line.IsInstalled -and $line.Source -ne "manual") {
                        $nameText += " [Already installed]"
                    }
                    
                    if ($lineIdx -eq $cursorIndex) {
                        Write-Host (Get-VisualPadRight "$prefix$check $nameText" 64) -ForegroundColor $fg -BackgroundColor DarkBlue
                    }
                    else {
                        Write-Host (Get-VisualPadRight "$prefix$check $nameText" 64) -ForegroundColor $fg
                    }
                }
            }
            else {
                Write-Host "".PadRight(64)
            }
        }
        Write-Host "----------------------------------------------------------------" -ForegroundColor Gray
        
        # Scroll position indicator
        $appIndex = ($listLines[0..$cursorIndex] | Where-Object { -not $_.IsHeader }).Count
        $totalApps = ($listLines | Where-Object { -not $_.IsHeader }).Count
        $aboveCount = [Math]::Max(0, $scrollOffset)
        $belowCount = [Math]::Max(0, $listLines.Count - $scrollOffset - $pageSize)
        $posText = " Position: $appIndex / $totalApps"
        if ($aboveCount -gt 0 -or $belowCount -gt 0) {
            $posText += "  (▲ ${aboveCount} ▼ ${belowCount})"
        }
        Write-Host (Get-VisualPadRight $posText 64) -ForegroundColor DarkGray

        # Color legend
        Write-Host " ■" -ForegroundColor White -NoNewline; Write-Host " Not installed" -ForegroundColor DarkGray -NoNewline
        Write-Host "  ■" -ForegroundColor DarkGreen -NoNewline; Write-Host " Installed" -ForegroundColor DarkGray -NoNewline
        Write-Host "  ■" -ForegroundColor DarkYellow -NoNewline; Write-Host " Manual" -ForegroundColor DarkGray -NoNewline
        Write-Host "  ■" -ForegroundColor Cyan -NoNewline; Write-Host " Focus" -ForegroundColor DarkGray

        $selectedCount = ($listLines | Where-Object { -not $_.IsHeader -and $_.Selected }).Count
        $totalCount = ($listLines | Where-Object { -not $_.IsHeader }).Count
        Write-Host (Get-VisualPadRight " Selected: $selectedCount / $totalCount apps (total $totalCount)" 64) -ForegroundColor Green

        $keyInfo = [Console]::ReadKey($true)
        switch ($keyInfo.Key) {
            "UpArrow" {
                $cursorIndex--
                if ($cursorIndex -lt 0) { $cursorIndex = $listLines.Count - 1 }
            }
            "DownArrow" {
                $cursorIndex++
                if ($cursorIndex -ge $listLines.Count) { $cursorIndex = 0 }
            }
            "RightArrow" {
                # Jump to the next section header (wraps to the first)
                $headerIndices = @(for ($idx = 0; $idx -lt $listLines.Count; $idx++) { if ($listLines[$idx].IsHeader) { $idx } })
                if ($headerIndices.Count -gt 0) {
                    $next = $headerIndices | Where-Object { $_ -gt $cursorIndex } | Select-Object -First 1
                    if ($null -eq $next) { $next = $headerIndices[0] }
                    $cursorIndex = $next
                }
            }
            "LeftArrow" {
                # Jump to the previous section header (wraps to the last)
                $headerIndices = @(for ($idx = 0; $idx -lt $listLines.Count; $idx++) { if ($listLines[$idx].IsHeader) { $idx } })
                if ($headerIndices.Count -gt 0) {
                    $prev = $headerIndices | Where-Object { $_ -lt $cursorIndex } | Select-Object -Last 1
                    if ($null -eq $prev) { $prev = $headerIndices[-1] }
                    $cursorIndex = $prev
                }
            }
            "Spacebar" {
                if ($listLines[$cursorIndex].IsHeader) {
                    # Toggle child items in bulk
                    $subApps = @()
                    for ($idx = $cursorIndex + 1; $idx -lt $listLines.Count; $idx++) {
                        if ($listLines[$idx].IsHeader) { break }
                        $subApps += $listLines[$idx]
                    }
                    
                    $anyUnselected = $false
                    foreach ($app in $subApps) {
                        if (-not $app.Selected) {
                            $anyUnselected = $true
                            break
                        }
                    }
                    
                    $targetState = $anyUnselected
                    foreach ($app in $subApps) {
                        $app.Selected = $targetState
                    }
                }
                else {
                    $listLines[$cursorIndex].Selected = -not $listLines[$cursorIndex].Selected
                }
            }
            "A" {
                foreach ($l in $listLines) {
                    if (-not $l.IsHeader) { $l.Selected = $true }
                }
            }
            "N" {
                foreach ($l in $listLines) {
                    if (-not $l.IsHeader) { $l.Selected = $false }
                }
            }
            "Enter" {
                $selItems = @($listLines | Where-Object { -not $_.IsHeader -and $_.Selected })
                if ($selItems.Count -eq 0) {
                    Set-SafeCursor 0 ($pageSize + 7)
                    Write-Host (Get-VisualPadRight " [!] No apps are selected. Please select at least one app to install." 64) -ForegroundColor Yellow
                    Start-Sleep -Milliseconds 1200
                    continue
                }

                $estSec = 0
                foreach ($item in $selItems) {
                    if ($item.Info.sec) { $estSec += $item.Info.sec }
                }
                
                $confirmWidth = 62
                $lineBorder = "═" * $confirmWidth
                Write-Host "╔$lineBorder╗" -ForegroundColor Cyan
                Write-BorderLine "  Confirm installation" "Cyan" $confirmWidth
                Write-Host "╠$lineBorder╣" -ForegroundColor Cyan
                Write-BorderLine "  Selected apps: $($selItems.Count)" "White" $confirmWidth
                
                $min = [Math]::Floor($estSec / 60)
                $sec = $estSec % 60
                $timeStr = if ($min -gt 0) { "${min}m ${sec}s" } else { "${sec}s" }
                Write-BorderLine "  Estimated time: about $timeStr" "White" $confirmWidth
                Write-BorderLine "  [Enter] Start installation  [Esc] Return to selection screen" "DarkGray" $confirmWidth
                Write-Host "╚$lineBorder╝" -ForegroundColor Cyan

                $waitingConfirm = $true
                while ($waitingConfirm) {
                    $cKey = [Console]::ReadKey($true)
                    if ($cKey.Key -eq [ConsoleKey]::Enter) {
                        $running = $false
                        $waitingConfirm = $false
                    }
                    elseif ($cKey.Key -eq [ConsoleKey]::Escape) {
                        $waitingConfirm = $false
                        try { [Console]::Clear() } catch { Clear-Host }
                    }
                }
            }
            "Escape" {
                $running = $false
                $canceled = $true
            }
        }
    }

    try { [Console]::CursorVisible = $oldCursorVisible } catch {}
    try { [Console]::Clear() } catch { Clear-Host }

    if ($canceled) {
        Write-Log -Level "INFO" -Message "TUI menu cancelled by user."
        return $null
    }
    
    $selectedApps = @($listLines | Where-Object { -not $_.IsHeader -and $_.Selected } | ForEach-Object { $_.Name })
    Write-Log -Level "INFO" -Message "TUI selection completed." -Detail "$($selectedApps.Count) apps selected: $($selectedApps -join ', ')"
    return $selectedApps
}
#endregion

# ================================================================
#region ── Interrupt prompt and process execution control
# ================================================================
function Show-InterruptPrompt {
    param(
        [string]$AppName
    )

    $origTop = [Console]::CursorTop
    $origLeft = [Console]::CursorLeft

    $w = 58
    
    $makeLine = {
        param([string]$Text)
        $vw = Get-VisualWidth $Text
        $pad = $w - $vw
        return "  │ $Text" + (" " * [Math]::Max(0, $pad)) + "│"
    }

    Write-Host ""
    Write-Host "  ┌$([string][char]0x2500 * $w)┐" -ForegroundColor Yellow
    Write-Host (& $makeLine " [!] Installation paused (Q / Esc detected)") -ForegroundColor Yellow
    Write-Host (& $makeLine " Currently installing: $AppName") -ForegroundColor Yellow
    Write-Host (& $makeLine "") -ForegroundColor Yellow
    Write-Host (& $makeLine "  1. Stop this item (force-cancel the current install)") -ForegroundColor Yellow
    Write-Host (& $makeLine "  2. Stop all installs (skip the remaining list)") -ForegroundColor Yellow
    Write-Host (& $makeLine "  3. Continue") -ForegroundColor Yellow
    Write-Host "  └$([string][char]0x2500 * $w)┘" -ForegroundColor Yellow
    Write-Host "  Select (1-3): " -ForegroundColor Yellow -NoNewline

    $choice = $null
    while ($null -eq $choice) {
        $key = [Console]::ReadKey($true)
        if ($key.KeyChar -eq '1') { $choice = "Current" }
        elseif ($key.KeyChar -eq '2') { $choice = "All" }
        elseif ($key.KeyChar -eq '3') { $choice = "Continue" }
    }

    for ($t = $origTop; $t -le ($origTop + 10); $t++) {
        Set-SafeCursor 0 $t
        Write-Host (" " * 78) -NoNewline
    }
    Set-SafeCursor $origLeft $origTop

    if ($choice -eq "Continue") {
        return "None"
    }
    return $choice
}

function Execute-ProcessWithInterrupt {
    param(
        [string]$FilePath,
        [string]$ArgumentList,
        [string]$AppName,
        [string]$RedirectStandardOutput = "",
        [string]$RedirectStandardError = "",
        [string]$ProgressPrefix = ""
    )

    # Prepare an empty stdin file in Temp to avoid input interception
    $emptyStdin = Join-Path $env:TEMP "empty-stdin.txt"
    if (-not (Test-Path $emptyStdin)) {
        " " | Out-File $emptyStdin -Force -Encoding ASCII
    }

    # Use hashtable splatting to avoid parameter-mapping errors and add stdin redirection
    $splat = @{
        FilePath              = $FilePath
        ArgumentList          = $ArgumentList
        NoNewWindow           = $true
        PassThru              = $true
        RedirectStandardInput = $emptyStdin
    }

    if ($RedirectStandardOutput) { $splat["RedirectStandardOutput"] = $RedirectStandardOutput }
    if ($RedirectStandardError) { $splat["RedirectStandardError"] = $RedirectStandardError }

    Write-Log -Level "DEBUG" -Message "Starting process with interrupt tracking: $FilePath $ArgumentList"

    try {
        $proc = Start-Process @splat
    }
    catch {
        Write-Log -Level "ERROR" -Message "Failed to start process." -Detail $_.Exception.Message
        return @{ ExitCode = -1; Interrupted = "None"; Error = $_.Exception.Message }
    }

    $interrupted = "None"
    $lastStatusText = ""
    $lastUpdate = Get-Date
    
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 100
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Escape -or $key.Key -eq [ConsoleKey]::Q) {
                $interrupted = Show-InterruptPrompt -AppName $AppName
                if ($interrupted -eq "Current" -or $interrupted -eq "All") {
                    try {
                        if (-not $proc.HasExited) {
                            Write-Log -Level "WARN" -Message "Killing process $AppName due to user selection ($interrupted)."
                            $proc.Kill()
                        }
                    }
                    catch {
                        Write-Log -Level "ERROR" -Message "Failed to kill process." -Detail $_.Exception.Message
                    }
                    break
                }
                $lastStatusText = ""
            }
        }

        # Parse live progress and update the fixed status bar at the bottom (300 ms interval)
        if ($RedirectStandardOutput -and $ProgressPrefix -and (Test-Path $RedirectStandardOutput)) {
            $now = Get-Date
            if (($now - $lastUpdate).TotalMilliseconds -ge 300) {
                $lastUpdate = $now
                try {
                    $lines = Get-SafeContentTail -Path $RedirectStandardOutput -TailCount 5
                    $rawStatus = ""
                    for ($j = $lines.Count - 1; $j -ge 0; $j--) {
                        $l = $lines[$j]
                        if (-not $l -or -not $l.Trim()) { continue }
                        if ($l.Trim() -eq "-" -or $l.Trim() -match '^[- ]+$') { continue }
                        $rawStatus = $l.Trim()
                        break
                    }
                    
                    if ($rawStatus -and $rawStatus -ne $lastStatusText) {
                        $lastStatusText = $rawStatus
                        
                        # Save the current cursor position
                        $backLeft = [Console]::CursorLeft
                        $backTop = [Console]::CursorTop
                        
                        # Determine the bottom console line
                        $statusBarTop = [Console]::WindowHeight - 1
                        if ($statusBarTop -lt 0) { $statusBarTop = 0 }
                        
                        # Build the output string and trim it to width
                        $statusBarLine = "  >> ${AppName}: $rawStatus"
                        $maxLen = [Console]::WindowWidth - 2
                        if ($maxLen -lt 10) { $maxLen = 60 }
                        if ($statusBarLine.Length -gt $maxLen) {
                            $statusBarLine = $statusBarLine.Substring(0, $maxLen - 3) + "..."
                        }
                        
                        # Redraw the status bar area
                        Set-SafeCursor 0 $statusBarTop
                        Write-Host ($statusBarLine.PadRight($maxLen)) -ForegroundColor Yellow -BackgroundColor Black -NoNewline
                        
                        # Restore the original cursor position
                        Set-SafeCursor $backLeft $backTop
                    }
                }
                catch {}
            }
        }
    }

    # Clear the status bar after the process exits
    try {
        $backLeft = [Console]::CursorLeft
        $backTop = [Console]::CursorTop
        $statusBarTop = [Console]::WindowHeight - 1
        $maxLen = [Console]::WindowWidth - 2
        if ($statusBarTop -ge 0 -and $maxLen -gt 0) {
            Set-SafeCursor 0 $statusBarTop
            Write-Host (" " * $maxLen) -NoNewline
            Set-SafeCursor $backLeft $backTop
        }
    }
    catch {}

    $exitCode = -1
    try {
        $exitCode = $proc.ExitCode
        $proc.Close()
    }
    catch {}

    return @{ ExitCode = $exitCode; Interrupted = $interrupted; Error = $null }
}
#endregion

# ================================================================
#region ── TUI output helpers
# ================================================================
function Write-Header {
    param([int]$Total)
    Clear-Host
    $w = 64
    $line = "═" * $w
    Write-Host "╔$line╗" -ForegroundColor Cyan
    Write-BorderLine "  Windows Auto-Install Script  v$SCRIPT_VERSION" "Cyan" $w
    Write-Host "╠$line╣" -ForegroundColor Cyan
    Write-BorderLine "  Preparing to install $Total apps" "Yellow" $w
    Write-Host "╚$line╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  ※ Press [Q] or [Esc] to stop from the next install process onward." -ForegroundColor DarkGray
    Write-Host ""
}

# (Get-FailReason now lives in AutoInstaller.Core.ps1)

function Write-SectionBar {
    param([string]$Cat)
    Write-Host ""
    Write-Host "  ── $Cat " -ForegroundColor DarkCyan -NoNewline
    Write-Host ("─" * [Math]::Max(2, 52 - $Cat.Length)) -ForegroundColor DarkCyan
}
#endregion

# ================================================================
#region ── GitHub release installation
# ================================================================
function Install-FromGitHub {
    param([string]$Name, [hashtable]$Cfg, [string]$ProgressPrefix = "")
    $tmp = $null
    try {
        Write-Log -Level "INFO" -Message "GitHub release installation started for $Name." -Detail "API: $($Cfg.Api)"
        
        # Add an authorization header when GITHUB_TOKEN is set (avoids unauthenticated rate limits)
        $headers = @{ "User-Agent" = "AutoInstall"; "Accept" = "application/vnd.github+json" }
        if ($env:GITHUB_TOKEN) {
            $headers["Authorization"] = "token $env:GITHUB_TOKEN"
            Write-Log -Level "DEBUG" -Message "Using GITHUB_TOKEN authorization header."
        }
        
        $rel = Invoke-RestMethod -Uri $Cfg.Api -Headers $headers
        $asset = $rel.assets | Where-Object { $_.name -like $Cfg.Filter } | Select-Object -First 1
        if (-not $asset) {
            Write-Log -Level "ERROR" -Message "No matching GitHub release asset found." -Detail "Filter: $($Cfg.Filter)"
            return @{ Ok = $false; Reason = 'No release asset found' }
        }
        
        $tmp = Join-Path $env:TEMP $asset.name
        Write-Log -Level "DEBUG" -Message "Downloading release asset." -Detail "URL: $($asset.browser_download_url)`nTemp path: $tmp"
        
        $ProgressPreference = 'SilentlyContinue'
        $downloadCmd = "Invoke-WebRequest -Uri '$($asset.browser_download_url)' -OutFile '$tmp' -UseBasicParsing"
        $res = Execute-ProcessWithInterrupt -FilePath "powershell" -ArgumentList "-NoProfile -Command $downloadCmd" -AppName "$Name download" -ProgressPrefix $ProgressPrefix
        $ProgressPreference = 'Continue'
        
        if ($res.Interrupted -eq "Current") {
            return @{ Ok = $false; Reason = "Canceled by user (current item stopped)"; Interrupted = "Current" }
        }
        elseif ($res.Interrupted -eq "All") {
            return @{ Ok = $false; Reason = "Canceled by user (all installs stopped)"; Interrupted = "All" }
        }
        
        if ($res.ExitCode -ne 0) {
            return @{ Ok = $false; Reason = "Download failed (exit code $($res.ExitCode))"; Interrupted = "None" }
        }
        
        $a = if ($Cfg.Args) { $Cfg.Args } else { "" }
        Write-Log -Level "INFO" -Message "Executing GitHub installer process with interrupt check." -Detail "Path: $tmp`nArgs: $a"
        
        $res = Execute-ProcessWithInterrupt -FilePath $tmp -ArgumentList $a -AppName $Name -ProgressPrefix $ProgressPrefix
        
        Start-Sleep -Seconds 1
        
        $exit = $res.ExitCode
        $interrupted = $res.Interrupted
        
        if ($interrupted -eq "Current") {
            return @{ Ok = $false; Reason = "Canceled by user (current item stopped)"; Interrupted = "Current" }
        }
        elseif ($interrupted -eq "All") {
            return @{ Ok = $false; Reason = "Canceled by user (all installs stopped)"; Interrupted = "All" }
        }
        
        if ($res.Error) {
            return @{ Ok = $false; Reason = "Installer execution failed: $($res.Error)" }
        }

        Write-Log -Level "INFO" -Message "GitHub installer execution completed." -Detail "ExitCode: $exit"
        if ($exit -eq 0) { return @{ Ok = $true; Reason = $null; Interrupted = "None" } }
        return @{ Ok = $false; Reason = "Installation error (exit code $exit)"; Interrupted = "None" }
    }
    catch {
        $err = $_.Exception.Message -replace "`r`n", " "
        Write-Log -Level "ERROR" -Message "Exception occurred in Install-FromGitHub." -Detail $err
        return @{ Ok = $false; Reason = $err }
    }
    finally {
        if ($tmp -and (Test-Path $tmp)) {
            Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        }
    }
}
#endregion


# ================================================================
#region ── Winget installation execution
# ================================================================
function Invoke-Winget {
    param([string]$Id, [string]$AppName, [string]$Extra = "", [string]$ProgressPrefix = "")
    $tmpOut = [IO.Path]::GetTempFileName()
    $tmpErr = [IO.Path]::GetTempFileName()
    
    $wingetArgs = @("install", "--id", $Id, "--silent", "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity")
    if ($Extra) {
        $wingetArgs += $Extra -split ' '
    }
    $argsString = $wingetArgs -join ' '
    
    $res = Execute-ProcessWithInterrupt -FilePath "winget" -ArgumentList $argsString -AppName $AppName -RedirectStandardOutput $tmpOut -RedirectStandardError $tmpErr -ProgressPrefix $ProgressPrefix
    
    $exit = $res.ExitCode
    $interrupted = $res.Interrupted
    
    $output = (Get-Content $tmpOut -Raw -ErrorAction SilentlyContinue) + "`n" + (Get-Content $tmpErr -Raw -ErrorAction SilentlyContinue)
    Remove-Item $tmpOut -Force -ErrorAction SilentlyContinue
    Remove-Item $tmpErr -Force -ErrorAction SilentlyContinue
    
    if ($interrupted -eq "Current") {
        return @{ Ok = $false; Reason = "Canceled by user (current item stopped)"; Interrupted = "Current" }
    }
    elseif ($interrupted -eq "All") {
        return @{ Ok = $false; Reason = "Canceled by user (all installs stopped)"; Interrupted = "All" }
    }
    
    if ($res.Error) {
        return @{ Ok = $false; Reason = "Process execution failed: $($res.Error)" }
    }

    # Success-condition check (0, already installed (-1978335189 / 0x8A15005B / 2317112411), reboot required (3010, 1641))
    $WINGET_ALREADY_INSTALLED = $script:EXIT_ALREADY_INSTALLED
    $ERROR_SUCCESS_REBOOT_REQUIRED = $script:EXIT_REBOOT_REQUIRED
    $ERROR_SUCCESS_REBOOT_INITIATED = $script:EXIT_REBOOT_INITIATED
    
    $ok = ($exit -eq 0 -or $exit -eq $WINGET_ALREADY_INSTALLED -or $exit -eq $ERROR_SUCCESS_REBOOT_REQUIRED -or $exit -eq $ERROR_SUCCESS_REBOOT_INITIATED)
    $reason = if ($ok) { $null } else { Get-FailReason $output }
    
    Write-Log -Level "INFO" -Message "Winget execution completed." -Detail "ExitCode: $exit`nOutput: $output"
    return @{ Ok = $ok; Reason = $reason; Interrupted = "None" }
}
#endregion

# ================================================================
#region ── Installation execution
# ================================================================
function Invoke-Install {
    param([string[]]$Selected)

    $done = [System.Collections.Generic.List[PSCustomObject]]::new()
    $failed = [System.Collections.Generic.List[PSCustomObject]]::new()
    $manuals = [System.Collections.Generic.List[PSCustomObject]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    $catPrinted = @{}
    $total = $Selected.Count
    $pad = $total.ToString().Length
    $cancelled = $false

    Write-Log -Level "INFO" -Message "Starting installation loop for $($Selected.Count) apps."

    for ($i = 0; $i -lt $Selected.Count; $i++) {
        $name = $Selected[$i]
        $namePad = $name + (" " * [Math]::Max(0, 30 - (Get-VisualWidth $name)))
        
        # Check whether a cancel key was already pressed when entering the loop
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Escape -or $key.Key -eq [ConsoleKey]::Q) {
                $cancelled = $true
            }
        }
        
        # Skip the remaining apps if the user requested cancellation
        if ($cancelled) {
            Write-Log -Level "DEBUG" -Message "Skipping $name due to cancel state."
            $skipped.Add($name)
            continue
        }

        $src = $null
        $type = $null
        if ($WINGET.Contains($name)) { $src = $WINGET[$name]; $type = "winget" }
        elseif ($STORE.Contains($name)) { $src = $STORE[$name]; $type = "store" }
        elseif ($GITHUB.Contains($name)) { $src = $GITHUB[$name]; $type = "github" }
        elseif ($MANUAL.Contains($name)) { $src = $MANUAL[$name]; $type = "manual" }
        if (-not $src) { continue }

        $idx = $i + 1
        $cat = $src.cat
        if (-not $cat) { $cat = "Manual Setup" }
        if (-not $catPrinted[$cat]) { Write-SectionBar $cat; $catPrinted[$cat] = $true }

        $prefix = "[{0,$pad}/{1}]" -f $idx, $total

        # Check whether the app is already installed (manual installs are not skipped so the user can follow the required setup guide)
        $isAlreadyInstalled = $false
        if ($type -ne "manual") {
            $detectId = if ($src.id) { $src.id } else { $name }
            if ($detectId -and (Test-IsAppInstalled -AppId $detectId)) {
                $isAlreadyInstalled = $true
            }
        }

        if ($isAlreadyInstalled) {
            Write-Log -Level "INFO" -Message "$name is already installed. Skipping installer run."
            $resultLine = "  $prefix  $namePad ◽ Already installed"
            Write-Host (Get-VisualPadRight $resultLine 64) -ForegroundColor DarkGray
            $done.Add([PSCustomObject]@{ Name = $name; Time = 0; IsAlreadyInstalled = $true })
            continue
        }

        if ($type -eq "manual") {
            Write-Log -Level "INFO" -Message "$name marked for manual setup."
            Write-Host "  $prefix  $namePad Manual setup recorded" -ForegroundColor Yellow
            $manuals.Add([PSCustomObject]@{ Name = $name; Url = $src.url; Note = $src.note })
            continue
        }

        Write-Log -Level "INFO" -Message "Installing $name ($type)"
        Write-Host "  $prefix  $namePad Installing..." -ForegroundColor DarkGray -NoNewline
        $start = Get-Date

        $res = switch ($type) {
            "winget" { Invoke-Winget -Id $src.id -AppName $name -ProgressPrefix $prefix }
            "store" { Invoke-Winget -Id $src.id -AppName $name -Extra "--source msstore" -ProgressPrefix $prefix }
            "github" { Install-FromGitHub -Name $name -Cfg $src -ProgressPrefix $prefix }
        }

        $end = Get-Date
        $duration = [Math]::Round(($end - $start).TotalSeconds)
        
        $ok = $res.Ok
        
        # Handle interrupted state
        if ($res.Interrupted -eq "Current") {
            $ok = $false
            $res.Reason = "Canceled by user (current item)"
        }
        elseif ($res.Interrupted -eq "All") {
            $ok = $false
            $res.Reason = "Canceled by user (all installs)"
            $cancelled = $true
        }
        
        $col = if ($ok) { "Green" } else { "Red" }
        $sym = if ($ok) { "✅" } else { "❌" }
        
        [Console]::Write("`r")
        $resultLine = "  $prefix  $namePad $sym ($duration s elapsed)"
        Write-Host (Get-VisualPadRight $resultLine 64) -ForegroundColor $col
        
        if (-not $ok) {
            Write-Log -Level "ERROR" -Message "Installation failed for $name." -Detail $res.Reason
            Write-Host ("  {0}    → $($res.Reason)" -f (' ' * ($pad * 2 + 5))) -ForegroundColor DarkRed
            $failed.Add([PSCustomObject]@{ Name = $name; Reason = $res.Reason; Time = $duration })
        }
        else {
            Write-Log -Level "INFO" -Message "Installation succeeded for $name in $duration seconds."
            $done.Add([PSCustomObject]@{ Name = $name; Time = $duration; IsAlreadyInstalled = $false })
        }
    }

    # Refresh PATH once after the batch if at least one app was installed (avoids repeated refreshes and losing session PATH entries)
    $newlyInstalled = @($done | Where-Object { -not $_.IsAlreadyInstalled }).Count
    if ($newlyInstalled -gt 0) {
        Refresh-EnvironmentPaths
    }

    Write-Log -Level "INFO" -Message "Installation loop completed." -Detail "Success: $($done.Count) | Failed: $($failed.Count) | Skipped: $($skipped.Count)"
    return @{ Done = $done; Failed = $failed; Manuals = $manuals; Skipped = $skipped }
}
#endregion

# ================================================================
#region ── Results summary
# ================================================================
function Show-Summary {
    param($Result)
    $w = 64; $line = "═" * $w
    Write-Host ""
    Write-Host "╔$line╗" -ForegroundColor Cyan
    Write-BorderLine "  Installation summary" "Cyan" $w
    Write-Host "╠$line╣" -ForegroundColor Cyan
    
    $totalDoneTime = 0
    foreach ($d in $Result.Done) { $totalDoneTime += $d.Time }
    
    Write-BorderLine "  ✅ Success: $($Result.Done.Count) apps (total $totalDoneTime s elapsed)" "Green" $w
    
    if ($Result.Failed.Count -gt 0) {
        $totalFailTime = 0
        foreach ($f in $Result.Failed) { $totalFailTime += $f.Time }
        Write-BorderLine "  ❌ Failed: $($Result.Failed.Count) apps" "Red" $w
    }
    Write-Host "╚$line╝" -ForegroundColor Cyan
 
    # 1. Print the success list
    if ($Result.Done.Count -gt 0) {
        Write-Host ""
        Write-Host "  ── Success list " -ForegroundColor Green -NoNewline
        Write-Host ("─" * 48) -ForegroundColor DarkGreen
        foreach ($s in $Result.Done) {
            $namePad = $s.Name + (" " * [Math]::Max(0, 30 - (Get-VisualWidth $s.Name)))
            Write-Host "  ✅ $namePad" -ForegroundColor Green -NoNewline
            if ($s.IsAlreadyInstalled) {
                Write-Host "(Already installed)" -ForegroundColor DarkGray
            }
            else {
                Write-Host "($($s.Time)s elapsed)" -ForegroundColor Gray
            }
        }
    }

    # 2. Print the failure list
    if ($Result.Failed.Count -gt 0) {
        Write-Host ""
        Write-Host "  ── Failure list " -ForegroundColor Red -NoNewline
        Write-Host ("─" * 48) -ForegroundColor DarkRed
        foreach ($f in $Result.Failed) {
            $namePad = $f.Name + (" " * [Math]::Max(0, 30 - (Get-VisualWidth $f.Name)))
            Write-Host "  ❌ $namePad" -ForegroundColor Red -NoNewline
            Write-Host "→  $($f.Reason) ($($f.Time)s elapsed)" -ForegroundColor DarkRed
        }
    }

    # 3. Print the canceled/skipped list
    if ($Result.Skipped.Count -gt 0) {
        Write-Host ""
        Write-Host "  ── Canceled/Skipped list " -ForegroundColor Gray -NoNewline
        Write-Host ("─" * 46) -ForegroundColor DarkGray
        foreach ($s in $Result.Skipped) {
            Write-Host "  ◽ $s (canceled)" -ForegroundColor Gray
        }
    }

    # 4. Handle selected manual setup targets
    if ($Result.Manuals.Count -gt 0) {
        Write-Host ""
        Write-Host "  ── Manual setup required (selected) " -ForegroundColor Yellow -NoNewline
        Write-Host ("─" * 36) -ForegroundColor DarkYellow
        foreach ($m in $Result.Manuals) {
            if ($m.Url) {
                Write-Host "  🌐 $($m.Name)" -ForegroundColor Yellow -NoNewline
                Write-Host "  →  $($m.Note)" -ForegroundColor DarkGray
            }
            else {
                Write-Host "  💿 $($m.Name)" -ForegroundColor DarkYellow -NoNewline
                Write-Host "  →  $($m.Note)" -ForegroundColor DarkGray
            }
        }
    }
    
    # Print the detailed log path
    Write-Host ""
    Write-Host "  Detailed installation logs were saved to: " -ForegroundColor DarkGray
    Write-Host "     $LOG_FILE" -ForegroundColor Cyan
    Write-Host ""
}
#endregion

# ================================================================
#region ── Entry point
# ================================================================
Scan-InstalledApps

$scriptRunning = $true
while ($scriptRunning) {
    $sel = Show-TUISelectionMenu
    if ($null -eq $sel) {
        Write-Host "Canceled. Exiting the program." -ForegroundColor Gray
        $scriptRunning = $false
        break
    }
    
    if ($sel.Count -eq 0) {
        Write-Host "No apps were selected. Please choose again." -ForegroundColor Yellow
        Start-Sleep -Seconds 1.5
        continue
    }

    Write-Header -Total $sel.Count

    $result = Invoke-Install -Selected $sel
    Show-Summary -Result $result

    # Open only the selected manual websites in the browser
    $manualOpenCount = 0
    foreach ($m in $result.Manuals) {
        if ($m.Url) {
            Start-Process $m.Url
            Start-Sleep -Milliseconds 600
            $manualOpenCount++
        }
    }

    if ($manualOpenCount -gt 0) {
        Write-Host "  $manualOpenCount website(s) were opened in the browser." -ForegroundColor DarkGray
    }

    Write-Host "  Press Enter to return to main menu..." -ForegroundColor DarkGray
    [Console]::ReadLine() | Out-Null
    
    # Refresh the installed-app list before returning
    Scan-InstalledApps
}
#endregion
