# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-07-17

### Changed
- **Split code into modules**: moved pure logic functions (`Write-Log`, `Get-VisualWidth`, `Get-VisualPadRight`, `Get-VisualSubstring`, `Get-SafeContentTail`, `Test-IsAppInstalled`, `Get-FailReason`) into `AutoInstaller.Core.ps1`, dot-sourced by `auto-installer.ps1` at startup. Enables independent Pester unit testing without triggering admin elevation, winget calls, or console control.
- **Externalized the app catalog**: moved the `$WINGET`/`$STORE`/`$GITHUB`/`$MANUAL`/`$APP_CUSTOM_MAPPINGS` hashtables into `catalog.json`. Adding or editing apps no longer requires touching the script. All 54 existing entries (winget 42 · store 3 · github 2 · manual 7) and 14 custom mappings were carried over without data loss.
- **Documented the winget exit-code constants**: added source/verification-date comments to `-1978335189` / `3010` / `1641`.

### Added
- **WARN logging for fallback matches**: `Test-IsAppInstalled` now logs a `WARN` line whenever one of its heuristic fallback stages (2-5: custom mapping, version prefix, two-segment, name-contains) decides an app is installed, so false positives can be spotted after the fact by scanning the log file.
- **Pester unit tests**: added `tests/Core.Tests.ps1`, covering `Get-VisualWidth`, `Get-VisualPadRight`, `Get-VisualSubstring`, `Get-FailReason`, and all 6 stages of `Test-IsAppInstalled` (including the v0.0.10 false-positive fixes and the WARN logging above).

### Fixed
- **KakaoTalk and Hancom Office Korean display-name matching regression**: the `chore: translate code comments and user-facing strings to English` pass (this repo, June 30) accidentally replaced the literal Korean display-name values `"카카오톡"` and `"한컴오피스"` in the `kakao.kakaotalk` and Hancom Office custom mappings with their English names. Those values are runtime data used to match `winget list`/display-name output on Korean-locale Windows, not comments, so the substitution silently broke installed-app detection for both on Korean systems (they would show as "not installed" even when present). Restored both Korean literals alongside the English variants in `catalog.json`.

## [0.0.11] - 2026-06-30

### Added
- Added Left/Right arrow navigation in the selection menu to jump to the previous/next section header.

## [0.0.10] - 2026-06-30

### Fixed
- Fixed false-positive install detection caused by two-segment prefix matching in `Test-IsAppInstalled`.
- Tightened the name-based fallback so short partial matches no longer trigger accidental installs.
- Fixed TUI row alignment for full-width characters by switching to visual-width padding.

### Changed
- `Refresh-EnvironmentPaths` now runs once after the batch only when at least one app was installed.
- `Get-FailReason` now recognizes negative exit codes.

## [0.0.9] - 2026-06-22

### Added
- Added AI-assistant attribution in the README, script header, and TUI menu.

## [0.0.8] - 2026-06-21

### Added
- Added detection and auto-skip support for Microsoft Office aliases and portable Malware Zero installs.

### Fixed
- Reworked the winget parser for CJK locales using visual-width substring extraction.
- Added custom alias mapping to reconcile winget catalog IDs, Store IDs, and display names.
- Moved installed-app caches to script scope to avoid variable pollution.

## [0.0.7] - 2026-06-21

### Added
- Added a dedicated bottom console status bar for live installation progress.

## [0.0.6] - 2026-06-21

### Added
- Added smarter preinstallation matching with exact ID, versioned prefix, and two-segment fallback checks.

## [0.0.5] - 2026-06-21

### Added
- Changed the main flow to return to the selection menu after a batch install instead of exiting.
- Added an automatic re-scan step when returning to the main menu.

### Fixed
- Wrapped blocking download steps in interruptible background processes.
- Centralized version strings in the TUI header and menus.

## [0.0.4] - 2026-06-21

### Added
- Mirrored raw winget output directly in the UI for live feedback.

### Fixed
- Forced UTF-8 console encoding so CJK output is preserved and parsed correctly.

## [0.0.3] - 2026-06-21

### Added
- Added real-time installation progress display from background log parsing.

### Fixed
- Fixed the interrupt overlay border rendering crash.

## [0.0.2] - 2026-06-21

### Fixed
- Rewrote the winget parser to support Korean and English locale headers.
- Removed an unsupported `winget list` flag.
- Prevented duplicate empty log files by moving elevation before log initialization.
- Reduced PATH logging noise.
- Corrected the Python winget package ID.
- Renamed the local `$args` variable to avoid clashing with PowerShell automation.
- Saved the script as UTF-8 with BOM so PowerShell can parse it reliably.

## [0.0.1] - 2026-06-21

### Added
- Added the keyboard-driven TUI selection screen.
- Added multi-level logging.
- Added Q/Esc-based interrupt handling.
- Added per-app installation result summaries.
