# Changelog

All notable changes to The Powerful Intune Bulk Actions Tool will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

> Changes on `dev` that have not yet been released to `main`.

---

## [1.1.0] — 2026-07-24

### Changed

- **Modernized UI** — complete visual refresh of the WPF interface using pure XAML styles and control templates (no new dependencies): Fluent-style tabs, card layout, restyled buttons/inputs/dropdowns/checkboxes, pill connection-status badges, color-coded Activity Log levels, and a redesigned busy overlay
- **Faster first run** — only the required `Microsoft.Graph` submodules are installed instead of the full meta-module (7 modules instead of 40+)
- **Automatic STA relaunch** — running `.\script.ps1` from a plain (MTA) Windows PowerShell console now relaunches itself with `-STA` automatically; the manual `-STA` flag is no longer needed
- **Configurable export/log directory** — optional `config.json` next to `script.ps1` (`{ "ExportDirectory": "D:\\Path" }`); when the configured or default `C:\Temp` location is not writable, the tool falls back to `%TEMP%\IntuneTool` automatically
- App version is now shown in the window title and logged at startup

### Fixed

- Removed a stray quoted line that printed `$Form.ShowDialog() | out-null` to the console on every launch

---

## [1.0.0] — 2026-03-15

### Initial Release

First public release of The Powerful Intune Bulk Actions Tool — a PowerShell/WPF graphical desktop application for Microsoft Intune administrators.

### Added

#### Core Application
- WPF-based graphical interface with three tabs: **Main** (authentication), **Reporting**, and **Actions**
- Asynchronous execution engine using `RunspacePool` + `DispatcherTimer` — long-running operations never freeze the UI
- Real-time **Activity Log** panel displaying live progress from background operations, including `Write-Host` and `Write-Warning` messages streamed from background runspaces
- Persistent **Audit Log** for tracking all destructive/write operations with before/after state
- Automatic **Microsoft Graph SDK** installation on first run (admin: `AllUsers` scope; standard user: `CurrentUser` scope)
- **STA mode** detection with clear guidance when the script is launched without `-STA`
- Graph API retry logic with exponential backoff on `429`, `500`, `502`, `503`, `504` errors
- Automatic log rotation: max 10 MB per file, 5 most recent files retained, stored in `C:\Temp\YYYYMMDD\`
- 7 log levels: `DEBUG`, `INFO`, `USER`, `REPORT`, `ACTION`, `WARNING`, `ERROR`
- CSV export for all reports and action results
- Clipboard copy for all report and action result grids

#### Targeting — Single & Bulk Device Mode
- **Single device** mode: target one device directly by identifier
- **Bulk mode**: provide a `.txt` file (one identifier per line) or paste identifiers directly into the UI
- Supported identifier types: **Intune Device ID**, **Entra Object ID**, **Serial Number**, **Device Name**

#### Reporting
- **Device Details & Specs** — full hardware/OS inventory from Intune
- **BitLocker Status** — encryption and key escrow status per device
- **Last Logged-on User** — most recent interactive session with user details
- **Autopilot Info** — deployment profile, group tag, enrollment status
- **TPM & BIOS / Hardware Export** — TPM version, secure boot, BIOS manufacturer/version
- **Policy Non-Compliance** — all non-compliant policies per device with details
- **OS Distribution** — OS/version breakdown across a group or device list
- **App Version Distribution** — versions of a specified app across devices
- **Group Assignments** — which policies and profiles are assigned to a given group
- **Group Members — Intune Info** — Intune device details for all members of an Entra group
- **Detected Apps** — all discovered applications across a device list
- **User Details** — Entra user profile data linked to device records

#### Actions
- **Import Devices to Group** — bulk-add devices to an Entra ID group by device identifier
- **Remove Devices from Group** — bulk-remove devices from an Entra ID group
- **Empty Group Members** — remove all current members from a specified group
- **Retire Devices** — send retire signal to devices via Intune
- **Update Autopilot Group Tag** — bulk-update the Autopilot group tag field
- **Bulk Rename Devices** — rename devices in Intune based on serial number mappings
- **Reinstall Android App** — trigger app reinstallation on Android devices
- **Delete Device Records** — delete device records from Intune, Autopilot, and/or Entra ID simultaneously, with per-target confirmation controls

#### Infrastructure
- `script.ps1` — entry point, UI event handlers, WPF bootstrap (~3,784 lines)
- `graphFunctions.psm1` — all Microsoft Graph API interactions (~2,926 lines)
- `otherFunctions.psm1` — logging, WPF UI helpers, CSV export (~1,219 lines)
- `MainWindow.xaml` — WPF window layout (~347 lines)
- `code documentation.md` — full architecture reference, function signatures, data flow diagrams, UI element reference
- MIT License

---

[Unreleased]: https://github.com/ppel123/The-Powerful-Intune-Bulk-Actions-Tool/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/ppel123/The-Powerful-Intune-Bulk-Actions-Tool/releases/tag/v1.0.0
