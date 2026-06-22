# ================================================================
# Windows 자동 설치 스크립트 v0.0.9 (TUI Refactored with Advanced Log Levels)
# ※ 본 프로그램은 AI 코딩 어시스턴트의 도움을 받아 공동 개발되었습니다.
# ================================================================

#region ── 관리자 권한 자동 승격 (로그 생성 전 최우선 처리)
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    Start-Process $exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}
#endregion

# 로깅 폴더 및 파일 정의 (스크립트 실행 루트 폴더 하위의 logs)
$SCRIPT_VERSION = "0.0.9"

# Winget 종료 코드 상수
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

# 로그 레벨 지원 출력 함수
function Write-Log {
    param(
        [ValidateSet("INFO", "DEBUG", "WARN", "ERROR")]
        [string]$Level = "INFO",
        [string]$Message,
        [string]$Detail = ""
    )
    $time = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logLine = "[ $time ] [ $Level ] $Message"
    $logLine | Out-File $LOG_FILE -Append -Encoding UTF8
    if ($Detail) {
        $indentedDetail = ($Detail -split "`r?`n" | ForEach-Object { "    $_" }) -join "`r`n"
        $indentedDetail | Out-File $LOG_FILE -Append -Encoding UTF8
    }
}

Write-Log -Level "INFO" -Message "Administrator privileges confirmed."

# 콘솔 코드 페이지 및 입출력 인코딩 UTF-8 강제 (TUI 이모지 및 외부 winget 한글 출력 깨짐 방지)
if (Get-Command chcp -ErrorAction SilentlyContinue) {
    $null = & chcp 65001
}
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
[Console]::InputEncoding = [System.Text.Encoding]::UTF8

# TLS 1.2 강제 활성화 (GitHub API 및 웹 다운로드 에러 방지)
Write-Log -Level "DEBUG" -Message "Setting SecurityProtocol to TLS 1.2."
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# CJK 및 특수문자 전폭 문자열 너비 계산 함수
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

# CJK 지원 박스 라인 출력 함수
function Write-BorderLine {
    param([string]$Content, [string]$Color = "White", [int]$Width = 64)
    $visualWidth = Get-VisualWidth $Content
    $padNeeded = $Width - $visualWidth
    $paddedContent = $Content + (" " * [Math]::Max(0, $padNeeded))
    Write-Host "║$paddedContent║" -ForegroundColor $Color
}

# 안전한 Cursor Position 설정 헬퍼 (Buffer 경계 예외 방지)
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

# 환경 변수 새로고침 (PATH Refresh)
function Refresh-EnvironmentPaths {
    Write-Host "  -> 환경 변수(PATH) 실시간 갱신 중..." -ForegroundColor DarkGray
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

# Winget 미설치 시 준비 부트스트랩
Write-Log -Level "INFO" -Message "Checking if winget is available on system PATH."
Write-Host "패키지 매니저(winget) 상태를 점검하고 있습니다..." -ForegroundColor DarkGray
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Log -Level "WARN" -Message "winget not found on PATH. Attempting automatic bootstrap installation."
    Write-Host "winget을 찾을 수 없어 자동 설치를 시작합니다..." -ForegroundColor Yellow
    $msixUrl = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
    $msixPath = Join-Path $env:TEMP "Microsoft.DesktopAppInstaller.msixbundle"
    
    try {
        Write-Log -Level "INFO" -Message "Downloading winget package." -Detail "URL: $msixUrl`nTarget: $msixPath"
        Write-Host "winget 패키지 다운로드 중..." -ForegroundColor Gray
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $msixUrl -OutFile $msixPath -UseBasicParsing
        $ProgressPreference = 'Continue'
        
        Write-Log -Level "INFO" -Message "Installing downloaded AppInstaller msixbundle."
        Write-Host "winget 패키지 설치 중..." -ForegroundColor Gray
        Add-AppxPackage -Path $msixPath
        Remove-Item $msixPath -Force -ErrorAction SilentlyContinue
        
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Log -Level "INFO" -Message "winget successfully installed and verified."
            Write-Host "winget 설치 완료!" -ForegroundColor Green
        }
        else {
            Write-Log -Level "WARN" -Message "winget installed but command is not immediately visible on current session."
        }
    }
    catch {
        $err = $_.Exception.Message
        Write-Log -Level "ERROR" -Message "winget bootstrap installation failed." -Detail $err
        Write-Host "winget 자동 설치 실패: $err" -ForegroundColor Red
        Write-Host "Microsoft Store에서 '앱 설치 관리자(App Installer)'를 업데이트해 주세요." -ForegroundColor Yellow
    }
}
else {
    Write-Log -Level "INFO" -Message "winget verified on system PATH."
}

# 기설치 앱 정보를 스캔하고 전역 해시테이블에 갱신하는 모듈화 함수
$script:installedIds = @{}
$script:installedNames = @{}

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

