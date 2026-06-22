# Changelog

All notable changes to this project will be documented in this file.

## [0.0.9] - 2026-06-22

### Added
- **AI 도움 표기 추가**: `README.md`, 스크립트 헤더 주석 및 TUI 메인 메뉴에 AI의 도움을 받아 공동 개발된 프로그램임을 명시하는 안내 문구 및 주석 추가.

## [0.0.8] - 2026-06-21

### Added
- **MS Office 및 Malware Zero 감지 기능**: Microsoft Office 계열의 다양한 표시 명칭/별칭 매핑(`o365proplusretail`, `microsoft 365`, `office`, `엔터프라이즈용 microsoft 365`)을 추가하고, 레지스트리에 등록되지 않는 포터블 형태의 `Malware Zero` 경로(`C:\mzk`, 바탕화면/다운로드 폴더의 `mzk`) 감지 규칙을 구현하여 이미 존재할 경우 TUI 화면에서 초록색 `[이미 설치됨]` 상태로 표시하고 자동 스킵되도록 조치.

### Fixed
- **CJK (Korean) Locale Alignment for winget parser**: Introduced a visual-width based substring extractor (`Get-VisualSubstring`) to handle multi-byte CJK character offsets (like `카카오톡` which takes 8 visual cells but holds only 4 string chars). Prevents preinstalled package IDs from getting truncated (e.g. parsing `Kakao.KakaoTalk` as `kao.kakaotalk`), fixing false-uninstalled detections on non-English locales.
- **Store ID & GUID Alias Mapping**: Added a custom mappings dictionary (`$customMappings`) inside `Test-IsAppInstalled` to resolve discrepancy between winget catalogue identifiers (like Store ID `9PM860492SZD` or user scope GUIDs) and the actual display/package names parsed from `winget list` (like `Microsoft.MicrosoftPCManager` / `PC Manager`).
- **Unified Scope Bindings**: Shifted installed-app hashes from global-scope variables to script-scope ones (`$script:installedIds` and `$script:installedNames`), mitigating variable pollution risks.

## [0.0.7] - 2026-06-21

### Added
- **Dedicated Console Bottom Status Bar**: Decoupled the real-time installation progress string from the application item list. Real-time outputs (e.g. `>> Google Chrome: 다운로드 중 [  25%]`) are now rendered at the very bottom line (`WindowHeight - 1`) of the console in Yellow. Restores the cursor position instantly using cursor backups, preventing the installation checklist and the live progress from overlapping. Clears the status bar automatically upon process completion.

## [0.0.6] - 2026-06-21

### Added
- **Smart App Preinstallation Matching (`Test-IsAppInstalled`)**: Integrated a robust partial-prefix match utility. Standard contains check on preinstalled apps was replaced by a multi-tier comparison, supporting exact ID matching, prefix wildcard match for versioned apps (like `Python.Python.3.13` matching a preinstalled `python.python.3.12`), and 2-segment fallback comparison (e.g. matching `Google.Chrome.Beta` to `Google.Chrome`). Fixes the false-uninstalled status bugs where winget would immediately abort.

## [0.0.5] - 2026-06-21

### Added
- **Seamless Main Menu Return & Rescanning Loop**: Converted the script's entrypoint execution flow into a loop. When a batch installation ends, pressing Enter now returns you back to the main TUI Selection Menu instead of exiting.
- **Dynamic Re-scan Module (`Scan-InstalledApps`)**: Modulized the `winget list` querying engine. Calls `Scan-InstalledApps` automatically upon returning to the main menu, immediately checking off newly installed packages and coloring them Green (`[이미 설치됨]`) dynamically.

### Fixed
- **WebRequest Downloader Interrupts**: Wrapped blocking download steps (in `Download-TigerVNC` and `Install-FromGitHub`) into background PowerShell processes managed by `Execute-ProcessWithInterrupt`. This allows instant Q/Esc cancellation triggers to kill downloads immediately.
- **TUI Title and Header Version Sync**: Replaced hardcoded version strings (`v0.0.2` 등) in TUI menus and headers with a centralized 전역 `$SCRIPT_VERSION` variable, resolving version info mismatches.

## [0.0.4] - 2026-06-21

### Added
- **winget Raw Output UI Mirroring**: Refactored the real-time installation feedback loop. Instead of parsing and substituting custom summary strings, it now extracts the raw trimmed console output lines directly from winget (e.g. `다운로드 중 [  25%]`, `이미 설치된 기존 패키지를 찾았습니다...`). Dynamically truncates the string to prevent console wrap-around, restoring the native winget install feedback look-and-feel inside the TUI selection list.

