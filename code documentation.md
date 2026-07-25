# The Powerful Intune Bulk Actions Tool - Complete Code Documentation

**Version:** 1.2.0  
**Last Updated:** July 2026  
**Total Lines of Code:** ~10,539 lines (script.ps1: 4,469, graphFunctions.psm1: 3,853, otherFunctions.psm1: 1,247, MainWindow.xaml: 970)

---

## Table of Contents

1. [Overview](#1-overview)
2. [Project Structure](#2-project-structure)
3. [Supported Environments & Usage](#3-supported-environments--usage)
4. [Application Architecture](#4-application-architecture)
5. [Code Flow](#5-code-flow)
6. [Asynchronous Background Tasks](#6-asynchronous-background-tasks)
7. [File Documentation](#7-file-documentation)
   - [script.ps1](#71-scriptps1)
   - [graphFunctions.psm1](#72-graphfunctionspsm1)
   - [otherFunctions.psm1](#73-otherfunctionspsm1)
   - [MainWindow.xaml](#74-mainwindowxaml)
8. [Function Reference](#8-function-reference)
9. [UI Element Reference](#9-ui-element-reference)
10. [Data Flow Patterns](#10-data-flow-patterns)
11. [Error Handling](#11-error-handling)
12. [Logging System](#12-logging-system)
13. [Files Created at Runtime](#13-files-created-at-runtime)

---

## 1. Overview

The Powerful Intune Bulk Actions Tool is a PowerShell-based WPF application designed for Microsoft Intune administrators. It provides a graphical interface for performing device management tasks including reporting and administrative actions.

### Key Capabilities

| Category | Features |
|----------|----------|
| **Reports (18)** | Device Information, Bitlocker Status, Last Logged-on User, Detected Apps, Group Assignments, Group Membership, Autopilot Info, TPM/Hardware Export, User Details, Policy Non-Compliance Settings, OS Distribution, App Version Distribution, Group Members Intune Info, **Stale Devices**, **Duplicate Device Records**, **App Install Status**, **Low Disk Space Devices**, **Primary User Mismatch** |
| **Actions (19)** | Import Devices to Group, Remove Devices from Group, Empty Group Members, Retire Devices, Update Autopilot Group Tag, Bulk Rename Devices, Remove Android App, Delete Device Records, **Sync Devices**, **Restart Devices**, **Rotate BitLocker Keys**, **Rotate LAPS Password**, **Remote Lock Devices**, **Defender Quick/Full Scan**, **Set Primary User**, **Set Device Category**, **Set Device Ownership**, **Send Custom Notification** |
| **Export** | CSV export and clipboard copy for all reports and action results |
| **Logging** | Comprehensive logging with rotation, log levels, audit log for write operations, live Activity Log panel |
| **UI** | Modern Fluent-style WPF theme (pure XAML, no external dependencies), asynchronous execution with busy overlays and Force Stop, automatic STA relaunch |

---

## 2. Project Structure

```
IntuneTool/
├── script.ps1                 # Main entry point (4,469 lines)
├── graphFunctions.psm1        # Graph API module (3,853 lines)
├── otherFunctions.psm1        # Utility module (1,247 lines)
├── MainWindow.xaml            # WPF UI definition + Fluent theme (970 lines)
├── MainImage.png              # Application logo
├── readme.md                  # User-facing documentation
├── CHANGELOG.md               # Version history
├── config.json                # OPTIONAL, user-created: { "ExportDirectory": "D:\\Path" }
└── .gitignore                 # Git ignore rules
```

---

## 3. Supported Environments & Usage

### Tested Environments

The Powerful Intune Bulk Actions Tool is fully tested and supported in the following environments:
- Standard PowerShell Console (5.1)
- PowerShell ISE
- Visual Studio Code (VS Code) PowerShell terminal
- PowerShell 7+ (PS7)

### How to Run the Tool

```powershell
.\script.ps1
```

That's it. For the WPF Graphical User Interface to function correctly, PowerShell requires **Single-Threaded Apartment (STA) mode** — but the script handles this itself: at startup it checks `[System.Threading.Thread]::CurrentThread.ApartmentState`, and if it is running in MTA mode it automatically relaunches itself in the same console with `-STA` (choosing `pwsh` or `powershell.exe` to match the current edition). PowerShell 7 and the ISE are STA by default.

#### What is STA and why is it required?
**STA (Single-Threaded Apartment)** is a thread concurrency model used by Microsoft's COM framework. Windows Presentation Foundation (WPF) — which powers the UI of this tool — relies heavily on COM components that demand STA mode for thread safety. Without the automatic relaunch, running in MTA mode would fail to load UI components with errors like `You cannot call a method on a null-valued expression` at `ShowDialog()`.

### Dependencies & Requirements

**PowerShell Requirements:**
| Dependency | Version | Purpose |
|------------|---------|---------|
| PowerShell | 5.1+ | Core scripting engine |
| WPF (PresentationFramework) | Built-in | User interface |
| Microsoft.VisualBasic | Built-in | UI input dialogs |

**Microsoft Graph SDK:**

Only the required submodules are installed automatically at first run (NOT the full `Microsoft.Graph` meta-module — this keeps first run to a couple of minutes). Install scope is `AllUsers` when elevated, `CurrentUser` otherwise.

| Module | Purpose |
|--------|---------|
| Microsoft.Graph.Authentication | Graph API authentication, `Invoke-MgGraphRequest` |
| Microsoft.Graph.DeviceManagement | Managed device operations (get/remove/retire) |
| Microsoft.Graph.DeviceManagement.Enrollment | Autopilot device identities |
| Microsoft.Graph.Devices.CorporateManagement | Mobile apps (imported by background runspaces) |
| Microsoft.Graph.Groups | Group management |
| Microsoft.Graph.Users | User lookups |
| Microsoft.Graph.Identity.DirectoryManagement | Entra ID device records |

### Required Graph API Permissions

These permissions are automatically requested when clicking "Sign-In" via the `Connect-ToMGGraph` function.

```powershell
# Read Permissions
DeviceManagementManagedDevices.Read.All     # Device info, encryption, logged-on users
DeviceManagementConfiguration.Read.All      # Device config policies, settings catalog, compliance, remediation scripts
DeviceManagementApps.Read.All               # Mobile apps, app protection, app config
DeviceManagementScripts.Read.All            # PowerShell scripts and assignments
Group.Read.All                               # Group information for assignment searches
DeviceManagementServiceConfig.Read.All      # Endpoint security policies, Autopilot info

# Write Permissions
Device.Read.All                              # Read device info for group import
User.Read.All                                # Resolve user UPNs (primary user assignment / mismatch report)
GroupMember.ReadWrite.All                    # Add/remove devices from groups
DeviceManagementManagedDevices.ReadWrite.All # Retire devices, Autopilot group tags, primary user/category/ownership
DeviceManagementManagedDevices.PrivilegedOperations.All # Sync, restart, key rotations, remote lock, Defender scans
```

**Note:** If you encounter "Forbidden" errors — including on the remote actions (Sync/Restart/Rotate/Lock/Scan) after upgrading — disconnect and sign in again to consent to the updated permission set.

### Full Connection Command

```powershell
Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All", "DeviceManagementConfiguration.Read.All", "DeviceManagementApps.Read.All", "DeviceManagementScripts.Read.All", "Group.Read.All", "DeviceManagementServiceConfig.Read.All", "Device.Read.All", "GroupMember.ReadWrite.All", "DeviceManagementManagedDevices.ReadWrite.All", "DeviceManagementManagedDevices.PrivilegedOperations.All", "User.Read.All"
```

---

## 4. Application Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        script.ps1 (Entry Point)                     │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────┐ │
│  │   XAML Loading  │  │  Event Handlers │  │   UI State Mgmt     │ │
│  └────────┬────────┘  └────────┬────────┘  └──────────┬──────────┘ │
└───────────┼─────────────────────┼─────────────────────┼─────────────┘
            │                     │                     │
            ▼                     ▼                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     graphFunctions.psm1                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │
│  │ Connection   │  │  Resolvers   │  │    Graph Operations      │   │
│  │ Functions    │  │  & Helpers   │  │  (Reports & Actions)     │   │
│  └──────────────┘  └──────────────┘  └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
            │                     │                     │
            ▼                     ▼                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     otherFunctions.psm1                              │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │
│  │   Logging    │  │  UI Helpers  │  │     Export Functions     │   │
│  │   System     │  │              │  │                          │   │
│  └──────────────┘  └──────────────┘  └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
            │                     │                     │
            ▼                     ▼                     ▼
┌─────────────────────────────────────────────────────────────────────┐
│                        MainWindow.xaml                               │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │
│  │   Home Tab   │  │ Reporting Tab│  │     Actions Tab          │   │
│  └──────────────┘  └──────────────┘  └──────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 5. Code Flow

### 5.1 Application Startup Sequence

```
1. script.ps1 starts
   │
   ├─► Set $script:AppVersion (shown in window title, logged at startup)
   │
   ├─► Ensure STA mode
   │   └─► If MTA: relaunch self with -STA in the same console, exit
   │
   ├─► Check required Microsoft.Graph SUBMODULES (7, not the meta-module)
   │   ├─► Detect admin context (Admin → AllUsers / Non-Admin → CurrentUser)
   │   └─► Install-Module only the missing ones
   │
   ├─► Import graphFunctions.psm1
   ├─► Import otherFunctions.psm1
   │
   ├─► Read optional config.json
   │   └─► Set-ExportDirectory (custom export/log base directory)
   │
   ├─► Initialize-AppLogging
   │   └─► Creates log file with rotation (C:\Temp\YYYYMMDD, %TEMP% fallback)
   │
   ├─► Load MainWindow.xaml
   │   └─► ConvertTo-EscapedXaml (path transformation)
   │
   ├─► Parse XAML and create WPF Form
   │   ├─► XamlReader.Load()
   │   └─► Set window title with version
   │
   ├─► Load all XAML controls into $WPF* variables
   │   └─► ForEach x:Name → Set-Variable
   │
   ├─► Start Activity Log tail timer (500 ms, feeds LvActivityLog)
   │
   ├─► Check existing Graph connection
   │   └─► Test-MGGraphConnection
   │
   ├─► Populate dropdown menus
   │   ├─► Report types (18 options)
   │   ├─► Action types (19 options)
   │   └─► Device ID types
   │
   ├─► Initialize async RunspacePool
   │   └─► Initialize-AsyncRunspacePool
   │
   ├─► Attach all event handlers
   │   ├─► Sign-In/Disconnect buttons
   │   ├─► Report type selection
   │   ├─► Action type selection
   │   ├─► Single/Multiple device selection
   │   ├─► Generate Report button
   │   ├─► Perform Action button
   │   ├─► Force Stop buttons
   │   └─► Export/Copy buttons
   │
   └─► Show-Form
       └─► $Form.ShowDialog()
```

### 5.2 Report Execution Flow

```
User clicks "Generate Report"
   │
   ├─► Validate Graph connection
   │   └─► Test-MGGraphConnection
   │
   ├─► Validate permissions
   │   └─► Test-GraphPermissions -OperationType "Report"
   │
   ├─► Validate report type selected
   │
   ├─► Validate input fields (report-type specific)
   │   ├─► No input reports: Export TPM/Hardware
   │   ├─► Single input reports: Get Group Assignments
   │   ├─► File input reports: Get Autopilot Info
   │   └─► Standard reports: based on $IsSingleDevice
   │
   ├─► Log report execution start
   │   └─► Write-AppLogSection
   │
   ├─► Execute report function
   │   └─► graphFunctions.psm1 function call
   │
   ├─► Process returned data
   │   └─► Format into hashtable with arrays
   │
   ├─► Display results
   │   ├─► FillDataListView (for tabular data)
   │   └─► ResultsTextBox.Text (for text data)
   │
   ├─► Show export button
   │   └─► UnhideItems @("ExportReportButton")
   │
   └─► Log completion
       └─► Write-AppLogResults
```

### 5.3 Action Execution Flow

```
User clicks "Perform Action"
   │
   ├─► Validate Graph connection
   │
   ├─► Validate permissions for actions
   │
   ├─► Action-specific validation
   │   ├─► File path exists
   │   ├─► ID type selected
   │   └─► Group/tag specified (where applicable)
   │
   ├─► Show confirmation dialog
   │   └─► MessageBox YesNo
   │
   ├─► Execute action function
   │   └─► graphFunctions.psm1 function
   │
   ├─► Process results
   │
   ├─► Display in ListView
   │   └─► FillDataListView
   │
   ├─► Show summary dialog
   │   └─► Success/Error counts
   │
   └─► Log completion
```

### 5.4 Device Resolution Flow

```
Resolve-DeviceIdentifier called
   │
   ├─► Switch on DesiredID type
   │   ├─► "EntraID ID" → Direct use
   │   ├─► "Intune ID" → Query by ID
   │   ├─► "Device Name" → Filter by deviceName
   │   └─► "Serial Number" → Filter by serialNumber
   │
   ├─► Invoke-GraphRequestWithRetry
   │   └─► Handle 429/500 errors with backoff
   │
   ├─► Return resolved device info
   │   └─► Hashtable with EntraId, IntuneId, DeviceName
   │
   └─► Error handling
       └─► New-ErrorResult on failure
```

---

## 6. Asynchronous Background Tasks

The application implements a robust asynchronous execution pattern to prevent UI freezing during long-running operations. All reports and actions now execute in background threads while keeping the UI responsive.

### 6.1 Overview

**Problem:** When executing Graph API operations (especially batch operations on multiple devices), the UI thread blocks, causing the application to appear frozen and unresponsive.

**Solution:** Use PowerShell's RunspacePool with BeginInvoke() for non-blocking execution, combined with DispatcherTimer for completion polling and UI thread marshaling.

### 6.2 Components

#### Core Helper Functions (script.ps1)

| Function | Purpose |
|----------|---------|
| `Initialize-AsyncRunspacePool` | Creates a shared RunspacePool with imported modules |
| `Close-AsyncRunspacePool` | Disposes RunspacePool resources on application exit |
| `Set-UiBusy` | Shows/hides the busy overlay with status text |
| `Invoke-AsyncOperation` | Main orchestration function for async execution |

#### XAML Busy Overlay Elements

| Element | Tab | Purpose |
|---------|-----|---------|
| `BusyOverlay` | Reporting | Semi-transparent overlay with ZIndex=100 |
| `BusyOverlayAction` | Actions | Semi-transparent overlay for actions tab |
| `BusyProgressBar` | Reporting | Indeterminate progress indicator |
| `BusyProgressBarAction` | Actions | Indeterminate progress indicator |
| `BusyStatusText` | Reporting | Status message (e.g., "Retrieving device info...") |
| `BusyStatusTextAction` | Actions | Status message for action operations |

### 6.3 Usage Pattern

```powershell
# 1. Capture parameters in script-scope variable (to avoid closure issues)
$script:AsyncParams = @{ DeviceId = $deviceId; IdType = $idType }

# 2. Call Invoke-AsyncOperation with all required parameters
Invoke-AsyncOperation -ScriptBlock {
    param($params)
    # This runs in background thread - NO UI access allowed here
    return Get-IntuneDeviceInfo -IsSingleDevice $true -DeviceId $params.DeviceId -IDType $params.IdType
} -ArgumentList $script:AsyncParams `
  -BusyMessage "Retrieving device info..." `
  -Tab "Report" `
  -ControlsToDisable @($WPFReportType, $WPFGenerateReportButton) `
  -OnSuccess {
    param($returnedData)
    # This runs on UI thread - safe to update UI
    if ($null -ne $returnedData) {
        FillDataListView -ListView $WPFlistview -Headers @("Property", "Value") -Data $returnedData
        UnhideItems -ItemNames @("listview", "ExportReportButton")
    }
} -OnError {
    param($exception)
    # This runs on UI thread - handle errors
    [System.Windows.MessageBox]::Show("Error: $($exception.Message)", "Error")
}
```

### 6.4 How It Works

```
┌─────────────────────────────────────────────────────────────────────────┐
│ 1. User clicks button (e.g., Generate Report)                          │
│    └─► Invoke-AsyncOperation called                                     │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 2. Set-UiBusy -IsBusy $true -Tab "Report" -Message "Working..."         │
│    ├─► Shows BusyOverlay (ZIndex=100, semi-transparent)                 │
│    ├─► Shows BusyProgressBar (IsIndeterminate=True)                     │
│    └─► Disables specified controls                                      │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 3. PowerShell.BeginInvoke() on RunspacePool                             │
│    └─► ScriptBlock executes in background thread                        │
│    └─► UI thread remains responsive                                     │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 4. DispatcherTimer polls every 100ms                                    │
│    └─► Checks $handle.IsCompleted                                       │
│    └─► UI stays responsive during polling                               │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 5. When complete: Timer stops, EndInvoke() called                       │
│    ├─► On Success: OnSuccess callback via Dispatcher.Invoke             │
│    └─► On Error: OnError callback via Dispatcher.Invoke                 │
└─────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────┐
│ 6. Set-UiBusy -IsBusy $false                                            │
│    ├─► Hides BusyOverlay                                                │
│    └─► Re-enables controls                                              │
└─────────────────────────────────────────────────────────────────────────┘
```

### 6.5 Important Constraints

| Constraint | Description |
|------------|-------------|
| **No UI Access in ScriptBlock** | The background script cannot access WPF controls directly |
| **Script-Scope Parameters** | Use `$script:AsyncParams` to pass data - closures don't work across runspaces |
| **Module Re-import** | RunspacePool has modules pre-imported in InitialSessionState |
| **Callback Threading** | OnSuccess/OnError run on UI thread via `$Form.Dispatcher.Invoke()` |
| **Sequential Calls Only** | Don't run multiple async operations in parallel |

### 6.6 Error Handling and UI Restore

The async pattern ensures UI state is always restored, even on errors:

```powershell
try {
    $result = $ps.EndInvoke($handle)
    # Check for errors in PowerShell streams
    if ($ps.Streams.Error.Count -gt 0) {
        # Handle error - call OnError callback
    } else {
        # Success - call OnSuccess callback
    }
} finally {
    # ALWAYS restore UI state
    Set-UiBusy -IsBusy $false -Tab $Tab -ControlsToEnable $ControlsToDisable
    $ps.Dispose()
}
```

### 6.7 Scalability Notes

- **RunspacePool Size:** Currently set to min=1, max=4 runspaces
- **Timer Interval:** 100ms polling provides responsive feedback
- **Memory:** Each runspace has pre-imported modules (~50MB overhead)
- **Cleanup:** `Close-AsyncRunspacePool` is called on form close to release resources

### 6.8 Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| UI stays busy after completion | Timer not stopping | Check `$timer.Stop()` is called in finally block |
| "Variable not found" errors | Closure issue | Use `$script:AsyncParams` pattern |
| Module functions not available | Missing module import | Verify `InitialSessionState` setup |
| Results not displaying | Wrong thread | Ensure UI updates use `Dispatcher.Invoke()` |
| Memory leak | RunspacePool not closed | Call `Close-AsyncRunspacePool` on exit |

---

## 7. File Documentation

### 7.1 script.ps1

**Purpose:** Main application entry point, async infrastructure, UI event handling, report/action orchestration.

**Line Count:** ~4,469 lines

#### Key Functions

| Function | Purpose |
|----------|---------|
| `Initialize-AsyncRunspacePool` | Creates RunspacePool with pre-imported modules |
| `Close-AsyncRunspacePool` | Disposes RunspacePool resources |
| `Set-UiBusy` | Shows/hides busy overlay with status text |
| `Invoke-AsyncOperation` | Main async orchestration with callbacks |
| `ConvertTo-EscapedXaml` | Transforms XAML for PowerShell WPF loading |
| `Add-ActivityLogEntry` | Parses log lines and feeds them into the real-time Activity Log ListView |
| `Show-FilePicker` | WPF file open dialog helper |
| `Add-SelectFileButton` | Adds a "Select file..." browse button to a grid |
| `Update-LastSyncTime` | Updates the "Connected: ..." sync time label on the Home tab |
| `Update-DeviceCount` | Counts devices in a file or pasted text and updates a count label |
| `Resolve-MultipleDeviceInput` | Resolves bulk device input to a file path; writes a temp file from pasted text |
| `Copy-ListViewToClipboard` | Copies ListView data to clipboard as tab-separated text |
| `Initialize-AndroidAppSelection` | Populates Android app dropdown for Remove Android App action |
| `Initialize-DeviceCategorySelection` | Populates device category dropdown (async) for Set Device Category action |
| `Show-Form` | Displays main window with error handling |

#### State Variables

| Variable | Type | Purpose |
|----------|------|---------|
| `$script:IsSingleDevice` | Boolean/Null | Tracks single vs multiple device mode for reports |
| `$script:IsSingleDeviceAction` | Boolean/Null | Tracks single vs multiple device mode for actions |
| `$script:AppLogPath` | String | Path to current log file |
| `$script:AsyncRunspacePool` | RunspacePool | Shared pool for async operations |
| `$script:ActiveAsyncContext` | Hashtable | Holds current async operation state (PowerShell instance, handle, callbacks, ForceStopped flag) |
| `$script:AsyncFetchAppsParams` | Hashtable | Parameters for the async Android app fetch operation |
| `$script:LogTailOffset` | Int64 | Byte offset used by log tail timer for reading new log lines |
| `$script:LogTailTimer` | DispatcherTimer | 500 ms timer that polls the log file and feeds new entries into the Activity Log ListView |
| `$script:LastOpenDir` | String | Persists the last directory used in file picker dialogs |
| `$script:LastReportTempFile` | String/Null | Path to the temp file created from pasted report device IDs; cleaned up on next run |
| `$script:LastActionTempFile` | String/Null | Path to the temp file created from pasted action device IDs; cleaned up on next run |

#### Event Handlers

| Handler | Purpose |
|---------|---------|
| `$WPFSignInButtonCopy.Add_Click` | Initiates Graph connection |
| `$WPFDisconnectBtn.Add_Click` | Disconnects from Graph |
| `ReportType.Add_SelectionChanged` | Shows/hides UI elements based on report selection |
| `SingleOrMultipleDevices.Add_SelectionChanged` | Toggles between single/multiple device input |
| `ActionType.Add_SelectionChanged` | Shows/hides UI elements based on action selection |
| `SingleOrMultipleDevicesAction.Add_SelectionChanged` | Toggles input mode for actions |
| `MainTabControl.Add_SelectionChanged` | Clears descriptions when switching tabs |
| `$WPFPerformActionButton.Add_Click` | Executes selected action (async) |
| `$WPFGenerateReportButton.Add_Click` | Executes selected report |
| `$WPFExportReportButton.Add_Click` | Exports report ListView to CSV |
| `$WPFExportActionButton.Add_Click` | Exports action ListView to CSV |
| `$Form.Add_Closing` | Logs application shutdown |

---

### 7.2 graphFunctions.psm1

**Purpose:** All Microsoft Graph API interactions, device resolution, and data retrieval.

**Line Count:** ~3,853 lines

**Exported Functions:** 36

#### Connection Functions

| Function | Purpose |
|----------|---------|
| `Test-MGGraphConnection` | Checks if connected to Microsoft Graph |
| `Connect-ToMGGraph` | Establishes Graph connection with required scopes |
| `Test-GraphPermissions` | Validates permissions for Report or Action operations |

#### Helper Functions

| Function | Purpose | Parameters |
|----------|---------|------------|
| `New-ErrorResult` | Creates standardized error hashtable | Message, Status |
| `ConvertTo-SafeFilterString` | Sanitizes a string for safe use in Graph API OData `$filter` queries | Value |
| `Invoke-GraphRequestWithRetry` | Graph request with retry/backoff for 429/500 | Uri, Method, Body, MaxRetries |
| `Test-FilePath` | Validates file path existence | FilePath |
| `New-ResultsHashtable` | Initializes hashtable with empty arrays | Keys |
| `Add-ResultToHashtable` | Appends values to hashtable arrays | Hashtable, Values |
| `Resolve-DeviceIdentifier` | Resolves device by various ID types | DeviceIdentifier, DesiredID |
| `Resolve-GroupIdentifier` | Resolves group by Object ID or Name | GroupID, IDType |
| `Get-AllGraphPages` | Handles Graph API pagination | InitialResponse |
| `Invoke-ForEachDevice` | Generic bulk device processing | FilePath, DesiredID, ProcessingScript |

#### Report Functions

| Function | Purpose | Input Modes |
|----------|---------|-------------|
| `Get-IntuneDeviceInfo` | Full device information | Single/Multiple |
| `Get-IntuneDeviceEncryptionDetails` | Bitlocker encryption status | Single/Multiple |
| `Get-IntuneDeviceLastLoggedOnUser` | Last logged-on user with details | Single/Multiple |
| `Get-IntuneGroupAssignments` | All policy assignments for a group | Single Group |
| `Test-IntuneDeviceGroupMembership` | Check if device is in group | Single/Multiple |
| `Get-IntuneAutopilotInfo` | Autopilot enrollment status | Multiple Only |
| `Get-EntraUserDetails` | User info by UPN | Single/Multiple |
| `Get-PolicyNonComplianceSettings` | Non-compliant settings per device | Multiple Only |
| `Get-TPMAndBIOSInfo` | TPM/BIOS/Hardware info for all devices | All Devices (auto) |
| `Get-IntuneDetectedApps` | Detected apps on device(s) | Single/Multiple |
| `Get OS Distribution` | OS build version distribution by platform | Platform Selection |
| `Get App Version Distribution` | App version distribution across devices | Platform + App Selection |
| `Get Group Members Intune Info` | Group device members with Intune details | Group Name/ID |
| **`Get-StaleIntuneDevices`** | Devices with no check-in for N+ days (fleet-wide scan) | Days threshold |
| **`Get-DuplicateIntuneDevices`** | Serials with multiple Intune records, keep/cleanup suggestions | None (fleet-wide) |
| **`Get-LowDiskSpaceDevices`** | Devices below a free-space threshold in GB (fleet-wide scan) | GB threshold |
| **`Get-PrimaryUserMismatchReport`** | Devices where primary user ≠ last logged-on user (cached user lookups) | None (fleet-wide) |
| **`Get-AppInstallStatusReport`** | Per-device install state for a selected app via `retrieveDeviceAppInstallationStatusReport` (paged POST, downloaded to temp file) | App selection |

#### Action Functions

| Function | Purpose | Input |
|----------|---------|-------|
| `Import-DevicesToGroup` | Add devices to Entra group | Single/Multiple + Group |
| `Remove-DevicesFromGroup` | Remove devices from group | Multiple + Group |
| `Clear-GroupMembers` | Remove all members from group | Group only |
| `Invoke-IntuneDeviceRetire` | Retire devices with confirmation | Multiple |
| `Update-AutopilotGroupTag` | Update Autopilot group tags | Multiple + Tag |
| `Remove-IntuneDeviceRecords` | Delete device records from Intune, Autopilot, and Entra ID | Multiple + Options |
| `Resolve-DeviceIdsFromInput` | Resolves device IDs from single input or file path to a common format | FilePath/SingleId + IDType |
| `Invoke-AndroidAppChangeAssignments` | Changes app assignment intent (Install/Uninstall) on devices | DeviceId, AppId, Action |
| **`Invoke-IntuneBulkDeviceAction`** | Generic engine for Sync / Restart / Rotate BitLocker Keys / Rotate LAPS Password / Remote Lock / Defender Quick+Full Scan | Multiple + ActionName |
| **`Set-IntuneDevicePrimaryUser`** | Sets the Intune primary user (resolves the UPN once, then `users/$ref` POST per device) | Multiple + UPN |
| **`Get-IntuneDeviceCategories`** | Lists tenant device categories (feeds the category picker) | None |
| **`Set-IntuneDeviceCategory`** | Assigns a device category (`deviceCategory/$ref` PUT) | Multiple + Category |
| **`Set-IntuneDeviceOwnership`** | Flips ownership company/personal (PATCH `managedDeviceOwnerType`) | Multiple + Ownership |
| **`Send-IntuneCustomNotification`** | Sends a Company Portal push notification (iOS/Android) | Multiple + Title/Message |

#### Retry Logic

```powershell
# Invoke-GraphRequestWithRetry pattern
$maxRetries = 3
$retryCount = 0
$delay = 5  # seconds

while ($retryCount -lt $maxRetries) {
    try {
        $response = Invoke-MgGraphRequest ...
        return $response
    }
    catch {
        if ($_.Exception.Response.StatusCode -in @(429, 500, 502, 503, 504)) {
            $retryCount++
            $delay = $delay * 2  # Exponential backoff
            Start-Sleep -Seconds $delay
        }
        else {
            throw
        }
    }
}
```

---

### 7.3 otherFunctions.psm1

**Purpose:** Logging system, UI helper functions, and export functionality.

**Line Count:** ~1,247 lines

**Exported Functions:** 18

#### Configuration Constants

```powershell
$script:MaxLogFiles = 5           # Maximum number of log files to keep
$script:MaxLogSizeMB = 10         # Maximum log file size in MB
$script:DefaultLogLevel = "INFO"  # Default logging level
$script:LogLevelPriority = @{
    "DEBUG"   = 0
    "INFO"    = 1
    "USER"    = 2
    "REPORT"  = 3
    "ACTION"  = 4
    "WARNING" = 5
    "ERROR"   = 6
}
```

#### Logging Functions

| Function | Purpose | Key Parameters |
|----------|---------|----------------|
| `Initialize-AppLogging` | Creates log file with rotation | LogDirectory (optional), MaxLogFiles, MaxLogSizeMB |
| `Write-AppLog` | Main logging function | Message, Level, Details |
| `Write-AuditLog` | Audit trail for write/destructive operations (before/after state) | Operation, Target, Result, Details |
| `Write-AppLogSection` | Section headers in log | Title |
| `Write-AppLogResults` | Logs operation results | Results, Operation |
| `Format-ActionableError` | Builds user-friendly error messages with next steps | ErrorType, Identifier, Operation |
| `Get-AppLogPath` | Returns current log path | None |

#### Export Functions

| Function | Purpose | Key Parameters |
|----------|---------|----------------|
| `Set-ExportDirectory` | Sets export/log base path (called by config.json support) | Path |
| `Get-ExportDirectory` | Gets today's dated export directory; falls back to `%TEMP%\IntuneTool` when the base is not writable | None (default base: `C:\Temp`) |
| `Export-ListViewToCsv` | Exports ListView to CSV | ListView, ExportName |

#### UI Helper Functions

| Function | Purpose | Parameters |
|----------|---------|------------|
| `UnhideItems` | Shows WPF elements | ItemNames (array) |
| `HideItems` | Hides WPF elements | ItemNames (array) |
| `FillDataListView` | Populates ListView from hashtable | ListView, Headers, Data |

#### Log Rotation Logic

```powershell
# Initialize-AppLogging pattern
# Base directory: config.json ExportDirectory > C:\Temp > %TEMP%\IntuneTool fallback
$logDir = Get-ExportDirectory        # e.g. C:\Temp\20260725
$existingLogs = Get-ChildItem -Path $logDir -Filter "IntuneTool_*.log" |
    Sort-Object LastWriteTime -Descending

# Keep only MaxLogFiles (per day folder)
if ($existingLogs.Count -ge $MaxLogFiles) {
    $existingLogs | Select-Object -Skip ($MaxLogFiles - 1) |
        Remove-Item -Force
}

# Create new log file
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logPath = Join-Path $logDir "IntuneTool_$timestamp.log"
```

---

### 7.4 MainWindow.xaml

**Purpose:** WPF user interface definition, including the complete modern theme.

**Line Count:** ~970 lines

#### Modern Theme (v1.1+)

All styling lives in `Window.Resources` as pure XAML styles and control templates — no external theme libraries. Includes: Fluent-style tab strip with accent underline, card layout, retemplated Button/TextBox/ComboBox/CheckBox/Expander/ListView/GridViewColumnHeader/ToolTip, pill-style connection badges, and color-coded Activity Log levels. Important quirk: the TextBox template must NOT add a Margin bound to Padding on `PART_ContentHost` — WPF applies the control Padding internally, and doubling it clips the text.

#### Tab Structure

| Tab | Purpose | Key Elements |
|-----|---------|--------------|
| Home Tab | Welcome screen, Sign-in | SignInButtonCopy, DisconnectBtn, Connected, NotConnectedLabel, LastSyncTimeLabel |
| Reporting Tab | Report selection and display | ReportType, listview, BusyOverlay, ExportReportButton |
| Actions Tab | Action execution | ActionType, listviewAction, BusyOverlayAction, ExportActionButton |

#### Busy Overlay Elements

| Element | Purpose |
|---------|---------|
| `BusyOverlay` | Semi-transparent overlay for Reporting tab (ZIndex=100) |
| `BusyOverlayAction` | Semi-transparent overlay for Actions tab (ZIndex=100) |
| `BusyProgressBar` | Indeterminate progress bar in Reporting overlay |
| `BusyProgressBarAction` | Indeterminate progress bar in Actions overlay |
| `BusyStatusText` | Status message in Reporting overlay |
| `BusyStatusTextAction` | Status message in Actions overlay |

#### Android App Selection Elements

| Element | Purpose |
|---------|---------|
| `RowAppSelectionPanel` | Container for Android app selection row |
| `AndroidAppLabel` | Label for app selection dropdown |
| `AndroidAppCombo` | ComboBox populated with Android apps |

#### Rename Options Elements

| Element | Purpose |
|---------|---------|
| `RenameOptionsPanel` | Container for rename options |
| `RenamePrefixBox` | TextBox for naming prefix |
| `RenamePlatformCombo` | ComboBox for platform filter (Windows/Android/iOS) |

#### Custom Notification Elements (v1.2)

| Element | Purpose |
|---------|---------|
| `RowNotificationPanel` | Container for the Send Custom Notification inputs |
| `NotificationTitleBox` | TextBox for the notification title |
| `NotificationMessageBox` | Multiline TextBox for the notification message |

**Panel reuse note (v1.2):** several new features repurpose existing panels at runtime instead of adding new XAML — `PolicyIDLabel`/`PolicyIDBox` double as the threshold input for the Stale Devices and Low Disk Space reports, `GroupTagLabel`/`GroupTagBox` double as the UPN input for Set Primary User, and `AndroidAppLabel`/`AndroidAppCombo` double as the category/ownership picker. Labels are reset at the top of each SelectionChanged handler.

#### UI Element Reference

See [Section 9: UI Element Reference](#9-ui-element-reference) for complete listing.

---

## 8. Function Reference

### 8.1 graphFunctions.psm1 Exports

```powershell
Export-ModuleMember -Function @(
    # Connection functions
    'Test-MGGraphConnection',
    'Connect-ToMGGraph',
    'Test-GraphPermissions',
    
    # Helper functions (public for reuse)
    'Invoke-GraphRequestWithRetry',
    'Test-FilePath',
    'New-ErrorResult',
    'ConvertTo-SafeFilterString',
    
    # Device information functions
    'Get-IntuneDeviceInfo',
    'Get-IntuneDeviceEncryptionDetails',
    'Get-IntuneDeviceLastLoggedOnUser',
    'Get-IntuneAutopilotInfo',
    'Get-TPMAndBIOSInfo',
    'Get-IntuneDetectedApps',
    
    # Group-related functions
    'Get-IntuneGroupAssignments',
    'Import-DevicesToGroup',
    'Test-IntuneDeviceGroupMembership',
    'Remove-DevicesFromGroup',
    'Clear-GroupMembers',
    
    # Action functions
    'Invoke-IntuneDeviceRetire',
    'Update-AutopilotGroupTag',
    'Remove-IntuneDeviceRecords',
    'Resolve-DeviceIdsFromInput',
    'Invoke-AndroidAppChangeAssignments',

    # Bulk remote actions (v1.2)
    'Invoke-IntuneBulkDeviceAction',
    'Set-IntuneDevicePrimaryUser',
    'Get-IntuneDeviceCategories',
    'Set-IntuneDeviceCategory',
    'Set-IntuneDeviceOwnership',
    'Send-IntuneCustomNotification',

    # Fleet-wide reports (v1.2)
    'Get-StaleIntuneDevices',
    'Get-DuplicateIntuneDevices',
    'Get-LowDiskSpaceDevices',
    'Get-PrimaryUserMismatchReport',
    'Get-AppInstallStatusReport',

    # User functions
    'Get-EntraUserDetails',

    # Policy functions
    'Get-PolicyNonComplianceSettings'
)
```

### 8.2 otherFunctions.psm1 Exports

```powershell
Export-ModuleMember -Function @(
    # Configuration functions
    'Get-ExportDirectory',
    'Set-ExportDirectory',

    # Logging functions
    'Initialize-AppLogging',
    'Write-AppLog',
    'Write-AuditLog',
    'Format-ActionableError',
    'Write-AppLogSection',
    'Write-AppLogResults',
    'Get-AppLogPath',

    # Helper functions (reduce code repetition)
    'Test-FileInputValidation',
    'Get-IdentifierType',
    'Get-ResultSummary',

    # UI helper functions
    'UnhideItems',
    'HideItems',
    'FillDataListView',
    'Export-ListViewToCsv',

    # Device rename functions
    'Get-IntuneDevicesForRename',
    'Set-IntuneDeviceName'
)
```

### 8.3 Function Signatures

#### Connection Functions

```powershell
function Test-MGGraphConnection {
    # Returns: [bool] - True if connected, False otherwise
}

function Connect-ToMGGraph {
    # Returns: [bool] - True if connection successful
}

function Test-GraphPermissions {
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Report", "Action")]
        [string]$OperationType
    )
    # Returns: [hashtable] @{ IsValid = [bool]; Message = [string] }
}
```

#### Resolver Functions

```powershell
function Resolve-DeviceIdentifier {
    param(
        [Parameter(Mandatory=$true)]
        [string]$DeviceIdentifier,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("EntraID ID", "Intune ID", "Device Name", "Serial Number")]
        [string]$DesiredID
    )
    # Returns: [hashtable] @{ 
    #   EntraId = [string]
    #   IntuneId = [string]
    #   DeviceName = [string]
    #   SerialNumber = [string]
    #   Found = [bool]
    # }
}

function Resolve-GroupIdentifier {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GroupID,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("Group Object ID", "Group Name")]
        [string]$IDType
    )
    # Returns: [hashtable] @{
    #   ObjectId = [string]
    #   DisplayName = [string]
    #   Found = [bool]
    # }
}
```

#### Report Functions

```powershell
function Get-IntuneDeviceInfo {
    param(
        [Parameter(Mandatory=$true)]
        [bool]$IsSingleDevice,
        
        [Parameter(Mandatory=$true)]
        [string]$IDorFilePath,
        
        [Parameter(Mandatory=$true)]
        [string]$DesiredID
    )
    # Returns: [hashtable] with device properties as arrays
}

function Get-IntuneGroupAssignments {
    param(
        [Parameter(Mandatory=$true)]
        [string]$GroupID,
        
        [Parameter(Mandatory=$true)]
        [string]$IDType
    )
    # Returns: [hashtable] @{
    #   PolicyName = [string[]]
    #   PolicyType = [string[]]
    #   AssignmentType = [string[]]
    #   PolicyId = [string[]]
    # }
}

function Get-TPMAndBIOSInfo {
    param(
        [Parameter(HelpMessage = "Number of devices to process per batch")]
        [ValidateRange(1, 100)]
        [int]$BatchSize = 20,

        [Parameter(HelpMessage = "Throttle limit for parallel processing (PS7+)")]
        [ValidateRange(1, 20)]
        [int]$ThrottleLimit = 10
    )
    # Returns: [hashtable] @{
    #   DeviceName = [string[]]
    #   SerialNumber = [string[]]
    #   TPMVersion = [string[]]
    #   TPMSpecificationVersion = [string[]]
    #   BIOSVersion = [string[]]
    #   ... (21 properties total)
    #   _RawResults = [PSCustomObject[]]  # For CSV export
    # }
}
```

#### Action Functions

```powershell
function Import-DevicesToGroup {
    param(
        [Parameter(Mandatory=$true)]
        [bool]$IsSingleDevice,
        
        [Parameter(Mandatory=$true)]
        [string]$IDorFilePath,
        
        [Parameter(Mandatory=$true)]
        [string]$DesiredID,
        
        [Parameter(Mandatory=$true)]
        [string]$GroupID,
        
        [Parameter(Mandatory=$true)]
        [string]$GroupIDType
    )
    # Returns: [hashtable] @{
    #   DeviceID = [string[]]
    #   DeviceName = [string[]]
    #   Status = [string[]]
    #   Message = [string[]]
    # }
}

function Invoke-IntuneDeviceRetire {
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        
        [Parameter(Mandatory=$true)]
        [string]$DesiredID
    )
    # Returns: [hashtable] with DeviceID, DeviceName, LastSync, Ownership, Status, Message
}

function Remove-IntuneDeviceRecords {
    # DESTRUCTIVE ACTION: Deletes device records from Intune, Autopilot, and Entra ID
    param(
        [Parameter(Mandatory=$true)]
        [string]$FilePath,              # Path to file containing device identifiers
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("Serial Number", "Device Name", "Intune ID")]
        [string]$DesiredID,             # Type of identifier in file
        
        [Parameter(Mandatory=$false)]
        [bool]$DeleteIntune = $true,    # Delete from Intune Managed Devices
        
        [Parameter(Mandatory=$false)]
        [bool]$DeleteAutopilot = $true, # Delete from Windows Autopilot
        
        [Parameter(Mandatory=$false)]
        [bool]$DeleteEntraId = $true,   # Delete from Entra ID (Azure AD)
        
        [Parameter(Mandatory=$false)]
        [bool]$WhatIf = $true           # Dry run mode (default ON for safety)
    )
    # Returns: [hashtable] with InputValue, DeviceName, SerialNumber,
    #   IntuneManagedDeviceId, AutopilotIdentityId, EntraDirectoryObjectId,
    #   IntuneDeleteStatus, AutopilotDeleteStatus, EntraDeleteStatus,
    #   ErrorIntune, ErrorAutopilot, ErrorEntra, WhatIfMode
    
    # Deletion Steps:
    # 1. Resolve device from Intune using identifier
    # 2. Delete Intune Managed Device (Remove-MgDeviceManagementManagedDevice)
    # 3. Find Autopilot device by serial, delete (Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity)
    # 4. Resolve Entra ID device from AzureAdDeviceId, delete (Remove-MgDevice)
    
    # IMPORTANT: Entra ID deletion requires resolving the directory object ID
    # from the AzureAdDeviceId using Get-MgDevice -Filter "deviceId eq '$azureAdDeviceId'"
    # then using Remove-MgDevice -DeviceId $entraDevice.Id (the directory object ID)
}
```

#### Logging Functions

```powershell
function Write-AppLog {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Message,
        
        [Parameter(Mandatory=$false)]
        [ValidateSet("DEBUG", "INFO", "USER", "REPORT", "ACTION", "WARNING", "ERROR")]
        [string]$Level = "INFO",
        
        [Parameter(Mandatory=$false)]
        [string]$Details = ""
    )
}

function Write-AuditLog {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Operation,      # e.g. "DeviceRetire", "SetPrimaryUser"

        [Parameter(Mandatory=$true)]
        [string]$Target,         # Device/group name

        [string]$TargetType = "Device",
        [string]$BeforeState = "",
        [string]$AfterState = "",
        [string]$Result = "Success",
        [string]$ErrorMessage = "",
        [string]$Details = ""
    )
    # Writes an audit trail entry for every write/destructive operation
}
```

---

## 9. UI Element Reference

### 9.1 Home Tab Elements

| Element Name | Type | Purpose |
|-------------|------|---------|
| `MainImage` | Image | Application logo |
| `SignInButtonCopy` | Button | Initiates Graph sign-in (accent style) |
| `DisconnectBtn` | Button | Disconnects from Graph |
| `NotConnectedLabel` | Label | Red pill badge "Not Connected" |
| `ConnectedPanel` | StackPanel | Container shown when connected |
| `Connected` | Label | Green pill badge "Connected" |
| `LastSyncTimeLabel` | TextBlock | "Connected: <time>" caption |
| `MainTextBox` | TextBlock | Welcome message |

### 9.2 Reporting Tab Elements

| Element Name | Type | Purpose |
|-------------|------|---------|
| `SelectReport` | Label | "Select Report:" label |
| `ReportType` | ComboBox | Report type dropdown |
| `ReportDescriptionLabel` | TextBlock | Description of selected report |
| `SelectSingleOrMultiple` | Label | Single/multiple selection label |
| `SingleOrMultipleDevices` | ComboBox | Single/multiple dropdown |
| `SingleDevice` | Label | Single device input label |
| `SingleDeviceInfoChoice` | ComboBox | ID type dropdown (single) |
| `SingleDeviceInfoBox` | TextBox | Device identifier input |
| `MultipleDevices` | Label | Multiple devices input label |
| `MultipleDevicesInfoChoice` | ComboBox | ID type dropdown (multiple) |
| `MultipleDevicesInfoBox` | TextBox | File path input |
| `GroupInputLabelReporting` | Label | Group input label |
| `GroupInputBoxReporting` | TextBox | Group name/ID input |
| `PolicyIDLabel` | Label | Policy ID label (repurposed as threshold label for Stale/Low Disk reports) |
| `PolicyIDBox` | TextBox | Policy GUID input (repurposed as days/GB threshold input) |
| `DeviceCountLabel` | TextBlock | Live "(N devices)" count for file/pasted input |
| `PastedDevicesTextBox` | TextBox | Multiline paste-IDs input (alternative to file) |
| `PostRequestNote` | Label | POST request info note |
| **`PlatformSelectLabel`** | Label | "Select Platform:" label |
| **`PlatformSelectCombo`** | ComboBox | Platform dropdown (Windows/Android/iOS/macOS) |
| **`AppSelectLabel`** | Label | "Select App:" label |
| **`AppSelectCombo`** | ComboBox | App dropdown (populated dynamically) |
| `listview` | ListView | Results display |
| `ResultsTextBox` | TextBox | Text results (group assignments) |
| `ExportReportButton` | Button | Export to CSV |
| `CopyReportButton` | Button | Copy results to clipboard |
| `GenerateReportButton` | Button | Execute report |
| **BusyOverlay** | Border | Semi-transparent busy overlay (ZIndex=100) |
| **BusyProgressBar** | ProgressBar | Indeterminate progress indicator |
| **BusyStatusText** | TextBlock | Status message during async operation |
| **ForceStopReportButton** | Button | Force stop active report generation |

### 9.3 Actions Tab Elements

| Element Name | Type | Purpose |
|-------------|------|---------|
| `SelectAction` | Label | "Select Action:" label |
| `ActionType` | ComboBox | Action type dropdown |
| `ActionDescriptionLabel` | TextBlock | Description of selected action |
| `SelectSingleOrMultipleAction` | Label | Single/multiple label |
| `SingleOrMultipleDevicesAction` | ComboBox | Single/multiple dropdown |
| `SingleDeviceAction` | Label | Single device label |
| `SingleDeviceInfoChoiceAction` | ComboBox | ID type dropdown (single) |
| `SingleDeviceInfoBoxAction` | TextBox | Device input |
| `MultipleDevicesAction` | Label | Multiple devices label |
| `MultipleDevicesInfoChoiceAction` | ComboBox | ID type dropdown (multiple) |
| `MultipleDevicesInfoBoxAction` | TextBox | File path input |
| `GroupInputLabel` | Label | Group input label |
| `GroupInputBox` | TextBox | Group name/ID input |
| `GroupTagLabel` | Label | Group tag label |
| `GroupTagBox` | TextBox | New group tag value |
| `listviewAction` | ListView | Results display |
| `ExportActionButton` | Button | Export to CSV |
| `PerformActionButton` | Button | Execute action |
| **BusyOverlayAction** | Border | Semi-transparent busy overlay (ZIndex=100) |
| **BusyProgressBarAction** | ProgressBar | Indeterminate progress indicator |
| **BusyStatusTextAction** | TextBlock | Status message during async operation |
| **ForceStopActionButton** | Button | Force stop active action |
| **RowDeleteOptionsPanel** | Grid | Container for Delete Device Records options (shown only when that action is selected) |
| **DeleteIntuneCheckbox** | CheckBox | Selects deletion from Intune Managed Devices (default: checked) |
| **DeleteAutopilotCheckbox** | CheckBox | Selects deletion from Windows Autopilot (default: checked) |
| **DeleteEntraCheckbox** | CheckBox | Selects deletion from Entra ID (default: checked) |
| **WhatIfModeCheckbox** | CheckBox | Enables dry run mode — resolves devices but performs no actual deletion (default: checked for safety) |
| **RenameOptionsPanel** | StackPanel | Container for rename options |
| **RenamePrefixBox** | TextBox | Naming prefix input |
| **RenamePlatformCombo** | ComboBox | Platform filter (Windows/Android/iOS) |
| **RowAppSelectionPanel** | StackPanel | Container for Android app selection (also reused as category/ownership picker) |
| **AndroidAppLabel** | Label | Label for app dropdown (relabeled at runtime for category/ownership) |
| **AndroidAppCombo** | ComboBox | Android app selection dropdown (also holds categories or Company/Personal) |
| **RowNotificationPanel** | Grid | Container for Send Custom Notification inputs (v1.2) |
| **NotificationTitleBox** | TextBox | Notification title input (v1.2) |
| **NotificationMessageBox** | TextBox | Multiline notification message input (v1.2) |
| **DeviceCountLabelAction** | TextBlock | Live "(N devices)" count for file/pasted input |
| **PastedDevicesTextBoxAction** | TextBox | Multiline paste-IDs input (alternative to file) |
| **CopyActionButton** | Button | Copy results to clipboard |

### 9.4 PowerShell Variable Mapping

All XAML elements with `x:Name` attributes are loaded into PowerShell variables with the `$WPF` prefix:

```powershell
# Example mappings
$WPFReportType              # ReportType ComboBox
$WPFlistview                # listview ListView
$WPFExportReportButton      # ExportReportButton Button
$WPFSingleDeviceInfoBox     # SingleDeviceInfoBox TextBox
$WPFGroupInputBoxReporting  # GroupInputBoxReporting TextBox
```

---

## 10. Data Flow Patterns

### 10.1 Hashtable Result Pattern

All report and action functions return data in a consistent hashtable format with array values:

```powershell
# Result hashtable structure
$results = @{
    "ColumnName1" = @()  # Array of values
    "ColumnName2" = @()
    "Status"      = @()
    "Message"     = @()
}

# Adding data
$results["ColumnName1"] += $value1
$results["ColumnName2"] += $value2
```

### 10.2 FillDataListView Pattern

```powershell
# Clear existing items
$ListView.Items.Clear()

# Create GridView with columns
$gridView = New-Object System.Windows.Controls.GridView
foreach ($header in $Headers) {
    $column = New-Object System.Windows.Controls.GridViewColumn
    $column.Header = $header
    $column.DisplayMemberBinding = New-Object System.Windows.Data.Binding($header)
    $gridView.Columns.Add($column)
}
$ListView.View = $gridView

# Add data rows
$rowCount = $Data[$Headers[0]].Count
for ($i = 0; $i -lt $rowCount; $i++) {
    $item = New-Object PSObject
    foreach ($header in $Headers) {
        $item | Add-Member -NotePropertyName $header -NotePropertyValue $Data[$header][$i]
    }
    $ListView.Items.Add($item)
}
```

### 10.3 Bulk Device Processing Pattern

```powershell
# Invoke-ForEachDevice pattern
$deviceList = Get-Content -Path $FilePath -Encoding UTF8 | 
    Where-Object { $_ -match '\S' }

$results = New-ResultsHashtable -Keys @("DeviceID", "DeviceName", "Status", "Message")

foreach ($deviceIdentifier in $deviceList) {
    $deviceInfo = Resolve-DeviceIdentifier -DeviceIdentifier $deviceIdentifier -DesiredID $DesiredID
    
    if ($deviceInfo.Found) {
        # Process device
        $result = & $ProcessingScript -DeviceInfo $deviceInfo
        Add-ResultToHashtable -Hashtable $results -Values $result
    }
    else {
        # Log not found
        Add-ResultToHashtable -Hashtable $results -Values @{
            DeviceID = $deviceIdentifier
            DeviceName = "N/A"
            Status = "Not Found"
            Message = "Device not found in Intune"
        }
    }
}

return $results
```

---

## 11. Error Handling

### 11.1 Error Handling Patterns

#### Connection Validation

```powershell
# Before any Graph operation
if (-not (Test-MGGraphConnection)) {
    Write-AppLog -Message "Operation attempted without connection" -Level "WARNING"
    [System.Windows.MessageBox]::Show("Not connected to Microsoft Graph...", ...)
    return
}
```

#### Permission Validation

```powershell
$permissionCheck = Test-GraphPermissions -OperationType "Report"
if (-not $permissionCheck.IsValid) {
    Write-AppLog -Message "Insufficient permissions" -Level "WARNING" -Details $permissionCheck.Message
    [System.Windows.MessageBox]::Show($permissionCheck.Message, ...)
    return
}
```

#### Input Validation

```powershell
# File path validation
if ([string]::IsNullOrWhiteSpace($filePath)) {
    [System.Windows.MessageBox]::Show("Please enter the file path.", ...)
    return
}

if (-not (Test-Path $filePath)) {
    [System.Windows.MessageBox]::Show("File not found: $filePath", ...)
    return
}

# GUID validation
if ($policyId -notmatch '^[{]?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}[}]?$') {
    [System.Windows.MessageBox]::Show("Invalid Policy ID format.", ...)
    return
}
```

#### Graph Request Error Handling

```powershell
try {
    $response = Invoke-GraphRequestWithRetry -Uri $uri -Method "GET"
}
catch {
    Write-AppLog -Message "Graph request failed" -Level "ERROR" -Details $_.Exception.Message
    $results["Status"] += "Error"
    $results["Message"] += $_.Exception.Message
}
```

### 11.2 Error Result Format

```powershell
function New-ErrorResult {
    param(
        [string]$Message,
        [string]$Status = "Error"
    )
    return @{
        Found = $false
        Status = $Status
        Message = $Message
    }
}
```

---

## 12. Logging System

### 12.1 Log Levels

| Level | Priority | Usage |
|-------|----------|-------|
| DEBUG | 0 | Detailed diagnostic information |
| INFO | 1 | General operational messages |
| USER | 1 | User-initiated actions (clicks, selections) |
| REPORT | 1 | Report execution events |
| ACTION | 1 | Action execution events |
| WARNING | 2 | Potential issues, validation failures |
| ERROR | 3 | Errors and exceptions |

Levels are also color-coded in the live **Activity Log** panel (ERROR red, WARNING amber, INFO blue, USER green).

### 12.2 Log File Format

```
================================================================================
                THE POWERFUL INTUNE BULK ACTIONS TOOL - APPLICATION LOG
================================================================================
Started: 2024-03-15 14:30:25
User: DOMAIN\username
Computer: WORKSTATION01
================================================================================

[2024-03-15 14:30:25] [INFO] The Powerful Intune Bulk Actions Tool starting
[2024-03-15 14:30:26] [DEBUG] Script directory: C:\Users\...\IntuneTool
[2024-03-15 14:30:27] [USER] User clicked Sign-In button

================================================================================
                    REPORT EXECUTION: Get Device Information
================================================================================

[2024-03-15 14:31:00] [USER] User clicked 'Generate Report' button
    | Report: Get Device Information, Single Device: True
[2024-03-15 14:31:01] [REPORT] Executing Get Device Information (Single)
    | Device: DEVICE001, ID Type: Device Name
[2024-03-15 14:31:03] [INFO] Device info retrieved successfully
    | Device Name: DEVICE001
```

### 12.3 Log Location

```powershell
# Default log location (dated subfolder per day)
C:\Temp\YYYYMMDD\IntuneTool_yyyyMMdd_HHmmss.log

# Example
C:\Temp\20260725\IntuneTool_20260725_143025.log

# Custom base directory: config.json next to script.ps1
#   { "ExportDirectory": "D:\\IntuneToolLogs" }
# Fallback when the base directory is not writable:
#   %TEMP%\IntuneTool\YYYYMMDD\
```

---

## 13. Files Created at Runtime

### 13.1 Log Files

| File Pattern | Location | Rotation |
|-------------|----------|----------|
| `IntuneTool_yyyyMMdd_HHmmss.log` | `C:\Temp\YYYYMMDD\` (configurable, `%TEMP%\IntuneTool` fallback) | Max 5 files per day folder, Max 10MB each |

### 13.2 Export Files

| Export Type | File Pattern | Location |
|------------|--------------|----------|
| Reports | `{ReportName}_yyyyMMdd_HHmmss.csv` | Export directory (configurable) |
| Actions | `{ActionName}_yyyyMMdd_HHmmss.csv` | Export directory (configurable) |
| TPM/Hardware | `TPMInfo_yyyyMMdd_HHmmss.csv` | Export directory |

### 13.3 Export Directory Configuration

```powershell
# Preferred: create config.json next to script.ps1
#   { "ExportDirectory": "D:\\IntuneToolExports" }
# (read at startup, applied via Set-ExportDirectory)

# Programmatic equivalent
Set-ExportDirectory -Path "C:\Exports"

# Get today's dated working directory (creates it if needed)
$exportPath = Get-ExportDirectory    # e.g. C:\Temp\20260725

# Default base: C:\Temp - falls back to %TEMP%\IntuneTool when not writable
```

---

## Appendix A: Report Type → Input Mode Mapping

| Report Type | Single/Multiple | Input Fields Required |
|------------|-----------------|----------------------|
| Get Device Information | Both | SingleDeviceInfoBox or MultipleDevicesInfoBox + ID Type |
| Get Bitlocker Status | Both | SingleDeviceInfoBox or MultipleDevicesInfoBox + ID Type |
| Get Device Last Logged-on User | Both | SingleDeviceInfoBox or MultipleDevicesInfoBox + ID Type |
| Get Detected Apps | Both | SingleDeviceInfoBox or MultipleDevicesInfoBox + ID Type |
| Get Group Assignments | Single Only | SingleDeviceInfoBox (Group) + SingleDeviceInfoChoice |
| Check Group Membership | Both | Device input + GroupInputBoxReporting |
| Get Autopilot Info | Multiple Only | MultipleDevicesInfoBox (file path) |
| Export TPM/Hardware Info | None | No input needed (all Windows devices) |
| Get User Details | Both | SingleDeviceInfoBox (UPN) or MultipleDevicesInfoBox |
| Get Policy Non-Compliance | Multiple Only | MultipleDevicesInfoBox + ID Type + PolicyIDBox |
| Get OS Distribution | Platform Only | PlatformSelectCombo (Windows/Android/iOS/macOS) |
| Get App Version Distribution | Platform + App | PlatformSelectCombo → AppSelectCombo (dynamic) |
| Get Group Members Intune Info | Group Only | GroupInputBoxReporting (group name or Object ID) |
| **Get Stale Devices** | Threshold Only | PolicyIDBox (days without check-in, default 30) |
| **Get Duplicate Device Records** | None | No input (fleet-wide scan) |
| **Get App Install Status** | Platform + App | PlatformSelectCombo → AppSelectCombo (dynamic) |
| **Get Low Disk Space Devices** | Threshold Only | PolicyIDBox (minimum free GB, default 10) |
| **Get Primary User Mismatch** | None | No input (fleet-wide scan) |

---

## Appendix B: Action Type → Input Mode Mapping

| Action Type | Single/Multiple | Input Fields Required |
|------------|-----------------|----------------------|
| Import Devices to Group | Both | Device input + GroupInputBox |
| Remove Devices from Group | Multiple Only | MultipleDevicesInfoBoxAction + ID Type + GroupInputBox |
| Empty Group Members | N/A | GroupInputBox only |
| Retire Devices | Multiple Only | MultipleDevicesInfoBoxAction + ID Type |
| Update Autopilot Group Tag | Multiple Only | MultipleDevicesInfoBoxAction (serials) + GroupTagBox |
| Bulk Rename Devices | Both | Scope selector + RenamePrefixBox + RenamePlatformCombo |
| Remove Android App | Both | Device input + AndroidAppCombo |
| Delete Device Records | Multiple Only | MultipleDevicesInfoBoxAction + ID Type + DeleteIntuneCheckbox / DeleteAutopilotCheckbox / DeleteEntraCheckbox + WhatIfModeCheckbox |
| **Sync / Restart / Rotate BitLocker Keys / Rotate LAPS Password / Remote Lock / Defender Quick+Full Scan** | Multiple Only | MultipleDevicesInfoBoxAction (or pasted IDs) + ID Type |
| **Set Primary User** | Multiple Only | Device input + ID Type + GroupTagBox (relabeled "New Primary User (UPN):") |
| **Set Device Category** | Multiple Only | Device input + ID Type + AndroidAppCombo (relabeled "Select Category:", loaded from Graph) |
| **Set Device Ownership** | Multiple Only | Device input + ID Type + AndroidAppCombo (relabeled "New Ownership:", Company/Personal) |
| **Send Custom Notification** | Multiple Only | Device input + ID Type + NotificationTitleBox + NotificationMessageBox |

---

## Appendix C: Graph API Endpoints Used

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/deviceManagement/managedDevices` | GET | List/query devices |
| `/deviceManagement/managedDevices/{id}` | GET | Single device info |
| `/deviceManagement/managedDevices/{id}?$select=hardwareInformation` | GET | Hardware/TPM info |
| `/deviceManagement/managedDevices/{id}/detectedApps` | GET | Detected/discovered apps on device |
| `/deviceManagement/managedDevices/{id}/retire` | POST | Retire device |
| `/groups` | GET | List/query groups |
| `/groups/{id}/members` | GET | Group membership |
| `/groups/{id}/members/$ref` | POST | Add member to group |
| `/groups/{id}/members/{memberId}/$ref` | DELETE | Remove member from group |
| `/users/{upn}` | GET | User details |
| `/devices/{id}` | GET | Entra device details (to get DeviceId for Intune lookup) |
| `/deviceManagement/windowsAutopilotDeviceIdentities` | GET | Autopilot devices |
| `/deviceManagement/deviceCompliancePolicies` | GET | Compliance policies |
| `/deviceManagement/deviceConfigurations` | GET | Device configurations |
| `/deviceManagement/configurationPolicies` | GET | Settings catalog policies |
| `/deviceManagement/reports/getDevicesWithoutCompliancePolicyReport` | POST | Non-compliance report |
| `/deviceAppManagement/mobileApps` | GET | List mobile apps (filtered by platform type) |
| `/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport` | POST | App install status report (App Version Distribution + Get App Install Status; response is an octet-stream attachment, downloaded via `-OutputFilePath`) |
| **`/deviceManagement/managedDevices/{id}/syncDevice`** | POST | Force device check-in |
| **`/deviceManagement/managedDevices/{id}/rebootNow`** | POST | Restart device |
| **`/deviceManagement/managedDevices/{id}/rotateBitLockerKeys`** | POST | Rotate BitLocker recovery keys |
| **`/deviceManagement/managedDevices/{id}/rotateLocalAdminPassword`** | POST | Rotate Windows LAPS password |
| **`/deviceManagement/managedDevices/{id}/remoteLock`** | POST | Remote lock device |
| **`/deviceManagement/managedDevices/{id}/windowsDefenderScan`** | POST | Defender scan (body: `{ quickScan: bool }`) |
| **`/deviceManagement/managedDevices/{id}/sendCustomNotificationToCompanyPortal`** | POST | Company Portal push notification |
| **`/deviceManagement/managedDevices('{id}')/users/$ref`** | POST | Set primary user |
| **`/deviceManagement/managedDevices('{id}')/deviceCategory/$ref`** | PUT | Assign device category |
| **`/deviceManagement/managedDevices/{id}`** | PATCH | Change ownership (`managedDeviceOwnerType`) |
| **`/deviceManagement/deviceCategories`** | GET | List device categories (picker) |
| **`/deviceAppManagement/mobileApps/{id}/deviceStatuses`** | — | NOT USED: rejects `$top` and returns empty for WinGet apps (replaced by the reports endpoint above) |