# ================================================================
# AutoInstaller.Core.ps1
# ----------------------------------------------------------------
# Pure logic function library (logging / CJK visual-width helpers / install detection / error classification)
#
# auto-installer.ps1 dot-sources this file (". $CORE_MODULE_PATH") at startup.
# Only functions that do not depend on Windows-only APIs (Console/Registry/Start-Process, etc.)
# live here, so tests/Core.Tests.ps1 can dot-source this file on its own and unit-test it with Pester.
# ================================================================

# ----------------------------------------------------------------
# Logging helper with level support.
# Writes to $LOG_FILE if it is set in the caller's scope; otherwise it silently does nothing
# (for example, when this file is dot-sourced on its own in a unit test).
# ----------------------------------------------------------------
function Write-Log {
    param(
        [ValidateSet("INFO", "DEBUG", "WARN", "ERROR")]
        [string]$Level = "INFO",
        [string]$Message,
        [string]$Detail = ""
    )
    if (-not $LOG_FILE) { return }

    $time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "[ $time ] [ $Level ] $Message"
    $logLine | Out-File $LOG_FILE -Append -Encoding UTF8
    if ($Detail) {
        $indentedDetail = ($Detail -split "`r?`n" | ForEach-Object { "    $_" }) -join "`r`n"
        $indentedDetail | Out-File $LOG_FILE -Append -Encoding UTF8
    }
}

# ----------------------------------------------------------------
# Calculate display width for CJK and other full-width characters
# ----------------------------------------------------------------
function Get-VisualWidth {
    param([string]$String)
    if (-not $String) { return 0 }
    $width = 0
    $enumerator = [System.Globalization.StringInfo]::GetTextElementEnumerator($String)
    while ($enumerator.MoveNext()) {
        $element = $enumerator.GetTextElement()
        $firstChar = $element[0]
        if ([System.Char]::IsSurrogate($firstChar) -or [int]$firstChar -gt 127) {
            $width += 2
        }
        else {
            $width += 1
        }
    }
    return $width
}

# ----------------------------------------------------------------
# Pad strings to a target visual width for full-width characters
# (.PadRight counts characters and breaks CJK alignment)
# ----------------------------------------------------------------
function Get-VisualPadRight {
    param([string]$String, [int]$Width = 64)
    $visualWidth = Get-VisualWidth $String
    $padNeeded = $Width - $visualWidth
    return $String + (" " * [Math]::Max(0, $padNeeded))
}

# ----------------------------------------------------------------
# Extract a substring by visual width (used to parse CJK-locale columns from winget list)
# ----------------------------------------------------------------
function Get-VisualSubstring {
    param(
        [string]$String,
        [int]$StartWidth,
        [int]$LengthWidth
    )
    if (-not $String) { return "" }

    $currentVisualWidth = 0
    $startIndex = -1
    $endIndex = -1

    $enumerator = [System.Globalization.StringInfo]::GetTextElementEnumerator($String)
    $charOffset = 0
    while ($enumerator.MoveNext()) {
        $element = $enumerator.GetTextElement()
        $elementLen = $element.Length
        $firstChar = $element[0]

        $charWidth = if ([System.Char]::IsSurrogate($firstChar) -or [int]$firstChar -gt 127) { 2 } else { 1 }

        if ($startIndex -eq -1 -and $currentVisualWidth -ge $StartWidth) {
            $startIndex = $charOffset
        }

        $currentVisualWidth += $charWidth
        $charOffset += $elementLen

        if ($startIndex -ne -1 -and $currentVisualWidth -gt ($StartWidth + $LengthWidth)) {
            $endIndex = $charOffset - $elementLen
            break
        }
    }

    if ($startIndex -eq -1) { return "" }
    if ($endIndex -eq -1) { $endIndex = $String.Length }

    $len = $endIndex - $startIndex
    if ($len -le 0) { return "" }

    return $String.Substring($startIndex, $len).Trim()
}

# ----------------------------------------------------------------
# Safely read the last N lines of a text file (works even while another process is still writing it)
# ----------------------------------------------------------------
function Get-SafeContentTail {
    param(
        [string]$Path,
        [int]$TailCount = 5
    )
    if (-not (Test-Path $Path)) { return @() }
    try {
        $fileStream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $reader = New-Object System.IO.StreamReader($fileStream, [System.Text.Encoding]::UTF8)
        $lines = [System.Collections.Generic.List[string]]::new()
        while (($line = $reader.ReadLine()) -ne $null) {
            $lines.Add($line)
        }
        $reader.Close()
        $fileStream.Close()

        $startIdx = [Math]::Max(0, $lines.Count - $TailCount)
        return $lines.GetRange($startIdx, $lines.Count - $startIdx)
    }
    catch {
        return @()
    }
}