### Fixed
- **Preinstalled App Detection Recovery (Console Encoding Lock)**: Resolved an issue where already installed apps were not being detected under normal PowerShell host environments. Forced the console host's input and output stream encodings to UTF-8 (`[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`) at script entry. This preserves the CJK Korean character codes in the winget list stdout, allowing the header and ID parser to function with 100% accuracy.

## [0.0.3] - 2026-06-21

### Added
- **Real-time Installation Progress Display**: Integrates a background log parsing loop during package installer runs. Dynamically scans the temporary stdout log to capture download progress percentages (e.g., `45%`), hash verification status, or startup states, displaying the information inline under the active installer item row using smooth carriage returns (`\r`).

### Fixed
- **UAC Interrupt Prompt Char Multiplication Error**: Resolved a crash where the interrupt overlay (`Show-InterruptPrompt`) threw an `InvalidOperation` exception ("The operation '[System.Char] * [System.Int32]' is not defined") when rendering box borders. Casted the border character `[char]0x2500` to `[string]` explicitly to support native PowerShell duplication.

## [0.0.2] - 2026-06-21

### Fixed
- **Korean Locale Winget Parser**: Completely rewrote the `winget list` parser to dynamically detect Korean ("이름", "장치 ID", "버전") and English ("Name", "Id", "Version") header columns. Utilizes column start positions and separators (`----`) to guarantee accurate installation checks under CJK locales.
- **winget list Argument Fix**: Removed the unsupported `--accept-package-agreements` flag from `winget list` execution to prevent command errors.
- **Double Logging Prevention**: Restructured script startup to perform Administrator checks and process elevation *before* initializing the log file, preventing the generation of redundant empty log files.
- **PATH Log Reduction**: Silenced machine and user PATH details inside `Refresh-EnvironmentPaths` unless critical errors occur, preventing log files from bloating with duplicated environment path dumps.
- **Python ID Correction**: Updated Python 3's winget package ID from `Python.Python.3` to the exact versioned ID `Python.Python.3.13` (or latest stable release) to prevent package lookup failures.
- **Variable Namespace Safety**: Replaced the local variable name `$args` in `Invoke-Winget` with `$wingetArgs` to prevent collision with PowerShell's default automatic variable `$args`.
- **File Encoding Fix**: Re-saved the script file with UTF-8 BOM encoding to ensure PowerShell properly parses special Korean character sets and terminal box-drawing borders (`═`, `║`, `╔` etc.) without throwing syntactic errors.

## [0.0.1] - 2026-06-21

### Added
- **TUI Selection Screen**: Keyboard-driven (Arrow keys, Space, Enter) interactive application selection screen with dynamic window page height adaptation.
- **Log Management System**: Added multi-level logging (`INFO`, `DEBUG`, `WARN`, `ERROR`) outputs, now separated dynamically into hourly/timestamped files (`logs/auto-install-log-yyyyMMdd_HHmmss.txt`).
- **Interactive Interrupt System**: Polling loops for `Q` and `Esc` keys during installation. Triggers an inline TUI warning overlay allowing:
  1. Aborting the current installation (Process Kill).
  2. Aborting the entire batch run.
  3. Continuing execution.
- **TUI Cursor/Layout Restoration**: The interrupt overlay cleanly wipes its trace (10 console lines) and restores the cursor position when "Continue" is selected.
- **Auto-Skip Already Installed Apps**: Scans preexisting software using `winget list` beforehand and skips installer routines at runtime, coloring installed apps distinctly (`DarkGreen`) in the TUI selection menu.
- **GitHub Token Integration**: Detects `$env:GITHUB_TOKEN` to override rate-limiting for GitHub API queries.

### Fixed
- **TUI Installed App Detection Hotfix**: Resolved a critical bug where already-installed software was not colored differently or deselected in TUI menus. Fixed by replacing the un-supported `.Contains()` method call with `.ContainsKey()` lookup and enforcing `.ToLower()` case-insignificant bindings.
- **Winget LE Encoding Bug**: Refactored `winget list` parsing output to run directly as a PowerShell string array pipeline, completely bypassing UTF-16 LE text file encoding errors.
- **Process Splatting Syntax Error**: Replaced array parameter splatting with a robust hashtable splatting dictionary (`@splat`) for `Start-Process`, preventing positional matching runtime crashes.
- **Keyboard Latency during Install**: Configured child installer process input redirections to feed from a virtual empty text file, effectively blocking them from hijacking keyboard focus, making Q/Esc interrupts immediate and highly responsive.