function Scan-InstalledApps {
    Write-Log -Level "INFO" -Message "Querying installed apps using winget list."
    Write-Host "현재 설치되어 있는 프로그램 목록을 조회하고 있습니다..." -ForegroundColor DarkGray
    
    $script:installedIds = @{}
    $script:installedNames = @{}
    
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        try {
            $listOutput = & winget list --accept-source-agreements 2>&1
            
            # 구분선(----)으로 헤더/데이터 경계를 결정하고, 한국어/영어 양쪽 로케일 헤더를 지원하는 동적 파서
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
                
                # 한국어 로케일: "장치 ID", 영어 로케일: "Id" (대소문자 및 로케일 대응 보강)
                $krIdPos = $headerLine.IndexOf("장치 ID", [System.StringComparison]::OrdinalIgnoreCase)
                $enIdPos = $headerLine.IndexOf("Id", [System.StringComparison]::OrdinalIgnoreCase)
                $rawIdPos = if ($krIdPos -ge 0) { $krIdPos } else { $enIdPos }
                
                # 한국어 로케일: "버전", 영어 로케일: "Version"
                $krVerPos = $headerLine.IndexOf("버전", [System.StringComparison]::OrdinalIgnoreCase)
                $enVerPos = $headerLine.IndexOf("Version", [System.StringComparison]::OrdinalIgnoreCase)
                $rawVerPos = if ($krVerPos -ge 0) { $krVerPos } else { $enVerPos }
                
                if ($rawIdPos -ge 0 -and $rawVerPos -gt $rawIdPos) {
                    # 문자열 상의 원본 인덱스 대신 비주얼 너비 상의 인덱스를 계산하여 보정
                    $idStartWidth = Get-VisualWidth ($headerLine.Substring(0, $rawIdPos))
                    $versionStartWidth = Get-VisualWidth ($headerLine.Substring(0, $rawVerPos))
                    $idLengthWidth = $versionStartWidth - $idStartWidth
                    
                    Write-Log -Level "DEBUG" -Message "winget list header parsed in Visual Widths: idStartWidth=$idStartWidth versionStartWidth=$versionStartWidth idLengthWidth=$idLengthWidth"
                    
                    for ($i = $separatorIdx + 1; $i -lt $listOutput.Count; $i++) {
                        if ($null -eq $listOutput[$i]) { continue }
                        $line = $listOutput[$i].ToString()
                        if (-not $line -or $line.Trim() -eq "") { continue }
                        
                        # 비주얼 서브스트링으로 오차 없이 Name과 ID 분리 추출
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

# 기설치 앱 스마트 매칭 헬퍼 함수 (버전 및 마이너 계열 접두사 일치 지원)
function Test-IsAppInstalled {
    param(
        [string]$AppId
    )
    if (-not $AppId -or -not $script:installedIds) { return $false }
    $normalizedId = $AppId.ToLower()


    # 1. Exact Match 우선 확인
    if ($script:installedIds.ContainsKey($normalizedId)) {
        return $true
    }

    # 2. Custom Mappings 확인 (대체 ID 혹은 표시 이름이 설치되어 있는지)
    if ($script:APP_CUSTOM_MAPPINGS.ContainsKey($normalizedId)) {
        foreach ($alt in $script:APP_CUSTOM_MAPPINGS[$normalizedId]) {
            # ID 매칭
            if ($script:installedIds.ContainsKey($alt)) {
                return $true
            }
            # Name 매칭 (상호 부분 일치 포함)
            foreach ($instName in $script:installedNames.Keys) {
                if ($instName.Contains($alt) -or $alt.Contains($instName)) {
                    return $true
                }
            }
        }
    }

    # 3. 마이너 버전 분화가 활발한 특정 대표 패키지 접두사 매칭
    if ($normalizedId -match '^(python\.python\.3|microsoft\.visualstudiocode|git\.git)') {
        $prefix = $Matches[1]
        foreach ($instId in $script:installedIds.Keys) {
            if ($instId.StartsWith($prefix)) {
                return $true
            }
        }
    }

    # 4. 일반적인 상위 2세그먼트(예: Google.Chrome) 부분 일치 감지
    $parts = $normalizedId -split '\.'
    if ($parts.Count -ge 2) {
        $baseId = "$($parts[0]).$($parts[1])"
        foreach ($instId in $script:installedIds.Keys) {
            if ($instId.StartsWith($baseId)) {
                return $true
            }
        }
    }

    # 5. ID가 없는 GitHub 앱 및 수동 설치 앱 등 이름 기준 스마트 매치 추가 폴백
    foreach ($instName in $script:installedNames.Keys) {
        if ($instName.Contains($normalizedId) -or $normalizedId.Contains($instName)) {
            return $true
        }
    }

    # 6. Malware Zero 특수 폴더 경로 감지 규칙 (포터블 형식 대응)
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

# ================================================================
#region ── 앱 카탈로그
# ================================================================
$WINGET = [ordered]@{
    "Google Chrome"       = @{ id = "Google.Chrome"; sec = 60; cat = "Browser / AI" }
    "Claude AI"           = @{ id = "Anthropic.Claude"; sec = 30; cat = "Browser / AI" }
    "Antigravity"         = @{ id = "Google.Antigravity"; sec = 45; cat = "Browser / AI" }
    "Comet (Perplexity)"  = @{ id = "Perplexity.Comet"; sec = 90; cat = "Browser / AI" }
    "Git"                 = @{ id = "Git.Git"; sec = 45; cat = "Development" }
    "VS Code"             = @{ id = "Microsoft.VisualStudioCode"; sec = 60; cat = "Development" }
    "Python 3"            = @{ id = "Python.Python.3.13"; sec = 60; cat = "Development" }
    "PowerShell 7"        = @{ id = "Microsoft.PowerShell"; sec = 60; cat = "Development" }
    "PuTTY"               = @{ id = "PuTTY.PuTTY"; sec = 15; cat = "Development" }
    "DeepL"               = @{ id = "DeepL.DeepL"; sec = 40; cat = "AI / Productivity" }
    "Notion"              = @{ id = "Notion.Notion"; sec = 60; cat = "AI / Productivity" }
    "Notion Calendar"     = @{ id = "Notion.NotionCalendar"; sec = 60; cat = "AI / Productivity" }
    "Obsidian"            = @{ id = "Obsidian.Obsidian"; sec = 45; cat = "AI / Productivity" }
    "Miro"                = @{ id = "Miro.Miro"; sec = 60; cat = "AI / Productivity" }
    "Zotero"              = @{ id = "DigitalScholar.Zotero"; sec = 60; cat = "AI / Productivity" }
    "Devin Desktop"       = @{ id = "CognitionAI.DevinDesktop"; sec = 60; cat = "AI / Productivity" }
    "Discord"             = @{ id = "Discord.Discord"; sec = 60; cat = "Communication" }
    "KakaoTalk"           = @{ id = "Kakao.KakaoTalk"; sec = 45; cat = "Communication" }
    "Slack"               = @{ id = "SlackTechnologies.Slack"; sec = 60; cat = "Communication" }
    "VLC"                 = @{ id = "VideoLAN.VLC"; sec = 60; cat = "Media / Creative" }
    "GIMP"                = @{ id = "GIMP.GIMP"; sec = 180; cat = "Media / Creative" }
    "AIMP"                = @{ id = "AIMP.AIMP"; sec = 25; cat = "Media / Creative" }
    "Everything"          = @{ id = "voidtools.Everything"; sec = 15; cat = "Utility" }
    "PowerToys"           = @{ id = "Microsoft.PowerToys"; sec = 120; cat = "Utility" }
    "Winaero Tweaker"     = @{ id = "winaero.tweaker"; sec = 30; cat = "Utility" }
    "TreeSize Free"       = @{ id = "JAMSoftware.TreeSize.Free"; sec = 30; cat = "Utility" }
    "Geek Uninstaller"    = @{ id = "GeekUninstaller.GeekUninstaller"; sec = 15; cat = "Utility" }
    "Bandizip"            = @{ id = "Bandisoft.Bandizip"; sec = 30; cat = "Utility" }
    "Intel DSA"           = @{ id = "Intel.IntelDriverAndSupportAssistant"; sec = 60; cat = "System / Hardware" }
    "MSI Afterburner"     = @{ id = "Guru3D.Afterburner"; sec = 40; cat = "System / Hardware" }
    "Logi Options+"       = @{ id = "Logitech.OptionsPlus"; sec = 60; cat = "System / Hardware" }
    "Kensington Konnect"  = @{ id = "Kensington.KensingtonKonnect"; sec = 30; cat = "System / Hardware" }
    "Dygma Bazecor"       = @{ id = "DygmaLabs.Bazecor"; sec = 30; cat = "System / Hardware" }
    "LittleBigMouse"      = @{ id = "mgth.LittleBigMouse"; sec = 15; cat = "System / Hardware" }
    "AnyDesk"             = @{ id = "AnyDesk.AnyDesk"; sec = 30; cat = "Remote / Network" }
    "Parsec"              = @{ id = "Parsec.Parsec"; sec = 60; cat = "Remote / Network" }
    "NordVPN"             = @{ id = "NordSecurity.NordVPN"; sec = 60; cat = "Remote / Network" }
    "RaiDrive"            = @{ id = "OpenBoxLab.RaiDrive"; sec = 40; cat = "Remote / Network" }
    "Google Drive"        = @{ id = "Google.GoogleDrive"; sec = 90; cat = "Cloud / File" }
    "Quick Share"         = @{ id = "Google.QuickShare"; sec = 40; cat = "Cloud / File" }
    "Raspberry Pi Imager" = @{ id = "RaspberryPiFoundation.RaspberryPiImager"; sec = 60; cat = "Cloud / File" }
    "Steam"               = @{ id = "Valve.Steam"; sec = 60; cat = "Entertainment" }
}

$STORE = [ordered]@{
    "TranslucentTB"      = @{ id = "9PF4KZ2VN4W9"; sec = 15; cat = "Utility" }
    "Windows PC Manager" = @{ id = "9PM860492SZD"; sec = 30; cat = "Utility" }
    "Samsung Magician"   = @{ id = "XPDDT99J9GKB5C"; sec = 60; cat = "System / Hardware" }
}

$GITHUB = [ordered]@{
    "QMK MSYS"            = @{ Api = "https://api.github.com/repos/qmk/qmk_distro_msys/releases/latest"; Filter = "*.exe"; Args = "/VERYSILENT /SUPPRESSMSGBOXES /NORESTART"; sec = 90; cat = "Development" }
    "claude-usage-widget" = @{ Api = "https://api.github.com/repos/SlavomirDurej/claude-usage-widget/releases/latest"; Filter = "*win-Setup.exe"; Args = "/S"; sec = 60; cat = "AI / Productivity" }
}

$MANUAL = [ordered]@{
    "Adobe Creative Cloud" = @{ url = ""; note = "USB 수동 설치 필요 (정품 인증 및 로그인)" }
    "Microsoft Office"     = @{ url = ""; note = "USB 수동 설치 필요 (정품 인증 및 로그인)" }
    "한컴오피스"                = @{ url = ""; note = "USB 수동 설치 필요 (라이선스 키 필요)" }
    "Autodesk Fusion"      = @{ url = "https://manage.autodesk.com/"; note = "공식 사이트에서 설치 파일 다운로드 후 수동 설치" }
    "FreeFileSync"         = @{ url = "https://freefilesync.org/download.php"; note = "공식 사이트에서 다운로드 후 수동 설치 (무음 설치 미지원)" }
    "Equalizer APO"        = @{ url = "https://sourceforge.net/projects/equalizerapo/"; note = "공식 사이트에서 다운로드 후 수동 설치" }
    "Malware Zero"         = @{ url = "https://malzero.xyz"; note = "공식 사이트에서 다운로드 후 압축 해제하여 실행" }
}
#endregion

# 0. 커스텀 대체 ID 및 표시 이름 매핑 정의 (스토어 ID, GitHub, 특수 설치 매칭용)
$script:APP_CUSTOM_MAPPINGS = @{
    "9pm860492szd"             = @("microsoft.microsoftpcmanager", "pc manager", "windows pc manager") # Windows PC Manager
    "xpddt99j9gkb5c"           = @("samsung magician", "samsung.magician", "samsungmagician")        # Samsung Magician
    "9pf4kz2vn4w9"             = @("translucenttb")                                                 # TranslucentTB
    "cognitionai.devindesktop" = @("devin (user)", "devin")                               # Devin Desktop
    "kakao.kakaotalk"          = @("카카오톡", "kakaotalk")                                         # KakaoTalk 한글 매칭 보장
    
    "mgth.littlebigmouse"      = @("littlebigmouse", "arp\machine\x86\littlebigmouse")         # LittleBigMouse
    "qmk msys"                 = @("qmk msys", "qmk msys 1.12.0")                             # QMK MSYS
    "claude-usage-widget"      = @("claude-usage-widget", "claude-usage-widget 1.7.5")         # claude-usage-widget
    
    # 수동 설치 항목 매핑 추가
    "adobe creative cloud"     = @("adobe.creativecloud", "adobe creative cloud")
    "microsoft office"         = @("o365proplusretail", "microsoft 365", "office", "엔터프라이즈용 microsoft 365")
    "한컴오피스"                    = @("한컴오피스")
    "autodesk fusion"          = @("autodesk fusion", "fusion 360")
    "freefilesync"             = @("freefilesync")
    "equalizer apo"            = @("equalizer apo", "equalizerapo")
}

# ================================================================
#region ── 선택 TUI UI
# ================================================================
function Show-TUISelectionMenu {
    Write-Log -Level "DEBUG" -Message "Loading TUI selection menu."
    
    $categories = [ordered]@{}
    $addApp = {
        param($name, $appInfo, $source)
        $cat = $appInfo.cat
        if (-not $cat) {
            if ($source -eq "manual") { $cat = "Manual Setup" }
            else { $cat = "Others" }
        }
        if (-not $categories.Contains($cat)) {
            $categories[$cat] = [System.Collections.Generic.List[PSCustomObject]]::new()
        }
        
        # 이미 깔려있는지 점검 (수동 설치는 미설치 상태로 표기하기 위해 무조건 false 처리)
        $isInstalled = $false
        if ($source -ne "manual") {
            $detectId = if ($appInfo.id) { $appInfo.id } else { $name }
            if ($detectId) {
                if (Test-IsAppInstalled -AppId $detectId) {
                    $isInstalled = $true
                }
            }
        }
        
        # 이미 설치된 경우 기본적으로 선택(체크) 해제 (수동 설치는 항상 기본 체크 true)
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

    # 단일 배열로 평탄화
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

    # 화면 높이 자동 반응 높이 결정 (출력 라인 수 $pageSize + 10이 WindowHeight를 초과해 잘리지 않도록 마진 보정)
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
        Write-Host "║               Windows 자동 설치 프로그램 v$SCRIPT_VERSION              ║" -ForegroundColor Cyan
        Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
        Write-Host " [↑/↓] 이동  [Space] 선택/해제  [A] 전체선택  [N] 전체해제  [Enter] 시작  [Esc] 취소" -ForegroundColor DarkGray
        Write-Host " ※ 본 프로그램은 AI 코딩 어시스턴트의 도움을 받아 개발되었습니다." -ForegroundColor DarkGray
        Write-Host "----------------------------------------------------------------" -ForegroundColor Gray

        for ($i = 0; $i -lt $pageSize; $i++) {
            $lineIdx = $scrollOffset + $i
            if ($lineIdx -lt $listLines.Count) {
                $line = $listLines[$lineIdx]
                if ($line.IsHeader) {
                    $prefix = if ($lineIdx -eq $cursorIndex) { " > " } else { "   " }
                    
                    # 하위 항목의 선택 상태 계산
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
                    
                    $headerText = "$($line.Text.ToUpper()) ($($subApps.Count)개)"
                    $displayLine = "$prefix$headerCheck 📂 $headerText "
                    $fillerLength = [Math]::Max(2, 60 - (Get-VisualWidth $displayLine))
                    $displayLine += ("─" * $fillerLength)
                    
                    if ($lineIdx -eq $cursorIndex) {
                        Write-Host $displayLine.PadRight(64) -ForegroundColor Cyan -BackgroundColor DarkBlue
                    }
                    else {
                        Write-Host $displayLine.PadRight(64) -ForegroundColor Yellow
                    }
                }
                else {
                    $prefix = if ($lineIdx -eq $cursorIndex) { " > " } else { "   " }
                    $check = if ($line.Selected) { "[x]" } else { "[ ]" }
                    
                    # 수동 설치는 항상 DarkYellow(주황), 일반 앱은 포커스 시 Cyan / 기설치 시 DarkGreen / 미설치 시 White
                    $fg = if ($lineIdx -eq $cursorIndex) { "Cyan" }
                    elseif ($line.Source -eq "manual") { "DarkYellow" }
                    elseif ($line.IsInstalled) { "DarkGreen" }
                    else { "White" }
                          
                    $srcText = switch ($line.Source) {
                        "winget" { "Winget" }
                        "store" { "MS Store" }
                        "github" { "GitHub" }
                        "manual" { "수동" }
                    }
                    
                    $nameText = "$($line.Name) ($srcText)"
                    # 수동 설치 앱은 이미 감지되었더라도 [이미 설치됨] 라벨 표시 제외
                    if ($line.IsInstalled -and $line.Source -ne "manual") {
                        $nameText += " [이미 설치됨]"
                    }
                    
                    if ($lineIdx -eq $cursorIndex) {
                        Write-Host ("$prefix$check $nameText").PadRight(64) -ForegroundColor $fg -BackgroundColor DarkBlue
                    }
                    else {
                        Write-Host ("$prefix$check $nameText").PadRight(64) -ForegroundColor $fg
                    }
                }
            }
            else {
                Write-Host "".PadRight(64)
            }
        }
        Write-Host "----------------------------------------------------------------" -ForegroundColor Gray
        
        # 스크롤 위치 표시기
        $appIndex = ($listLines[0..$cursorIndex] | Where-Object { -not $_.IsHeader }).Count
        $totalApps = ($listLines | Where-Object { -not $_.IsHeader }).Count
        $aboveCount = [Math]::Max(0, $scrollOffset)
        $belowCount = [Math]::Max(0, $listLines.Count - $scrollOffset - $pageSize)
        $posText = " 위치: $appIndex / $totalApps"
        if ($aboveCount -gt 0 -or $belowCount -gt 0) {
            $posText += "  (▲ ${aboveCount} ▼ ${belowCount})"
        }
        Write-Host $posText.PadRight(64) -ForegroundColor DarkGray

        # 색상 범례
        Write-Host " ■" -ForegroundColor White -NoNewline; Write-Host " 미설치" -ForegroundColor DarkGray -NoNewline
        Write-Host "  ■" -ForegroundColor DarkGreen -NoNewline; Write-Host " 설치됨" -ForegroundColor DarkGray -NoNewline
        Write-Host "  ■" -ForegroundColor DarkYellow -NoNewline; Write-Host " 수동" -ForegroundColor DarkGray -NoNewline
        Write-Host "  ■" -ForegroundColor Cyan -NoNewline; Write-Host " 포커스" -ForegroundColor DarkGray

        $selectedCount = ($listLines | Where-Object { -not $_.IsHeader -and $_.Selected }).Count
        $totalCount = ($listLines | Where-Object { -not $_.IsHeader }).Count
        Write-Host " 선택됨: $selectedCount / $totalCount 개 앱 목록 (전체 $totalCount 개)".PadRight(64) -ForegroundColor Green

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
            "Spacebar" {
                if ($listLines[$cursorIndex].IsHeader) {
                    # 하위 항목 일괄 토글
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
                    Write-Host " [!] 선택된 앱이 없습니다. 설치하려면 최소 하나의 앱을 선택해 주세요.".PadRight(64) -ForegroundColor Yellow
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
                Write-BorderLine "  설치 진행 확인" "Cyan" $confirmWidth
                Write-Host "╠$lineBorder╣" -ForegroundColor Cyan
                Write-BorderLine "  선택된 앱: $($selItems.Count) 개" "White" $confirmWidth
                
                $min = [Math]::Floor($estSec / 60)
                $sec = $estSec % 60
                $timeStr = if ($min -gt 0) { "${min}분 ${sec}초" } else { "${sec}초" }
                Write-BorderLine "  예상 시간: 약 $timeStr" "White" $confirmWidth
                Write-BorderLine "  [Enter] 설치 시작  [Esc] 선택 화면으로 복귀" "DarkGray" $confirmWidth
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
#region ── 인터럽트 프롬프트 및 프로세스 실행 제어
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
    Write-Host (& $makeLine " [!] 설치 일시 중지됨 (Q / Esc 감지)") -ForegroundColor Yellow
    Write-Host (& $makeLine " 현재 설치 중: $AppName") -ForegroundColor Yellow
    Write-Host (& $makeLine "") -ForegroundColor Yellow
    Write-Host (& $makeLine "  1. 해당 항목 중지 (설치 강제 취소)") -ForegroundColor Yellow
    Write-Host (& $makeLine "  2. 전체 설치 중지 (남은 목록 스킵)") -ForegroundColor Yellow
    Write-Host (& $makeLine "  3. 계속 진행") -ForegroundColor Yellow
    Write-Host "  └$([string][char]0x2500 * $w)┘" -ForegroundColor Yellow
    Write-Host "  선택 (1-3): " -ForegroundColor Yellow -NoNewline

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

    # stdin 가로채기 방지를 위해 Temp 폴더에 빈 입력 가상 파일 준비
    $emptyStdin = Join-Path $env:TEMP "empty-stdin.txt"
    if (-not (Test-Path $emptyStdin)) {
        " " | Out-File $emptyStdin -Force -Encoding ASCII
    }

    # 해시테이블 splatting으로 파라미터 매핑 에러 해결 및 stdin 리다이렉션 추가
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

        # 실시간 진행상황 파싱 및 최하단 고정 상태 표시줄(Status Bar)에 갱신 (300ms 주기)
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
                        
                        # 현재 커서 위치 백업
                        $backLeft = [Console]::CursorLeft
                        $backTop = [Console]::CursorTop
                        
                        # 콘솔 최하단 라인 결정
                        $statusBarTop = [Console]::WindowHeight - 1
                        if ($statusBarTop -lt 0) { $statusBarTop = 0 }
                        
                        # 출력 문자열 빌드 및 가로폭 자르기
                        $statusBarLine = "  >> ${AppName}: $rawStatus"
                        $maxLen = [Console]::WindowWidth - 2
                        if ($maxLen -lt 10) { $maxLen = 60 }
                        if ($statusBarLine.Length -gt $maxLen) {
                            $statusBarLine = $statusBarLine.Substring(0, $maxLen - 3) + "..."
                        }
                        
                        # 상태바 영역에 갱신 출력
                        Set-SafeCursor 0 $statusBarTop
                        Write-Host ($statusBarLine.PadRight($maxLen)) -ForegroundColor Yellow -BackgroundColor Black -NoNewline
                        
                        # 커서 원래 자리 복원
                        Set-SafeCursor $backLeft $backTop
                    }
                }
                catch {}
            }
        }
    }

    # 프로세스 종료 후 상태 표시바 공백 클리어
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
#region ── TUI 출력 헬퍼
# ================================================================
function Write-Header {
    param([int]$Total)
    Clear-Host
    $w = 64
    $line = "═" * $w
    Write-Host "╔$line╗" -ForegroundColor Cyan
    Write-BorderLine "  Windows 자동 설치 스크립트  v$SCRIPT_VERSION" "Cyan" $w
    Write-Host "╠$line╣" -ForegroundColor Cyan
    Write-BorderLine "  총 $Total 개 설치 진행 예정" "Yellow" $w
    Write-Host "╚$line╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  ※ [Q] 또는 [Esc] 키를 누르면 다음 설치 프로세스부터 중단할 수 있습니다." -ForegroundColor DarkGray
    Write-Host ""
}

function Get-FailReason {
    param([string]$Output)
    if (-not $Output) { return '알 수 없는 오류' }
    if ($Output -match 'No package found|패키지를 찾을 수 없') { return '패키지 없음' }
    if ($Output -match 'No applicable installer') { return '호환 설치 파일 없음' }
    if ($Output -match 'exit code[:\s]+(\d+)') { return "설치 오류 (종료 코드 $($Matches[1]))" }
    if ($Output -match 'Installer failed|설치.*실패') { return '설치 프로그램 오류' }
    if ($Output -match 'No applicable upgrade') { return '업그레이드 불가' }
    if ($Output -match 'Failed in attempting to update') { return '소스 업데이트 실패' }
    if ($Output -match 'download|다운로드.*실패') { return '다운로드 실패' }
    return '알 수 없는 오류'
}

function Write-SectionBar {
    param([string]$Cat)
    Write-Host ""
    Write-Host "  ── $Cat " -ForegroundColor DarkCyan -NoNewline
    Write-Host ("─" * [Math]::Max(2, 52 - $Cat.Length)) -ForegroundColor DarkCyan
}
#endregion

# ================================================================
#region ── GitHub 릴리즈 설치
# ================================================================
function Install-FromGitHub {
    param([string]$Name, [hashtable]$Cfg, [string]$ProgressPrefix = "")
    $tmp = $null
    try {
        Write-Log -Level "INFO" -Message "GitHub release installation started for $Name." -Detail "API: $($Cfg.Api)"
        
        # GITHUB_TOKEN 환경 변수가 있으면 인증 요청 헤더 추가 (무인화 속도 제한 회피)
        $headers = @{ "User-Agent" = "AutoInstall"; "Accept" = "application/vnd.github+json" }
        if ($env:GITHUB_TOKEN) {
            $headers["Authorization"] = "token $env:GITHUB_TOKEN"
            Write-Log -Level "DEBUG" -Message "Using GITHUB_TOKEN authorization header."
        }
        
        $rel = Invoke-RestMethod -Uri $Cfg.Api -Headers $headers
        $asset = $rel.assets | Where-Object { $_.name -like $Cfg.Filter } | Select-Object -First 1
        if (-not $asset) {
            Write-Log -Level "ERROR" -Message "No matching GitHub release asset found." -Detail "Filter: $($Cfg.Filter)"
            return @{ Ok = $false; Reason = '릴리즈 자산 없음' }
        }
        
        $tmp = Join-Path $env:TEMP $asset.name
        Write-Log -Level "DEBUG" -Message "Downloading release asset." -Detail "URL: $($asset.browser_download_url)`nTemp path: $tmp"
        
        $ProgressPreference = 'SilentlyContinue'
        $downloadCmd = "Invoke-WebRequest -Uri '$($asset.browser_download_url)' -OutFile '$tmp' -UseBasicParsing"
        $res = Execute-ProcessWithInterrupt -FilePath "powershell" -ArgumentList "-NoProfile -Command $downloadCmd" -AppName "$Name 다운로드" -ProgressPrefix $ProgressPrefix
        $ProgressPreference = 'Continue'
        
        if ($res.Interrupted -eq "Current") {
            return @{ Ok = $false; Reason = "사용자 취소 (현재 항목 중지)"; Interrupted = "Current" }
        }
        elseif ($res.Interrupted -eq "All") {
            return @{ Ok = $false; Reason = "사용자 취소 (전체 중지)"; Interrupted = "All" }
        }
        
        if ($res.ExitCode -ne 0) {
            return @{ Ok = $false; Reason = "다운로드 실패 (종료 코드 $($res.ExitCode))"; Interrupted = "None" }
        }
        
        $a = if ($Cfg.Args) { $Cfg.Args } else { "" }
        Write-Log -Level "INFO" -Message "Executing GitHub installer process with interrupt check." -Detail "Path: $tmp`nArgs: $a"
        
        $res = Execute-ProcessWithInterrupt -FilePath $tmp -ArgumentList $a -AppName $Name -ProgressPrefix $ProgressPrefix
        
        Start-Sleep -Seconds 1
        
        $exit = $res.ExitCode
        $interrupted = $res.Interrupted
        
        if ($interrupted -eq "Current") {
            return @{ Ok = $false; Reason = "사용자 취소 (현재 항목 중지)"; Interrupted = "Current" }
        }
        elseif ($interrupted -eq "All") {
            return @{ Ok = $false; Reason = "사용자 취소 (전체 중지)"; Interrupted = "All" }
        }
        
        if ($res.Error) {
            return @{ Ok = $false; Reason = "설치 프로그램 실행 실패: $($res.Error)" }
        }

        Write-Log -Level "INFO" -Message "GitHub installer execution completed." -Detail "ExitCode: $exit"
        if ($exit -eq 0) { return @{ Ok = $true; Reason = $null; Interrupted = "None" } }
        return @{ Ok = $false; Reason = "설치 오류 (종료 코드 $exit)"; Interrupted = "None" }
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
#region ── Winget 설치 실행
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
        return @{ Ok = $false; Reason = "사용자 취소 (현재 항목 중지)"; Interrupted = "Current" }
    }
    elseif ($interrupted -eq "All") {
        return @{ Ok = $false; Reason = "사용자 취소 (전체 중지)"; Interrupted = "All" }
    }
    
    if ($res.Error) {
        return @{ Ok = $false; Reason = "프로세스 실행 실패: $($res.Error)" }
    }

    # 성공조건 체크 (0, 이미 설치됨(-1978335189 / 0x8A15005B / 2317112411), 재부팅 요구(3010, 1641))
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
#region ── 설치 실행
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
        
        # 루프 진입 시점에 이미 취소 키가 입력되었는지 검사
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if ($key.Key -eq [ConsoleKey]::Escape -or $key.Key -eq [ConsoleKey]::Q) {
                $cancelled = $true
            }
        }
        
        # 유저가 중단을 요청한 상태라면 남은 앱들은 모두 스킵 처리
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

        # 이미 설치되어 있는지 사전에 확인 (수동 설치는 강제 가이드를 위해 기설치 스킵 제외)
        $isAlreadyInstalled = $false
        if ($type -ne "manual") {
            $detectId = if ($src.id) { $src.id } else { $name }
            if ($detectId -and (Test-IsAppInstalled -AppId $detectId)) {
                $isAlreadyInstalled = $true
            }
        }

        if ($isAlreadyInstalled) {
            Write-Log -Level "INFO" -Message "$name is already installed. Skipping installer run."
            $resultLine = "  $prefix  $namePad ◽ 이미 설치됨"
            Write-Host $resultLine.PadRight(64) -ForegroundColor DarkGray
            $done.Add([PSCustomObject]@{ Name = $name; Time = 0; IsAlreadyInstalled = $true })
            continue
        }

        if ($type -eq "manual") {
            Write-Log -Level "INFO" -Message "$name marked for manual setup."
            Write-Host "  $prefix  $namePad 수동 등록 완료" -ForegroundColor Yellow
            $manuals.Add([PSCustomObject]@{ Name = $name; Url = $src.url; Note = $src.note })
            continue
        }

        Write-Log -Level "INFO" -Message "Installing $name ($type)"
        Write-Host "  $prefix  $namePad 설치 중..." -ForegroundColor DarkGray -NoNewline
        $start = Get-Date

        $res = switch ($type) {
            "winget" { Invoke-Winget -Id $src.id -AppName $name -ProgressPrefix $prefix }
            "store" { Invoke-Winget -Id $src.id -AppName $name -Extra "--source msstore" -ProgressPrefix $prefix }
            "github" { Install-FromGitHub -Name $name -Cfg $src -ProgressPrefix $prefix }
        }

        $end = Get-Date
        $duration = [Math]::Round(($end - $start).TotalSeconds)
        
        $ok = $res.Ok
        
        # Interrupted 상태 처리
        if ($res.Interrupted -eq "Current") {
            $ok = $false
            $res.Reason = "사용자 요청으로 설치 중단(해당 항목)"
        }
        elseif ($res.Interrupted -eq "All") {
            $ok = $false
            $res.Reason = "사용자 요청으로 설치 중단(전체 중지)"
            $cancelled = $true
        }
        
        $col = if ($ok) { "Green" } else { "Red" }
        $sym = if ($ok) { "✅" } else { "❌" }
        
        [Console]::Write("`r")
        $resultLine = "  $prefix  $namePad $sym ($duration초 소요)"
        Write-Host $resultLine.PadRight(64) -ForegroundColor $col
        
        if (-not $ok) {
            Write-Log -Level "ERROR" -Message "Installation failed for $name." -Detail $res.Reason
            Write-Host ("  {0}    → $($res.Reason)" -f (' ' * ($pad * 2 + 5))) -ForegroundColor DarkRed
            $failed.Add([PSCustomObject]@{ Name = $name; Reason = $res.Reason; Time = $duration })
        }
        else {
            Write-Log -Level "INFO" -Message "Installation succeeded for $name in $duration seconds."
            $done.Add([PSCustomObject]@{ Name = $name; Time = $duration; IsAlreadyInstalled = $false })
            Refresh-EnvironmentPaths
        }
    }

    Write-Log -Level "INFO" -Message "Installation loop completed." -Detail "Success: $($done.Count) | Failed: $($failed.Count) | Skipped: $($skipped.Count)"
    return @{ Done = $done; Failed = $failed; Manuals = $manuals; Skipped = $skipped }
}
#endregion

# ================================================================
#region ── 결과 요약
# ================================================================
function Show-Summary {
    param($Result)
    $w = 64; $line = "═" * $w
    Write-Host ""
    Write-Host "╔$line╗" -ForegroundColor Cyan
    Write-BorderLine "  설치 결과 요약" "Cyan" $w
    Write-Host "╠$line╣" -ForegroundColor Cyan
    
    $totalDoneTime = 0
    foreach ($d in $Result.Done) { $totalDoneTime += $d.Time }
    
    Write-BorderLine "  ✅ 성공: $($Result.Done.Count) 개 (총 $totalDoneTime 초 소요)" "Green" $w
    
    if ($Result.Failed.Count -gt 0) {
        $totalFailTime = 0
        foreach ($f in $Result.Failed) { $totalFailTime += $f.Time }
        Write-BorderLine "  ❌ 실패: $($Result.Failed.Count) 개" "Red" $w
    }
    Write-Host "╚$line╝" -ForegroundColor Cyan
 
    # 1. 성공 리스트 출력
    if ($Result.Done.Count -gt 0) {
        Write-Host ""
        Write-Host "  ── 성공 목록 " -ForegroundColor Green -NoNewline
        Write-Host ("─" * 48) -ForegroundColor DarkGreen
        foreach ($s in $Result.Done) {
            $namePad = $s.Name + (" " * [Math]::Max(0, 30 - (Get-VisualWidth $s.Name)))
            Write-Host "  ✅ $namePad" -ForegroundColor Green -NoNewline
            if ($s.IsAlreadyInstalled) {
                Write-Host "(이미 설치됨)" -ForegroundColor DarkGray
            }
            else {
                Write-Host "($($s.Time)초 소요)" -ForegroundColor Gray
            }
        }
    }

    # 2. 실패 리스트 출력
    if ($Result.Failed.Count -gt 0) {
        Write-Host ""
        Write-Host "  ── 실패 목록 " -ForegroundColor Red -NoNewline
        Write-Host ("─" * 48) -ForegroundColor DarkRed
        foreach ($f in $Result.Failed) {
            $namePad = $f.Name + (" " * [Math]::Max(0, 30 - (Get-VisualWidth $f.Name)))
            Write-Host "  ❌ $namePad" -ForegroundColor Red -NoNewline
            Write-Host "→  $($f.Reason) ($($f.Time)초 소요)" -ForegroundColor DarkRed
        }
    }

    # 3. 중단/스킵 리스트 출력
    if ($Result.Skipped.Count -gt 0) {
        Write-Host ""
        Write-Host "  ── 중단/스킵 목록 " -ForegroundColor Gray -NoNewline
        Write-Host ("─" * 46) -ForegroundColor DarkGray
        foreach ($s in $Result.Skipped) {
            Write-Host "  ◽ $s (중단됨)" -ForegroundColor Gray
        }
    }

    # 4. 선택된 수동 설치 대상 처리
    if ($Result.Manuals.Count -gt 0) {
        Write-Host ""
        Write-Host "  ── 수동 설치 필요 (선택됨) " -ForegroundColor Yellow -NoNewline
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
    
    # 상세 로그 경로 출력
    Write-Host ""
    Write-Host "  ※ 상세 설치 로그가 다음 경로에 저장되었습니다: " -ForegroundColor DarkGray
    Write-Host "     $LOG_FILE" -ForegroundColor Cyan
    Write-Host ""
}
#endregion

# ================================================================
#region ── 진입점
# ================================================================
Scan-InstalledApps

$scriptRunning = $true
while ($scriptRunning) {
    $sel = Show-TUISelectionMenu
    if ($null -eq $sel) {
        Write-Host "취소되었습니다. 프로그램을 종료합니다." -ForegroundColor Gray
        $scriptRunning = $false
        break
    }
    
    if ($sel.Count -eq 0) {
        Write-Host "선택된 앱이 없습니다. 다시 선택해 주세요." -ForegroundColor Yellow
        Start-Sleep -Seconds 1.5
        continue
    }

    Write-Header -Total $sel.Count

    $result = Invoke-Install -Selected $sel
    Show-Summary -Result $result

    # 선택된 수동 웹사이트만 브라우저로 띄우기
    $manualOpenCount = 0
    foreach ($m in $result.Manuals) {
        if ($m.Url) {
            Start-Process $m.Url
            Start-Sleep -Milliseconds 600
            $manualOpenCount++
        }
    }

    if ($manualOpenCount -gt 0) {
        Write-Host "  웹 사이트 $manualOpenCount 개가 브라우저에 열렸습니다." -ForegroundColor DarkGray
    }

    Write-Host "  Press Enter to return to main menu..." -ForegroundColor DarkGray
    [Console]::ReadLine() | Out-Null
    
    # 복귀 전 기설치 목록 최신화 재스캔
    Scan-InstalledApps
}
#endregion