# ----------------------------------------------------------------
# Smart installed-app matching helper (supports version and minor-series prefix matches).
#
# Stage 1 is an exact match; stages 2-5 are heuristic fallbacks. Whenever a fallback stage
# decides an app is "installed", it now logs a WARN line so false positives can be spotted
# after the fact by scanning the log file. Stages 4 and 5 already require a segment boundary
# (stage 4) or a minimum token length of 5 (stage 5) — fixes that were merged upstream in
# v0.0.10 to stop things like Notion.Notion wrongly matching an installed Notion.NotionCalendar.
# The WARN logging adds visibility on top of that fix so any remaining edge cases are easy to find.
# ----------------------------------------------------------------
function Test-IsAppInstalled {
    param(
        [string]$AppId
    )
    if (-not $AppId -or -not $script:installedIds) { return $false }
    $normalizedId = $AppId.ToLower()

    # 1. Check exact match first
    if ($script:installedIds.ContainsKey($normalizedId)) {
        return $true
    }

    # 2. Check custom mappings (alternate ID or display name)
    if ($script:APP_CUSTOM_MAPPINGS -and $script:APP_CUSTOM_MAPPINGS.ContainsKey($normalizedId)) {
        foreach ($alt in $script:APP_CUSTOM_MAPPINGS[$normalizedId]) {
            # ID match
            if ($script:installedIds.ContainsKey($alt)) {
                Write-Log -Level "WARN" -Message "[fallback:2-custom-id] '$normalizedId' -> treated as installed (matched alternate ID '$alt')"
                return $true
            }
            # Name match (including bidirectional partial match)
            foreach ($instName in $script:installedNames.Keys) {
                if ($instName.Contains($alt) -or $alt.Contains($instName)) {
                    Write-Log -Level "WARN" -Message "[fallback:2-custom-name] '$normalizedId' -> treated as installed (alternate name '$alt' ~ installed name '$instName')"
                    return $true
                }
            }
        }
    }

    # 3. Prefix matching for representative packages with active minor-version branching
    if ($normalizedId -match '^(python\.python\.3|microsoft\.visualstudiocode|git\.git)') {
        $prefix = $Matches[1]
        foreach ($instId in $script:installedIds.Keys) {
            if ($instId.StartsWith($prefix)) {
                Write-Log -Level "WARN" -Message "[fallback:3-version-prefix] '$normalizedId' -> treated as installed (prefix '$prefix' ~ installed ID '$instId')"
                return $true
            }
        }
    }

    # 4. Generic two-segment prefix match (for example, Google.Chrome).
    #    Requires a segment boundary (fixed upstream in v0.0.10): prevents false positives such as
    #    matching notion.notioncalendar for notion.notion.
    $parts = $normalizedId -split '\.'
    if ($parts.Count -ge 2) {
        $baseId = "$($parts[0]).$($parts[1])"
        foreach ($instId in $script:installedIds.Keys) {
            if ($instId -eq $baseId -or $instId.StartsWith("$baseId.")) {
                Write-Log -Level "WARN" -Message "[fallback:4-two-segment] '$normalizedId' -> treated as installed (base '$baseId' ~ installed ID '$instId')"
                return $true
            }
        }
    }

    # 5. Additional name-based fallback for GitHub apps and manually installed apps without IDs.
    #    Fixed upstream in v0.0.10 to require an exact match or a token of 5+ characters before
    #    allowing a partial match, to avoid short-token false positives.
    foreach ($instName in $script:installedNames.Keys) {
        if ($instName -eq $normalizedId) {
            return $true
        }
        if ($normalizedId.Length -ge 5 -and $instName.Contains($normalizedId)) {
            Write-Log -Level "WARN" -Message "[fallback:5-name-contains/uncertain] '$normalizedId' -> treated as installed (installed name '$instName' contains it). Possible false positive — worth confirming."
            return $true
        }
        if ($instName.Length -ge 5 -and $normalizedId.Contains($instName)) {
            Write-Log -Level "WARN" -Message "[fallback:5-name-contains/uncertain] '$normalizedId' -> treated as installed (it contains installed name '$instName'). Possible false positive — worth confirming."
            return $true
        }
    }

    # 6. Malware Zero special folder-path detection rule (portable format support)
    if ($normalizedId -eq "malware zero") {
        $desktop = [System.IO.Path]::Combine($env:USERPROFILE, "Desktop")
        $downloads = [System.IO.Path]::Combine($env:USERPROFILE, "Downloads")
        $paths = @(
            "C:\mzk",
            (Join-Path $desktop "mzk"),
            (Join-Path $downloads "mzk")
        )
        foreach ($p in $paths) {
            if (Test-Path $p) {
                return $true
            }
        }
    }

    return $false
}

# ----------------------------------------------------------------
# Classify a winget/installer failure output string into a human-readable reason.
# Some patterns still match Korean winget output text on Korean-locale systems; that is
# intentional and not left-over untranslated text.
# ----------------------------------------------------------------
function Get-FailReason {
    param([string]$Output)
    if (-not $Output) { return 'Unknown error' }
    if ($Output -match 'No package found|패키지를 찾을 수 없') { return 'Package not found' }
    if ($Output -match 'No applicable installer') { return 'No compatible installer found' }
    if ($Output -match 'exit code[:\s]+(-?\d+)') { return "Installation error (exit code $($Matches[1]))" }
    if ($Output -match 'Installer failed|installation.*실패') { return 'Installer error' }
    if ($Output -match 'No applicable upgrade') { return 'Upgrade unavailable' }
    if ($Output -match 'Failed in attempting to update') { return 'Source update failed' }
    if ($Output -match 'download|다운로드.*실패') { return 'Download failed' }
    return 'Unknown error'
}
