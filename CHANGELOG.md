# Changelog

All notable changes to this project will be documented in this file.

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
