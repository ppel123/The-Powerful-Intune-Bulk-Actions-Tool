<#
================================================================================
    The Powerful Intune Bulk Actions Tool
================================================================================

REQUIRED MICROSOFT GRAPH PERMISSIONS:
--------------------------------------
This tool requires the following Microsoft Graph API permissions to function.
These permissions are automatically requested when you click "Sign-In".

Device Management (Read):
  - DeviceManagementManagedDevices.Read.All     (Read device information, encryption status, logged-on users)
  - DeviceManagementConfiguration.Read.All      (Read configuration policies, settings catalog, compliance, remediation scripts)
  - DeviceManagementApps.Read.All               (Read mobile apps, app protection policies, app configuration policies)
  - DeviceManagementScripts.Read.All            (Read PowerShell scripts and their assignments)
  - DeviceManagementServiceConfig.Read.All      (Read endpoint security policies, Autopilot info)

Group Management:
  - Group.Read.All                               (Read group information for group assignment searches)
  - Device.Read.All                              (Read device information for group import)

Actions (Write):
  - GroupMember.ReadWrite.All                    (Add/remove devices from groups)
  - DeviceManagementManagedDevices.ReadWrite.All (Retire devices, update Autopilot group tags)

NOTE: If you see "Forbidden" errors for PowerShell Scripts or Remediation Scripts,
you need to disconnect and sign in again to request the new permissions.

To manually connect with all required permissions, use:
  Connect-MgGraph -Scopes "DeviceManagementManagedDevices.Read.All", "DeviceManagementConfiguration.Read.All", "DeviceManagementApps.Read.All", "DeviceManagementScripts.Read.All", "Group.Read.All", "DeviceManagementServiceConfig.Read.All", "Device.Read.All", "GroupMember.ReadWrite.All", "DeviceManagementManagedDevices.ReadWrite.All"

================================================================================
#>

$scriptDir = $PSScriptRoot

#===========================================================================
# APP VERSION
#===========================================================================
$script:AppVersion = "1.1.0"

#===========================================================================
# ENSURE STA MODE (required by WPF)
#===========================================================================
# WPF can only run on a Single-Threaded Apartment (STA) thread. PowerShell 7 and
# the ISE are STA by default, but a plain Windows PowerShell console is MTA.
# Instead of failing, relaunch ourselves in the same console with -STA.
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    Write-Host "The WPF interface requires STA mode - relaunching PowerShell with -STA ..." -ForegroundColor Cyan
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell.exe' }
    & $psExe -STA -ExecutionPolicy Bypass -File $PSCommandPath
    exit $LASTEXITCODE
}

#===========================================================================
# CHECK & INSTALL REQUIRED MICROSOFT GRAPH MODULES
#===========================================================================
# Only the Microsoft.Graph submodules this tool actually uses are installed -
# NOT the full Microsoft.Graph meta-module (40+ modules) - keeping the first
# run to a couple of minutes instead of 10-20.
$requiredModules = @(
    "Microsoft.Graph.Authentication",               # Connect/Disconnect-MgGraph, Invoke-MgGraphRequest
    "Microsoft.Graph.DeviceManagement",             # Managed devices (get/remove/retire)
    "Microsoft.Graph.DeviceManagement.Enrollment",  # Autopilot device identities
    "Microsoft.Graph.Devices.CorporateManagement",  # Mobile apps (imported by background runspaces)
    "Microsoft.Graph.Groups",                       # Group membership add/remove
    "Microsoft.Graph.Users",                        # User lookups
    "Microsoft.Graph.Identity.DirectoryManagement"  # Entra ID device records
)

$missingModules = @($requiredModules | Where-Object { -not (Get-Module -ListAvailable -Name $_) })

if ($missingModules.Count -gt 0) {
    Write-Host "The following required modules are not installed:" -ForegroundColor Yellow
    $missingModules | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }

    # Determine install scope based on whether we are running as administrator
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator
    )

    if ($isAdmin) {
        $installScope = "AllUsers"
        Write-Host "Running as Administrator – modules will be installed for all users." -ForegroundColor Cyan
    } else {
        $installScope = "CurrentUser"
        Write-Host "Running without Administrator privileges – modules will be installed for the current user only." -ForegroundColor Cyan
    }

    foreach ($module in $missingModules) {
        try {
            Write-Host "Installing $module (Scope: $installScope) ..." -ForegroundColor Cyan
            Install-Module -Name $module -Scope $installScope -Force -AllowClobber -ErrorAction Stop
            Write-Host "$module installed successfully." -ForegroundColor Green
        }
        catch {
            Write-Host "ERROR: Failed to install $module – $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "Please install it manually:  Install-Module -Name $module -Scope $installScope" -ForegroundColor Red
            exit 1
        }
    }
}

Import-Module "$scriptDir\graphFunctions.psm1" -Force
Import-Module "$scriptDir\otherFunctions.psm1" -Force

#===========================================================================
# OPTIONAL CONFIGURATION FILE (config.json next to the script)
#===========================================================================
# Supported settings:
#   { "ExportDirectory": "D:\\IntuneToolLogs" }
# When not present (or invalid), logs/exports default to C:\Temp with an
# automatic fallback to the user's %TEMP% folder if C:\Temp is not writable.
$configPath = Join-Path $scriptDir "config.json"
if (Test-Path $configPath) {
    try {
        $appConfig = Get-Content -Path $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($appConfig.ExportDirectory -and -not [string]::IsNullOrWhiteSpace($appConfig.ExportDirectory)) {
            Set-ExportDirectory -Path $appConfig.ExportDirectory | Out-Null
        }
    }
    catch {
        Write-Host "Warning: Could not read config.json – using default export directory. $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Initialize logging
$script:AppLogPath = Initialize-AppLogging
Write-AppLog -Message "The Powerful Intune Bulk Actions Tool v$script:AppVersion starting" -Level "INFO"
Write-AppLog -Message "Script directory: $scriptDir" -Level "DEBUG"

#===========================================================================
# ASYNC UI HELPER FUNCTIONS
#===========================================================================
<#
================================================================================
    ANALYSIS: WHY THE UI FREEZES AND THE CHOSEN SOLUTION
================================================================================

PROBLEM:
--------
The UI freezes during long-running operations (like "Get Device Information") because
all code runs synchronously on the WPF UI thread. When a Graph API call takes several
seconds, the UI thread is blocked and cannot process user input or repaint the window.

SOLUTION:
---------
We use a RunspacePool + PowerShell.BeginInvoke pattern, which is the recommended
approach for WPF PowerShell applications:

1. A SHARED RunspacePool is created once at startup (reused for all background tasks)
2. When a button is clicked, we:
   - Show a busy indicator and disable controls (on UI thread)
   - Package the work into a PowerShell object with the background scriptblock
   - Call BeginInvoke() which starts execution on a pool thread (non-blocking)
   - Use a DispatcherTimer to poll for completion (keeps UI responsive)
3. When complete:
   - Retrieve results via EndInvoke()
   - Marshal back to UI thread via $Form.Dispatcher.Invoke()
   - Update UI controls with results, hide busy indicator, re-enable controls
4. Errors are caught, logged, and displayed gracefully

WHY THIS SCALES:
----------------
- The helper function `Invoke-AsyncOperation` is generic and reusable
- It accepts any ScriptBlock, arguments, and success/error/finally callbacks
- Each button handler only needs to define WHAT to do, not HOW to run it async
- The shared RunspacePool avoids creating new runspaces for each operation
- The pattern supports future enhancements like cancellation tokens

================================================================================
#>

# Create a shared RunspacePool for background operations (initialized once, reused)
$script:AsyncRunspacePool = $null

# Track active async operations for force-stop functionality
$script:ActiveAsyncContext = @{
    Reporting = $null
    Action    = $null
}

function Initialize-AsyncRunspacePool {
    <#
    .SYNOPSIS
        Initializes the shared RunspacePool for background operations.
    .DESCRIPTION
        Creates a RunspacePool with min/max threads. Call once after modules are loaded.
        The pool imports the same modules as the main script so Graph cmdlets work.
    #>
    param(
        [int]$MinRunspaces = 1,
        [int]$MaxRunspaces = 5
    )
    
    if ($null -ne $script:AsyncRunspacePool) {
        Write-AppLog -Message "RunspacePool already initialized" -Level "DEBUG"
        return
    }
    
    try {
        # Create initial session state with the same modules
        $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        
        # Import required modules into the runspace
        $modulesToImport = @(
            "$script:scriptDir\graphFunctions.psm1",
            "$script:scriptDir\otherFunctions.psm1",
            "Microsoft.Graph.Authentication",
            "Microsoft.Graph.DeviceManagement",
            "Microsoft.Graph.Devices.CorporateManagement"
        )
        
        foreach ($module in $modulesToImport) {
            $initialSessionState.ImportPSModule($module)
        }
        
        # Create the runspace pool
        $script:AsyncRunspacePool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
            $MinRunspaces, 
            $MaxRunspaces, 
            $initialSessionState, 
            $Host
        )
        $script:AsyncRunspacePool.ApartmentState = [System.Threading.ApartmentState]::STA
        $script:AsyncRunspacePool.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $script:AsyncRunspacePool.Open()
        
        Write-AppLog -Message "Async RunspacePool initialized (Min: $MinRunspaces, Max: $MaxRunspaces)" -Level "INFO"
    }
    catch {
        Write-AppLog -Message "Failed to initialize RunspacePool" -Level "ERROR" -Details $_.Exception.Message
        throw
    }
}

function Close-AsyncRunspacePool {
    <#
    .SYNOPSIS
        Closes and disposes the shared RunspacePool.
    .DESCRIPTION
        Call this when the application is closing to clean up resources.
    #>
    if ($null -ne $script:AsyncRunspacePool) {
        try {
            $script:AsyncRunspacePool.Close()
            $script:AsyncRunspacePool.Dispose()
            $script:AsyncRunspacePool = $null
            Write-AppLog -Message "Async RunspacePool closed" -Level "INFO"
        }
        catch {
            Write-AppLog -Message "Error closing RunspacePool" -Level "WARNING" -Details $_.Exception.Message
        }
    }
}

function Set-UiBusy {
    <#
    .SYNOPSIS
        Shows or hides the busy indicator and disables/enables UI controls.
    .PARAMETER IsBusy
        $true to show busy state, $false to restore normal state.
    .PARAMETER Message
        The status message to display (only used when IsBusy is $true).
    .PARAMETER Tab
        Which tab's overlay to use: "Reporting" or "Action". Defaults to "Reporting".
    .PARAMETER ControlsToDisable
        Optional array of control names to disable while busy.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [bool]$IsBusy,
        
        [string]$Message = "Working...",
        
        [ValidateSet("Reporting", "Action")]
        [string]$Tab = "Reporting",
        
        [string[]]$ControlsToDisable = @()
    )
    
    # Select the appropriate overlay controls based on tab
    $overlayName = if ($Tab -eq "Reporting") { "BusyOverlay" } else { "BusyOverlayAction" }
    $statusTextName = if ($Tab -eq "Reporting") { "BusyStatusText" } else { "BusyStatusTextAction" }
    
    # UI update scriptblock
    $uiAction = {
        $overlay = $Form.FindName($overlayName)
        $statusText = $Form.FindName($statusTextName)
        
        if ($IsBusy) {
            # Show busy overlay (force stop button is inside the overlay)
            if ($null -ne $statusText) { $statusText.Text = $Message }
            if ($null -ne $overlay) { $overlay.Visibility = "Visible" }
            
            # Disable specified controls
            foreach ($controlName in $ControlsToDisable) {
                $control = $Form.FindName($controlName)
                if ($null -ne $control) { $control.IsEnabled = $false }
            }
        }
        else {
            # Hide busy overlay (force stop button hides with it)
            if ($null -ne $overlay) { $overlay.Visibility = "Collapsed" }
            
            # Re-enable specified controls
            foreach ($controlName in $ControlsToDisable) {
                $control = $Form.FindName($controlName)
                if ($null -ne $control) { $control.IsEnabled = $true }
            }
        }
    }
    
    # Run directly if already on UI thread, otherwise marshal via Dispatcher
    if ($Form.Dispatcher.CheckAccess()) {
        & $uiAction
    } else {
        $Form.Dispatcher.Invoke([System.Windows.Threading.DispatcherPriority]::Normal, [System.Action]$uiAction)
    }
}

function Invoke-AsyncOperation {
    <#
    .SYNOPSIS
        Executes a scriptblock asynchronously in the background RunspacePool.
    .DESCRIPTION
        This is the main reusable helper for running any long-running operation
        without freezing the UI. It handles:
        - Running the work on a background thread
        - Polling for completion without blocking UI
        - Marshaling callbacks to the UI thread
        - Error handling and UI state restoration
    .PARAMETER ScriptBlock
        The code to run in the background. Should NOT touch any UI elements directly.
    .PARAMETER ArgumentList
        Optional hashtable of arguments to pass to the scriptblock.
        Access them inside the scriptblock via $args[0].VariableName
    .PARAMETER OnSuccess
        Scriptblock to execute on UI thread when operation completes successfully.
        Receives the result as $args[0].
    .PARAMETER OnError
        Scriptblock to execute on UI thread when operation fails.
        Receives the exception as $args[0].
    .PARAMETER OnFinally
        Scriptblock to execute on UI thread after success OR error (cleanup).
    .PARAMETER BusyMessage
        Message to show in the busy indicator.
    .PARAMETER Tab
        Which tab's overlay to use: "Reporting" or "Action".
    .PARAMETER ControlsToDisable
        Array of control names to disable while operation runs.
    .EXAMPLE
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            Get-IntuneDeviceInfo -IsSingleDevice $params.IsSingle -IDorFilePath $params.DeviceId -DesiredID $params.IdType
        } -ArgumentList @{ IsSingle = $true; DeviceId = "PC001"; IdType = "DeviceName" } `
          -OnSuccess { param($result) FillDataListView -ListView $WPFlistview -Headers $result.Keys -Data $result } `
          -OnError { param($err) [System.Windows.MessageBox]::Show("Error: $($err.Message)") } `
          -BusyMessage "Fetching device details..."
    #>
    param(
        [Parameter(Mandatory = $true)]
        [ScriptBlock]$ScriptBlock,
        
        [hashtable]$ArgumentList = @{},
        
        [ScriptBlock]$OnSuccess = {},
        
        [ScriptBlock]$OnError = {},
        
        [ScriptBlock]$OnFinally = {},
        
        [string]$BusyMessage = "Working...",
        
        [ValidateSet("Reporting", "Action")]
        [string]$Tab = "Reporting",
        
        [string[]]$ControlsToDisable = @("GenerateReportButton", "PerformActionButton")
    )
    
    # Ensure runspace pool is available
    if ($null -eq $script:AsyncRunspacePool -or $script:AsyncRunspacePool.RunspacePoolStateInfo.State -ne 'Opened') {
        Write-AppLog -Message "RunspacePool not available, initializing..." -Level "WARNING"
        Initialize-AsyncRunspacePool
    }
    
    # Show busy state
    Set-UiBusy -IsBusy $true -Message $BusyMessage -Tab $Tab -ControlsToDisable $ControlsToDisable
    Write-AppLog -Message "Starting async operation: $BusyMessage" -Level "DEBUG"
    
    try {
        # Create a new PowerShell instance attached to the pool
        $psInstance = [System.Management.Automation.PowerShell]::Create()
        $psInstance.RunspacePool = $script:AsyncRunspacePool
        
        # Add the scriptblock and arguments
        [void]$psInstance.AddScript($ScriptBlock)
        [void]$psInstance.AddArgument($ArgumentList)
        
        # Begin async execution
        $asyncHandle = $psInstance.BeginInvoke()
        
        # Create a DispatcherTimer to poll for completion (keeps UI responsive)
        $timer = New-Object System.Windows.Threading.DispatcherTimer
        $timer.Interval = [TimeSpan]::FromMilliseconds(100)
        
        # Store context for the timer's event handler
        $timerContext = @{
            PowerShell   = $psInstance
            AsyncHandle  = $asyncHandle
            OnSuccess    = $OnSuccess
            OnError      = $OnError
            OnFinally    = $OnFinally
            Tab          = $Tab
            Controls     = $ControlsToDisable
            Timer        = $timer
            ForceStopped = $false
            Completed    = $false
            StreamIndex  = @{ Information = 0; Warning = 0 }
        }
        
        # Store active context for force-stop access
        $tabKey = if ($Tab -eq "Reporting") { "Reporting" } else { "Action" }
        $script:ActiveAsyncContext[$tabKey] = $timerContext
        
        # Capture script-scope variable as local so .GetNewClosure() can access it
        # (Inside a closure, the script-scope variable refers to the closure module scope, not the outer script)
        $activeAsyncContext = $script:ActiveAsyncContext
        
        # Timer tick handler - checks if operation is complete
        $timer.Add_Tick({
            $ctx = $timerContext
            
            # Guard: skip if already completed or force-stopped
            if ($ctx.Completed -or $ctx.ForceStopped) { return }
            
            # Forward any new stream messages from the background runspace to the activity log.
            # Write-Host -> Streams.Information, Write-Warning -> Streams.Warning
            # This runs on every 100ms tick so messages appear in near real-time.
            try {
                $infoCount = $ctx.PowerShell.Streams.Information.Count
                if ($infoCount -gt $ctx.StreamIndex.Information) {
                    for ($i = $ctx.StreamIndex.Information; $i -lt $infoCount; $i++) {
                        $msgData = $ctx.PowerShell.Streams.Information[$i].MessageData
                        $msgText = if ($null -ne $msgData) { $msgData.ToString().Trim() } else { "" }
                        if ($msgText) { Write-AppLog -Message $msgText -Level "INFO" }
                    }
                    # Advance past the snapshot AND any extra entries Write-AppLog->Write-Host injected back into the stream
                    $ctx.StreamIndex.Information = $ctx.PowerShell.Streams.Information.Count
                }
                $warnCount = $ctx.PowerShell.Streams.Warning.Count
                if ($warnCount -gt $ctx.StreamIndex.Warning) {
                    for ($i = $ctx.StreamIndex.Warning; $i -lt $warnCount; $i++) {
                        $warnMsg = $ctx.PowerShell.Streams.Warning[$i].Message
                        if ($warnMsg) { Write-AppLog -Message $warnMsg -Level "WARNING" }
                    }
                    $ctx.StreamIndex.Warning = $ctx.PowerShell.Streams.Warning.Count
                }
            }
            catch { <# silently ignore stream-read errors to keep the timer alive #> }
            
            if ($ctx.AsyncHandle.IsCompleted) {
                # Stop the timer and mark as completed to prevent re-entry
                $ctx.Timer.Stop()
                $ctx.Completed = $true
                
                try {
                    # Get results - EndInvoke returns a PSDataCollection, extract actual result
                    $rawResult = $ctx.PowerShell.EndInvoke($ctx.AsyncHandle)
                    
                    # Extract the actual result from the PSDataCollection
                    # If there's one item, use it directly; if multiple, convert to array
                    $result = $null
                    if ($null -ne $rawResult -and $rawResult.Count -gt 0) {
                        if ($rawResult.Count -eq 1) {
                            $result = $rawResult[0]
                        } else {
                            $result = @($rawResult)
                        }
                    }
                    
                    # Check for errors in the PowerShell streams
                    # IMPORTANT: If we got a valid result, treat as success even if there were
                    # non-fatal errors in the stream (e.g., individual device "Not Found" errors
                    # during batch processing). The functions handle these gracefully and include
                    # them as result rows. Only treat as failure if there's NO result.
                    if ($null -ne $result) {
                        # We have a valid result - log any stream errors as warnings but proceed with success
                        if ($ctx.PowerShell.Streams.Error.Count -gt 0) {
                            Write-AppLog -Message "Async operation completed with $($ctx.PowerShell.Streams.Error.Count) handled error(s) in stream" -Level "WARNING" -Details "First error: $($ctx.PowerShell.Streams.Error[0].ToString())"
                        }
                        
                        # Check if result itself indicates an error (single-result error pattern)
                        if ($result -is [hashtable] -and $result.ContainsKey("Error") -and $result.Error -and -not $result.ContainsKey("DeviceName")) {
                            Write-AppLog -Message "Async operation returned error in result" -Level "ERROR" -Details $result.Error
                            & $ctx.OnError ([System.Exception]::new($result.Error))
                        }
                        else {
                            Write-AppLog -Message "Async operation completed successfully" -Level "DEBUG"
                            & $ctx.OnSuccess $result
                        }
                    }
                    elseif ($ctx.PowerShell.HadErrors -and $ctx.PowerShell.Streams.Error.Count -gt 0) {
                        # No result AND had errors - this is a real failure
                        $errorMessage = "Unknown async error"
                        $errorException = $null
                        
                        # Safely get error details
                        $errorRecord = $ctx.PowerShell.Streams.Error[0]
                        if ($null -ne $errorRecord) {
                            $errorMessage = $errorRecord.ToString()
                            $errorException = $errorRecord.Exception
                        }
                        
                        Write-AppLog -Message "Async operation error" -Level "ERROR" -Details $errorMessage
                        
                        # Execute error callback with a proper exception
                        $safeException = if ($null -ne $errorException) { $errorException } else { [System.Exception]::new($errorMessage) }
                        & $ctx.OnError $safeException
                    }
                    else {
                        # No result, no errors - unexpected, treat as empty success
                        Write-AppLog -Message "Async operation completed with null result" -Level "WARNING"
                        & $ctx.OnSuccess $null
                    }
                }
                catch {
                    Write-AppLog -Message "Error in async completion" -Level "ERROR" -Details $_.Exception.Message
                    
                    # Execute error callback
                    & $ctx.OnError $_.Exception
                }
                finally {
                    # Always execute finally callback and restore UI
                    try { & $ctx.OnFinally } catch { Write-AppLog -Message "Error in OnFinally callback" -Level "ERROR" -Details $_.Exception.Message }
                    try { Set-UiBusy -IsBusy $false -Tab $ctx.Tab -ControlsToDisable $ctx.Controls } catch { Write-AppLog -Message "Error in Set-UiBusy restore" -Level "ERROR" -Details $_.Exception.Message }
                    
                    # Cleanup
                    try { $ctx.PowerShell.Dispose() } catch { Write-AppLog -Message "Error in PowerShell.Dispose" -Level "ERROR" -Details $_.Exception.Message }
                    
                    # Clear active context (use the captured local variable, not the script-scoped one which doesn't resolve inside .GetNewClosure())
                    $ctxTabKey = if ($ctx.Tab -eq "Reporting") { "Reporting" } else { "Action" }
                    $activeAsyncContext[$ctxTabKey] = $null
                    
                    Write-AppLog -Message "Async cleanup completed for $($ctx.Tab) tab" -Level "DEBUG"
                }
            }
        }.GetNewClosure())
        
        # Start the timer
        $timer.Start()
    }
    catch {
        Write-AppLog -Message "Failed to start async operation" -Level "ERROR" -Details $_.Exception.Message
        Set-UiBusy -IsBusy $false -Tab $Tab -ControlsToDisable $ControlsToDisable
        & $OnError $_.Exception
        & $OnFinally
    }
}

#===========================================================================
# END ASYNC UI HELPER FUNCTIONS
#===========================================================================

# Load XAML from external file
$xamlPath = Join-Path $scriptDir "MainWindow.xaml"
if (-not (Test-Path $xamlPath)) {
    Write-Error "XAML file not found: $xamlPath"
    exit 1
}
$inputXML = Get-Content -Path $xamlPath -Raw -Encoding UTF8
Write-AppLog -Message "Loaded XAML from: $xamlPath" -Level "DEBUG"

<#
.SYNOPSIS
    Escapes and transforms XAML content for PowerShell WPF loading.
.DESCRIPTION
    Removes designer-specific attributes and updates image paths for runtime use.
.PARAMETER InputString
    The raw XAML string to process.
#>
function ConvertTo-EscapedXaml {
    param(
        [string]$InputString
    )

    # Define patterns to match
    $patterns = @(
        'TextChanged="TextBox_TextChanged"',
        'Click="SignInButton_Click"',
        'Source="/MainImage.png"',
        'd:ItemsSource="{d:SampleData ItemCount=5}"',
        'Margin="22,127,0,0"',
        'Margin="240,165,0,0"',
        'Margin="468,165,0,0"',
        'Margin="82,384,0,0"'
    )

    # Define replacements
    $imagePath = "$scriptDir\MainImage.png"
    $replacements = @(
        '',
        '',
        "Source=`"$imagePath`"",
        '',
        'Margin="22,93,0,0"',
        'Margin="240,97,0,0"',
        'Margin="468,97,0,0"',
        'Margin="48,345,0,0"'
    )

    # Loop through each pattern and replace in the input string
    for ($i = 0; $i -lt $patterns.Length; $i++) {
        $InputString = $InputString -replace $patterns[$i], $replacements[$i]
    }

    return $InputString
}


# --- Function to Get Devices for Rename ---
$inputXML = ConvertTo-EscapedXaml -InputString $inputXML
 
$inputXML = $inputXML -replace 'mc:Ignorable="d"','' -replace "x:Class",'Class' -replace '^<Win.*', '<Window'
[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[void][System.Reflection.Assembly]::LoadWithPartialName('Microsoft.VisualBasic')
[xml]$XAML = $inputXML
#Read XAML
 
$reader=(New-Object System.Xml.XmlNodeReader $xaml)
try{
    $Form=[Windows.Markup.XamlReader]::Load( $reader )
}
catch{
    Write-Warning "Unable to parse XML, with error: $($Error[0])`n Ensure that there are NO SelectionChanged or TextChanged properties in your textboxes (PowerShell cannot process them)"
    throw
}

# Show the app version in the window title
$Form.Title = "The Powerful Intune Bulk Actions Tool  -  v$script:AppVersion"
 
#===========================================================================
# Load XAML Objects In PowerShell
#===========================================================================
  
# Create namespace manager for XPath queries
$nsmgr = New-Object System.Xml.XmlNamespaceManager($xaml.NameTable)
$nsmgr.AddNamespace("x", "http://schemas.microsoft.com/winfx/2006/xaml")

$xaml.SelectNodes("//*[@x:Name]", $nsmgr) | ForEach-Object {
    $name = $_.GetAttribute("Name", "http://schemas.microsoft.com/winfx/2006/xaml")
    try {
        $control = $Form.FindName($name)
        if ($null -ne $control) {
            Set-Variable -Name "WPF$name" -Value $control -Scope Script -Force
        } else {
            Write-Host "Control not found: $name" -ForegroundColor Red
        }
    }
    catch {
        Write-Host "Error loading $name : $_" -ForegroundColor Red
    }
}

#===========================================================================
# Activity Log Panel – tails the app log file and shows entries in the UI
#===========================================================================

$script:LogTailOffset = 0

function Add-ActivityLogEntry {
    param([string]$Line)
    # Match lines written by Write-AppLog: [yyyy-MM-dd HH:mm:ss.fff] [LEVEL] Message
    if ($Line -notmatch '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+)\] \[([A-Z]+)\] (.+)$') {
        return
    }
    $row = [pscustomobject]@{
        Time    = $Matches[1]
        Level   = $Matches[2]
        Message = $Matches[3].Trim()
    }
    try {
        $WPFLvActivityLog.Items.Add($row) | Out-Null
        if ($WPFLvActivityLog.Items.Count -gt 500) {
            $WPFLvActivityLog.Items.RemoveAt(0)
        }
        $WPFLvActivityLog.ScrollIntoView($row)
    } catch {}
}

$script:LogTailTimer = New-Object System.Windows.Threading.DispatcherTimer
$script:LogTailTimer.Interval = [TimeSpan]::FromMilliseconds(500)
$script:LogTailTimer.Add_Tick({
    if (-not $script:AppLogPath -or -not (Test-Path $script:AppLogPath)) { return }
    try {
        $stream = [System.IO.File]::Open(
            $script:AppLogPath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite
        )
        $stream.Seek($script:LogTailOffset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $reader = New-Object System.IO.StreamReader($stream)
        while (-not $reader.EndOfStream) {
            $line = $reader.ReadLine()
            if ($line) { Add-ActivityLogEntry -Line $line }
        }
        $script:LogTailOffset = $stream.Position
        $reader.Dispose()
        $stream.Dispose()
    } catch {}
})
$script:LogTailTimer.Start()

#===========================================================================
# File Selection Helpers (WPF)
#===========================================================================

# Persist last-used directory across selections
if (-not $script:LastOpenDir -or [string]::IsNullOrWhiteSpace($script:LastOpenDir)) {
    $script:LastOpenDir = [Environment]::GetFolderPath('Desktop')
}

function Show-FilePicker {
    param(
        [Parameter(Mandatory=$true)]
        [object]$TextBox,
        [string]$Filter = "Text files (*.txt)|*.txt|CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    )

    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.InitialDirectory = $script:LastOpenDir
    $dlg.Filter = $Filter
    $dlg.Multiselect = $false
    $dlg.CheckFileExists = $true
    $dlg.RestoreDirectory = $true

    $result = $dlg.ShowDialog()
    if ($result -eq $true -and (Test-Path -Path $dlg.FileName)) {
        if ($TextBox -is [System.Windows.Controls.TextBox]) {
            # Clear first so TextChanged always fires even when the same path is re-selected,
            # ensuring the device count is re-calculated from the current file contents.
            $TextBox.Text = ""
            $TextBox.Text = $dlg.FileName
        }
        $script:LastOpenDir = Split-Path -Path $dlg.FileName -Parent
    }
}

function Add-SelectFileButton {
    param(
        [Parameter(Mandatory=$true)]
        [string]$ParentGridName,
        [Parameter(Mandatory=$true)]
        [string]$TextBoxName,
        [Parameter(Mandatory=$true)]
        [string]$ButtonName,
        [string]$Filter = "Text files (*.txt)|*.txt|CSV files (*.csv)|*.csv|All files (*.*)|*.*"
    )

    $grid = $Form.FindName($ParentGridName)
    $tb = $Form.FindName($TextBoxName)
    if ($null -eq $grid -or $null -eq $tb) { return }

    # Reserve right-side space for the button in the same grid column
    $tb.Margin = New-Object System.Windows.Thickness(0,0,110,0)

    $btn = New-Object System.Windows.Controls.Button
    $btn.Name = $ButtonName
    $btn.Content = "Select file..."
    $btn.Height = 30
    $btn.Width = 100
    $btn.HorizontalAlignment = "Right"
    $btn.VerticalAlignment = "Center"
    # Store references for use in the click handler to avoid scope issues
    $btn.Tag = [pscustomobject]@{ TextBox = $tb; Filter = $Filter }

    [System.Windows.Controls.Grid]::SetColumn($btn, [System.Windows.Controls.Grid]::GetColumn($tb))
    $grid.Children.Add($btn) | Out-Null

    $btn.Add_Click({
        param($btnSender, $e)
        try {
            $cfg = $btnSender.Tag
            if ($cfg -and $cfg.TextBox) {
                Show-FilePicker $cfg.TextBox $cfg.Filter
            }
        }
        catch {
            Write-AppLog -Message "File picker error" -Level "ERROR" -Details "$($_.Exception.Message)"
        }
    })
}

# Wire buttons for common file path textboxes (Reporting & Actions)
Add-SelectFileButton -ParentGridName "Row3ReportingPanel" -TextBoxName "MultipleDevicesInfoBox" -ButtonName "BrowseMultipleDevicesReportingBtn"
Add-SelectFileButton -ParentGridName "Row3ActionPanel" -TextBoxName "MultipleDevicesInfoBoxAction" -ButtonName "BrowseMultipleDevicesActionBtn"

#===========================================================================
# Use this space to add code to the various form elements in your GUI
#===========================================================================

#################################################### MAIN TAB ####################################################
Write-AppLogSection -Title "APPLICATION INITIALIZED"

# Initialize the async RunspacePool for background operations
Initialize-AsyncRunspacePool

# Helper function to update the last sync time display
function Update-LastSyncTime {
    $syncTime = Get-Date -Format "MMM dd, yyyy h:mm tt"
    $WPFLastSyncTimeLabel.Text = "Connected: $syncTime"
}

# Helper function to count devices in a file or pasted text and update the label.
function Update-DeviceCount {
    param(
        [string]$FilePath,
        [System.Windows.Controls.TextBlock]$Label,
        [string]$PastedText = ""
    )
    
    $fileError = $null
    
    # File path takes priority over pasted text when the file exists and is readable
    if (-not [string]::IsNullOrWhiteSpace($FilePath)) {
        if (Test-Path -Path $FilePath -PathType Leaf) {
            try {
                $lines = Get-Content -Path $FilePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $count = @($lines).Count
                $Label.Text = "($($count) devices)"
                return
            }
            catch {
                $fileError = "(invalid file)"
            }
        }
        else {
            $fileError = "(file not found)"
        }
    }
    
    # Fall back to pasted text count when available
    if (-not [string]::IsNullOrWhiteSpace($PastedText)) {
        $lines = $PastedText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $count = @($lines).Count
        $Label.Text = "($($count) pasted)"
        return
    }
    
    # If no pasted text is available but there was a file-related error, show that
    if ($fileError) {
        $Label.Text = $fileError
        return
    }
    
    $Label.Text = ""
}

# Resolves device input to a file path for passing to Graph API functions.
# If a valid file path is provided, it is returned as-is (file takes priority over pasted text).
# If pasted text is provided, the IDs are written to a temporary file whose path is returned.
# Temp files are named "IntuneTool_paste_<guid>.txt" and are cleaned up by the caller at the
# start of the next button-click handler via $script:LastReportTempFile / $script:LastActionTempFile.
# Returns a hashtable: @{ Source = "File"|"Paste"|"None"; Path = <string|$null>; TempCreated = <bool> }
function Resolve-MultipleDeviceInput {
    param(
        [string]$FilePath,
        [string]$PastedText
    )

    # File takes priority
    if (-not [string]::IsNullOrWhiteSpace($FilePath) -and (Test-Path -Path $FilePath -PathType Leaf)) {
        Write-AppLog -Message "Device input resolved from file" -Level "DEBUG" -Details "Path: $FilePath"
        return @{ Source = "File"; Path = $FilePath; TempCreated = $false }
    }

    # Fall back to pasted text
    if (-not [string]::IsNullOrWhiteSpace($PastedText)) {
        $lines = $PastedText -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() }
        if (@($lines).Count -gt 0) {
            $tempPath = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "IntuneTool_paste_$([System.Guid]::NewGuid().ToString('N')).txt")
            $lines | Set-Content -Path $tempPath -Encoding UTF8
            Write-AppLog -Message "Device input resolved from pasted text" -Level "DEBUG" -Details "Lines: $(@($lines).Count), TempFile: $tempPath"
            return @{ Source = "Paste"; Path = $tempPath; TempCreated = $true }
        }
    }

    return @{ Source = "None"; Path = $null; TempCreated = $false }
}

# Helper function to copy ListView data to clipboard
function Copy-ListViewToClipboard {
    param(
        [System.Windows.Controls.ListView]$ListView,
        [string]$DataType = "Results"
    )
    
    # Check Items collection (used by FillDataListView)
    if ($null -eq $ListView.Items -or $ListView.Items.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No data to copy.", "Copy to Clipboard", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    $items = @($ListView.Items)
    if ($items.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No data to copy.", "Copy to Clipboard", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    # Get all properties from the first item
    $properties = $items[0] | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name
    
    if ($null -eq $properties -or $properties.Count -eq 0) {
        [System.Windows.MessageBox]::Show("No data to copy.", "Copy to Clipboard", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        return
    }
    
    # Build tab-separated text with headers
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine(($properties -join "`t"))
    
    foreach ($item in $items) {
        $values = foreach ($prop in $properties) {
            $item.$prop
        }
        [void]$sb.AppendLine(($values -join "`t"))
    }
    
    [System.Windows.Clipboard]::SetText($sb.ToString())
    Write-AppLog -Message "Copied $($items.Count) $DataType rows to clipboard" -Level "INFO"
    [System.Windows.MessageBox]::Show("$($items.Count) rows copied to clipboard!", "Copy to Clipboard", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
}

# Set button tooltips programmatically (PowerShell WPF sometimes doesn't parse XAML ToolTip attributes)
$WPFSignInButtonCopy.ToolTip = "Connect to Microsoft Graph with your credentials to access Intune data"
$WPFDisconnectBtn.ToolTip = "Disconnect from Microsoft Graph and clear session"
$WPFGenerateReportButton.ToolTip = "Execute the selected report with the specified parameters"
$WPFPerformActionButton.ToolTip = "Execute the selected action with the specified parameters"
$WPFExportReportButton.ToolTip = "Export results to a CSV file for use in Excel"
$WPFExportActionButton.ToolTip = "Export results to a CSV file for use in Excel"
$WPFCopyReportButton.ToolTip = "Copy results to clipboard as tab-separated text"
$WPFCopyActionButton.ToolTip = "Copy results to clipboard as tab-separated text"

$initialConnectionResult = Test-MGGraphConnection
if ($initialConnectionResult){
    Write-AppLog -Message "Existing Graph connection detected" -Level "INFO"
    UnhideItems -ItemNames @("ConnectedPanel")
    HideItems -ItemNames @("NotConnectedLabel")
    Update-LastSyncTime
}
else {
    Write-AppLog -Message "No existing Graph connection" -Level "INFO"
}

$WPFSignInButtonCopy.Add_Click({ 
    Write-AppLog -Message "User clicked Sign-In button" -Level "USER"
    $connectionResult = Connect-ToMGGraph
    if ($connectionResult -eq $true){
        Write-AppLog -Message "Successfully connected to Microsoft Graph" -Level "INFO"
        $context = Get-MgContext
        Write-AppLog -Message "Connected as: $($context.Account)" -Level "INFO" -Details "TenantId: $($context.TenantId)"
        UnhideItems -ItemNames @("ConnectedPanel")
        HideItems -ItemNames @("NotConnectedLabel")
        Update-LastSyncTime
    }
    else{
        Write-AppLog -Message "Failed to connect to Microsoft Graph" -Level "ERROR"
        UnhideItems -ItemNames @("NotConnectedLabel")
        HideItems -ItemNames @("ConnectedPanel")
    }
})

if ($null -ne (Get-Variable -Name "WPFDisconnectBtn" -ErrorAction SilentlyContinue)) {
    $WPFDisconnectBtn.Add_Click({ 
        Write-AppLog -Message "User clicked Disconnect button" -Level "USER"
        Disconnect-MgGraph
        Write-AppLog -Message "Disconnected from Microsoft Graph" -Level "INFO"
        UnhideItems -ItemNames @("NotConnectedLabel")
        HideItems -ItemNames @("ConnectedPanel")
        $WPFLastSyncTimeLabel.Text = ""
    })
} else {
    Write-Host "DisconnectBtn control not found - disconnect functionality unavailable" -ForegroundColor Yellow
}

# Device count update handlers for file path textboxes
$WPFMultipleDevicesInfoBox.Add_TextChanged({
    Update-DeviceCount -FilePath $WPFMultipleDevicesInfoBox.Text -Label $WPFDeviceCountLabel -PastedText $WPFPastedDevicesTextBox.Text
})

$WPFMultipleDevicesInfoBoxAction.Add_TextChanged({
    Update-DeviceCount -FilePath $WPFMultipleDevicesInfoBoxAction.Text -Label $WPFDeviceCountLabelAction -PastedText $WPFPastedDevicesTextBoxAction.Text
})

# Device count update handlers for paste textboxes
$WPFPastedDevicesTextBox.Add_LostFocus({
    Update-DeviceCount -FilePath $WPFMultipleDevicesInfoBox.Text -Label $WPFDeviceCountLabel -PastedText $WPFPastedDevicesTextBox.Text
})

$WPFPastedDevicesTextBoxAction.Add_LostFocus({
    Update-DeviceCount -FilePath $WPFMultipleDevicesInfoBoxAction.Text -Label $WPFDeviceCountLabelAction -PastedText $WPFPastedDevicesTextBoxAction.Text
})

# Copy to Clipboard button handlers
$WPFCopyReportButton.Add_Click({
    Write-AppLog -Message "User clicked Copy Report button" -Level "USER"
    Copy-ListViewToClipboard -ListView $WPFlistview -DataType "report"
})

$WPFCopyActionButton.Add_Click({
    Write-AppLog -Message "User clicked Copy Action button" -Level "USER"
    Copy-ListViewToClipboard -ListView $WPFlistviewAction -DataType "action"
})

#################################################### REPORTING TAB #################################################### 

$script:IsSingleDevice = $null
$script:IsSingleDeviceAction = $null

# Populate the dropdown choices for available reports in the Reporting tab
# Initialize an array with report types (format: "Name - short description")
$reportTypes = @(
    "Get Device Information - Device details & specs",
    "Get Bitlocker Status - Encryption & keys",
    "Get Device Last Logged-on User - Last user login",
    "Get Detected Apps - Installed apps list",
    "Get Group Assignments - Group memberships",
    "Check Group Membership - Verify device in group",
    "Get Autopilot Info - Autopilot registration",
    "Export TPM/Hardware Info for All Devices - Export all TPM/BIOS",
    "Get User Details - User account info",
    "Get Policy Non-Compliance Settings - Non-compliant settings",
    "Get OS Distribution - OS version counts",
    "Get App Version Distribution - App version counts",
    "Get Group Members Intune Info - Group devices info"
)

# Iterate through each report type and add it as an item in the 'ReportType' dropdown
foreach ($choice in $reportTypes) {
    # Add the current choice to the 'ReportType' ComboBox, casting the operation to [void] to suppress the return value
    [void]$Form.FindName("ReportType").Items.Add($choice)
}

# Define descriptions for each report type (using script scope for access in event handlers)
# Keys match the dropdown items which include short descriptions after " - "
$script:reportDescriptions = @{
    "Get Device Information - Device details & specs" = "Retrieves detailed device info including hardware specs, OS version, compliance status, and enrollment details from Intune."
    "Get Bitlocker Status - Encryption & keys" = "Fetches the BitLocker encryption status and recovery key for the specified device(s)."
    "Get Device Last Logged-on User - Last user login" = "Shows the last user who logged into the device(s), useful for tracking device ownership."
    "Get Detected Apps - Installed apps list" = "Retrieves all detected/discovered applications installed on the specified device(s). Supports single or multiple devices."
    "Get Group Assignments - Group memberships" = "Lists all Entra ID groups that a specific group is assigned to (nested group memberships)."
    "Check Group Membership - Verify device in group" = "Verifies whether the specified device(s) are members of a specific Entra ID group."
    "Get Autopilot Info - Autopilot registration" = "Retrieves Windows Autopilot registration details including group tag, profile status, and serial number."
    "Export TPM/Hardware Info for All Devices - Export all TPM/BIOS" = "Exports TPM version, BIOS version, and hardware details for ALL managed devices to CSV. This may take several minutes."
    "Get User Details - User account info" = "Retrieves Entra ID user information including display name, job title, department, and account status."
    "Get Policy Non-Compliance Settings - Non-compliant settings" = "Shows which specific settings in a policy are causing non-compliance for the specified devices."
    "Get OS Distribution - OS version counts" = "Shows the distribution of OS build versions for corporate devices. Select a platform to see counts of each build number."
    "Get App Version Distribution - App version counts" = "Shows installed version distribution for a specific app across devices. Select platform, then app to see which versions are deployed. Uses POST request (read-only)."
    "Get Group Members Intune Info - Group devices info" = "Retrieves all device members of a group and shows their Intune information including compliance, OS version, last sync, and enrollment status."
}

# Attach an event handler to the SelectionChanged event of the 'ReportType' dropdown
$Form.FindName("ReportType").Add_SelectionChanged({
    # Call the Unhide-Label function when a selection is made, passing in the names of UI elements to be made visible
    $selectedReport = $Form.FindName("ReportType").SelectedItem
    Write-AppLog -Message "User selected report type: '$selectedReport'" -Level "USER"
    
    # Hide export button when switching report types (will be shown when report is generated)
    HideItems -ItemNames @("ExportReportButton", "CopyReportButton")
    
    # Clear all input fields and results when switching report types
    $Form.FindName("SingleDeviceInfoBox").Text = ""
    $Form.FindName("MultipleDevicesInfoBox").Text = ""
    $WPFPastedDevicesTextBox.Text = ""
    $WPFDeviceCountLabel.Text = ""
    $Form.FindName("SingleDeviceInfoChoice").SelectedIndex = -1
    $Form.FindName("MultipleDevicesInfoChoice").SelectedIndex = -1
    $Form.FindName("SingleOrMultipleDevices").SelectedIndex = -1
    $WPFPolicyIDBox.Text = ""
    $WPFGroupInputBoxReporting.Text = ""
    $WPFResultsTextBox.Text = ""
    $WPFlistview.Items.Clear()
    
    # Update and show description for selected report
    $descriptionLabel = $Form.FindName("ReportDescriptionLabel")
    if ($selectedReport -and $script:reportDescriptions.ContainsKey($selectedReport)) {
        $descriptionLabel.Text = $script:reportDescriptions[$selectedReport]
        $descriptionLabel.Visibility = "Visible"
    } else {
        $descriptionLabel.Text = ""
        $descriptionLabel.Visibility = "Collapsed"
    }
    
    if ($selectedReport -like "Get Group Assignments*") {
        # For group assignments, we only need single group input (Row2)
        UnhideItems -ItemNames @("Row2ReportingPanel")
        HideItems -ItemNames @("Row1ReportingPanel", "Row3ReportingPanel", "Row4ReportingPanel", "Row5ReportingPanel", "Row6ReportingPanel", "Row7ReportingPanel", "listview", "ResultsTextBox", "PostRequestNote")
        
        # Update label text for group
        $Form.FindName("SingleDevice").Content = "Group (enter info):"
        
        # Clear and populate with group ID types
        [void]$Form.FindName("SingleDeviceInfoChoice").Items.Clear()
        $groupIDTypes = @("Group Object ID", "Group Name")
        foreach ($choice in $groupIDTypes) {
            [void]$Form.FindName("SingleDeviceInfoChoice").Items.Add($choice)
        }
    } elseif ($selectedReport -like "Check Group Membership*") {
        # For group membership check, show device selection (Row1)
        UnhideItems -ItemNames @("Row1ReportingPanel")
        HideItems -ItemNames @("Row2ReportingPanel", "Row3ReportingPanel", "Row4ReportingPanel", "Row5ReportingPanel", "Row6ReportingPanel", "Row7ReportingPanel", "listview", "ResultsTextBox", "PostRequestNote")
        
        # Reset label text
        $Form.FindName("SingleDevice").Content = "Single device (enter info):"
    } elseif ($selectedReport -like "Get Autopilot Info*") {
        # For autopilot info, only support multiple devices (Row3)
        UnhideItems -ItemNames @("Row3ReportingPanel")
        HideItems -ItemNames @("Row1ReportingPanel", "Row2ReportingPanel", "Row4ReportingPanel", "Row5ReportingPanel", "Row6ReportingPanel", "Row7ReportingPanel", "listview", "ResultsTextBox", "PostRequestNote")
        
        # Set to multiple devices mode
        $script:IsSingleDevice = $false
        
        # Ensure the ID type dropdown is visible (may have been collapsed by a previous report)
        $Form.FindName("MultipleDevicesInfoChoice").Visibility = "Visible"
        
        # Clear and populate with only Entra ID Device ID option
        [void]$Form.FindName("MultipleDevicesInfoChoice").Items.Clear()
        [void]$Form.FindName("MultipleDevicesInfoChoice").Items.Add("EntraID ID")
        $Form.FindName("MultipleDevicesInfoChoice").SelectedIndex = 0
        
        # Update label to clarify
        $Form.FindName("MultipleDevices").Content = "Multiple devices:`r`n(select a file or`r`npaste Entra IDs`r`nbelow)"
    } elseif ($selectedReport -like "Export TPM/Hardware Info*") {
        # No additional inputs for this report - hide all row panels
        HideItems -ItemNames @("Row1ReportingPanel", "Row2ReportingPanel", "Row3ReportingPanel", "Row4ReportingPanel", "Row5ReportingPanel", "Row6ReportingPanel", "Row7ReportingPanel", "listview", "ResultsTextBox", "PostRequestNote")
        $script:IsSingleDevice = $null
    } elseif ($selectedReport -like "Get User Details*") {
        # For user details, show single/multiple selection (Row1)
        UnhideItems -ItemNames @("Row1ReportingPanel")
        HideItems -ItemNames @("Row2ReportingPanel", "Row3ReportingPanel", "Row4ReportingPanel", "Row5ReportingPanel", "Row6ReportingPanel", "Row7ReportingPanel", "listview", "ResultsTextBox", "PostRequestNote")
        
        # Update labels for user context
        $Form.FindName("SelectSingleOrMultiple").Content = "Report for single user or multiple users?"
        $Form.FindName("SingleDevice").Content = "User (UPN or Object ID):"
        $Form.FindName("MultipleDevices").Content = "Multiple users:`r`n(select a file or`r`npaste UPNs`r`nbelow)"
        
        # Update dropdown with user options instead of device options
        [void]$Form.FindName("SingleOrMultipleDevices").Items.Clear()
        [void]$Form.FindName("SingleOrMultipleDevices").Items.Add("Single User")
        [void]$Form.FindName("SingleOrMultipleDevices").Items.Add("Multiple Users")
    } elseif ($selectedReport -like "Get Policy Non-Compliance*") {
        # For policy non-compliance, show multiple devices (Row3) and policy ID (Row5)
        UnhideItems -ItemNames @("Row3ReportingPanel", "Row5ReportingPanel", "PostRequestNote")
        HideItems -ItemNames @("Row1ReportingPanel", "Row2ReportingPanel", "Row4ReportingPanel", "Row6ReportingPanel", "Row7ReportingPanel", "listview", "ResultsTextBox")
        
        # Set to multiple devices mode
        $script:IsSingleDevice = $false
        
        # Ensure the ID type dropdown is visible (may have been collapsed by a previous report)
        $Form.FindName("MultipleDevicesInfoChoice").Visibility = "Visible"
        
        # Clear and populate with device ID types
        [void]$Form.FindName("MultipleDevicesInfoChoice").Items.Clear()
        $policyDeviceIDTypes = @("Intune ID", "EntraID ID", "Serial Number")
        foreach ($choice in $policyDeviceIDTypes) {
            [void]$Form.FindName("MultipleDevicesInfoChoice").Items.Add($choice)
        }
        
        # Update label
        $Form.FindName("MultipleDevices").Content = "Multiple devices:`r`n(select a file or`r`npaste IDs`r`nbelow)"
        
        # Reset labels for device context
        $Form.FindName("SelectSingleOrMultiple").Content = "Report for single device or multiple devices?"
        $Form.FindName("SingleDevice").Content = "Single device (enter info):"
    } elseif ($selectedReport -like "Get OS Distribution*") {
        # For OS distribution, show only platform selection (Row6)
        UnhideItems -ItemNames @("Row6ReportingPanel")
        HideItems -ItemNames @("Row1ReportingPanel", "Row2ReportingPanel", "Row3ReportingPanel", "Row4ReportingPanel", "Row5ReportingPanel", "Row7ReportingPanel", "listview", "ResultsTextBox", "PostRequestNote")
        $script:IsSingleDevice = $null
        
        # Reset platform combo selection
        $Form.FindName("PlatformSelectCombo").SelectedIndex = -1
    } elseif ($selectedReport -like "Get App Version Distribution*") {
        # For app version distribution, show platform selection (Row6) and app selection (Row7)
        # Also show PostRequestNote since this report uses a POST request
        UnhideItems -ItemNames @("Row6ReportingPanel", "PostRequestNote")
        HideItems -ItemNames @("Row1ReportingPanel", "Row2ReportingPanel", "Row3ReportingPanel", "Row4ReportingPanel", "Row5ReportingPanel", "Row7ReportingPanel", "listview", "ResultsTextBox")
        $script:IsSingleDevice = $null
        
        # Reset selections
        $Form.FindName("PlatformSelectCombo").SelectedIndex = -1
        $Form.FindName("AppSelectCombo").Items.Clear()
    } elseif ($selectedReport -like "Get Group Members Intune Info*") {
        # For group members report, show group input (Row4)
        UnhideItems -ItemNames @("Row4ReportingPanel")
        HideItems -ItemNames @("Row1ReportingPanel", "Row2ReportingPanel", "Row3ReportingPanel", "Row5ReportingPanel", "Row6ReportingPanel", "Row7ReportingPanel", "listview", "ResultsTextBox", "PostRequestNote")
        $script:IsSingleDevice = $null
        
        # Clear the group input box
        $Form.FindName("GroupInputBoxReporting").Text = ""
    } else {
        # For device reports (Get Device Information, Get Bitlocker Status, Get Device Last Logged-on User)
        # Show single/multiple selection (Row1)
        UnhideItems -ItemNames @("Row1ReportingPanel")
        HideItems -ItemNames @("Row2ReportingPanel", "Row3ReportingPanel", "Row4ReportingPanel", "Row5ReportingPanel", "Row6ReportingPanel", "Row7ReportingPanel", "listview", "ResultsTextBox", "PostRequestNote")
        
        # Reset label text
        $Form.FindName("SingleDevice").Content = "Single device (enter info):"
        $Form.FindName("SelectSingleOrMultiple").Content = "Report for single device or multiple devices?"
        
        # Reset dropdown to device options
        [void]$Form.FindName("SingleOrMultipleDevices").Items.Clear()
        [void]$Form.FindName("SingleOrMultipleDevices").Items.Add("Single Device")
        [void]$Form.FindName("SingleOrMultipleDevices").Items.Add("Multiple Devices")
    }
})

# Event handler for PlatformSelectCombo - populates apps when platform changes (for App Version Distribution report)
$Form.FindName("PlatformSelectCombo").Add_SelectionChanged({
    $selectedReport = $Form.FindName("ReportType").SelectedItem
    
    # Only populate apps if we're on the App Version Distribution report AND a valid selection was made
    if ($selectedReport -like "Get App Version Distribution*") {
        $platformCombo = $Form.FindName("PlatformSelectCombo")
        $selectedItem = $platformCombo.SelectedItem
        
        # Check if selection is valid (not null and not index -1)
        if ($null -eq $selectedItem -or $platformCombo.SelectedIndex -lt 0) {
            # Selection was cleared (e.g., when switching reports), do nothing
            return
        }
        
        # Get the platform text from the selected ComboBoxItem
        $selectedPlatform = $null
        if ($selectedItem -is [System.Windows.Controls.ComboBoxItem]) {
            $selectedPlatform = $selectedItem.Content
        } elseif ($selectedItem -is [string]) {
            $selectedPlatform = $selectedItem
        } else {
            $selectedPlatform = $platformCombo.Text
        }
        
        if (-not [string]::IsNullOrWhiteSpace($selectedPlatform)) {
            
            # Show Row7 for app selection
            UnhideItems -ItemNames @("Row7ReportingPanel")
            
            # Clear and show loading state
            $appCombo = $Form.FindName("AppSelectCombo")
            $appCombo.Items.Clear()
            $loadingItem = New-Object System.Windows.Controls.ComboBoxItem
            $loadingItem.Content = "Loading apps..."
            $loadingItem.IsEnabled = $false
            [void]$appCombo.Items.Add($loadingItem)
            $appCombo.SelectedIndex = 0
            
            # Fetch apps asynchronously
            $script:AsyncFetchAppsParams = @{ Platform = $selectedPlatform }
            
            Invoke-AsyncOperation -ScriptBlock {
                param($params)
                
                $result = @{ 
                    Apps = @()
                    Platform = $params.Platform
                    Error = $null
                }
                
                try {
                    # Verify Graph SDK is available in the runspace
                    $cmd = Get-Command Invoke-MgGraphRequest -ErrorAction SilentlyContinue
                    if (-not $cmd) {
                        $result.Error = "Invoke-MgGraphRequest cmdlet not available in runspace"
                        return $result
                    }
                    
                    # Verify Graph context is active
                    $ctx = Get-MgContext
                    if (-not $ctx) {
                        $result.Error = "No Graph connection in runspace"
                        return $result
                    }
                    
                    # Fetch all apps for the platform
                    $platform = $params.Platform
                    $platformAppTypes = switch ($platform) {
                        "Windows" { @("win32", "windows", "office", "winGet") }
                        "Android" { @("android") }
                        "iOS" { @("ios") }
                        "macOS" { @("macOS") }
                        default { @() }
                    }
                    
                    # Fetch all apps (don't select @odata.type, it's included by default)
                    $allApps = @()
                    $uri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps?`$select=id,displayName&`$top=999"
                    $response = Invoke-MgGraphRequest -Method GET -Uri $uri
                    $allApps += $response.value
                    
                    while ($response.'@odata.nextLink') {
                        $response = Invoke-MgGraphRequest -Method GET -Uri $response.'@odata.nextLink'
                        $allApps += $response.value
                    }
                    
                    # Filter by platform
                    $filteredApps = @()
                    foreach ($app in $allApps) {
                        $appType = $app.'@odata.type'
                        if (-not $appType) { continue }
                        foreach ($prefix in $platformAppTypes) {
                            if ($appType -match $prefix) {
                                $filteredApps += @{
                                    id = $app.id
                                    displayName = $app.displayName
                                    displayVersion = $app.displayVersion
                                }
                                break
                            }
                        }
                    }
                    
                    $result.Apps = @($filteredApps | Sort-Object { $_.displayName })
                }
                catch {
                    $result.Error = $_.Exception.Message
                }
                
                return $result
            } -ArgumentList $script:AsyncFetchAppsParams `
              -BusyMessage "Fetching $selectedPlatform apps..." -Tab "Reporting" `
              -ControlsToDisable @() `
              -OnSuccess {
                param($returnedData)
                
                $appCombo = $Form.FindName("AppSelectCombo")
                $appCombo.Items.Clear()
                
                if ($returnedData.Error) {
                    Write-AppLog -Message "Failed to fetch apps" -Level "ERROR" -Details $returnedData.Error
                    $errorItem = New-Object System.Windows.Controls.ComboBoxItem
                    $errorItem.Content = "Error loading apps"
                    $errorItem.IsEnabled = $false
                    [void]$appCombo.Items.Add($errorItem)
                    return
                }
                
                $apps = $returnedData.Apps
                
                if ($null -eq $apps -or $apps.Count -eq 0) {
                    $noAppsItem = New-Object System.Windows.Controls.ComboBoxItem
                    $noAppsItem.Content = "No apps found"
                    $noAppsItem.IsEnabled = $false
                    [void]$appCombo.Items.Add($noAppsItem)
                    return
                }
                
                Write-AppLog -Message "Apps fetched successfully" -Level "INFO" -Details "Platform: $($returnedData.Platform), Count: $($apps.Count)"
                
                foreach ($app in $apps) {
                    $item = New-Object System.Windows.Controls.ComboBoxItem
                    $displayText = $app.displayName
                    if ($app.displayVersion) {
                        $displayText += " (v$($app.displayVersion))"
                    }
                    # Add short app ID for identification
                    $shortId = $app.id.Substring(0, 8)
                    $displayText += " - $shortId"
                    $item.Content = $displayText
                    $item.Tag = $app.id
                    [void]$appCombo.Items.Add($item)
                }
            } -OnError {
                param($exception)
                Write-AppLog -Message "Failed to fetch apps" -Level "ERROR" -Details $exception.Message
                $appCombo = $Form.FindName("AppSelectCombo")
                $appCombo.Items.Clear()
                $errorItem = New-Object System.Windows.Controls.ComboBoxItem
                $errorItem.Content = "Error: $($exception.Message)"
                $errorItem.IsEnabled = $false
                [void]$appCombo.Items.Add($errorItem)
            }
        }
    }
})

# Populate the dropdown choices for selecting between a single device or multiple devices in the Reporting tab
# Initialize an array with the options 'Single Device' and 'Multiple Devices'
$multipleOrSingleDevice = @("Single Device", "Multiple Devices")

# Iterate through the device options and add each one as an item in the 'SingleOrMultipleDevices' dropdown
foreach ($choice in $multipleOrSingleDevice) {
    # Add the current choice to the 'SingleOrMultipleDevices' ComboBox
    [void]$Form.FindName("SingleOrMultipleDevices").Items.Add($choice)
}

# Store a reference to the 'SingleOrMultipleDevices' ComboBox in a variable for later use
$multipleOrSingleDeviceSelection = $Form.FindName("SingleOrMultipleDevices")

# Initialize an array with different types of device identifiers
$DeviceIDs = @("EntraID ID", "Intune ID", "Device Name", "Serial Number")

# For Actions tab, we need a subset without Intune ID (can't add to groups with Intune ID)
$DeviceIDsForActions = @("EntraID ID", "Device Name", "Serial Number")

# Attach an event handler to the SelectionChanged event of the 'SingleOrMultipleDevices' dropdown
$multipleOrSingleDeviceSelection.Add_SelectionChanged({
    # Store the currently selected item in the ComboBox into a variable
    $selectedItem = $multipleOrSingleDeviceSelection.SelectedItem
    # Check if the selected item is 'Single Device' or 'Single User'
    if ($selectedItem -eq "Single Device" -or $selectedItem -eq "Single User") {
        Write-AppLog -Message "User selected $selectedItem mode for reporting" -Level "USER"
        $script:IsSingleDevice = $true
        # Show Row2 (Single Device) and hide Row3 (Multiple Devices)
        UnhideItems -ItemNames @("Row2ReportingPanel")
        HideItems -ItemNames @("Row3ReportingPanel")
        
        # Check if this is for User Details report
        $Form.FindName("SingleDeviceInfoChoice").Visibility = "Visible"
        [void]$Form.FindName("SingleDeviceInfoChoice").Items.Clear()
        
        if ($Form.FindName("ReportType").SelectedItem -like "Get User Details*") {
            # Add user ID types
            $userIDTypes = @("User Principal Name (UPN)", "Object ID")
            foreach ($choice in $userIDTypes) {
                [void]$Form.FindName("SingleDeviceInfoChoice").Items.Add($choice)
            }
            $Form.FindName("SingleDeviceInfoChoice").SelectedIndex = 0
        } else {
            # Iterate through each device ID type and add it as a choice for the single device selection
            foreach ($choice in $DeviceIDs) {
                [void]$Form.FindName("SingleDeviceInfoChoice").Items.Add($choice)
            }
        }
        # Show group input (Row4) if Check Group Membership is selected
        if ($Form.FindName("ReportType").SelectedItem -like "Check Group Membership*") {
            UnhideItems -ItemNames @("Row4ReportingPanel")
        }
    } elseif ($selectedItem -eq "Multiple Devices" -or $selectedItem -eq "Multiple Users") {
        Write-AppLog -Message "User selected $selectedItem mode for reporting" -Level "USER"
        $script:IsSingleDevice = $false
        # Show Row3 (Multiple Devices) and hide Row2 (Single Device)
        UnhideItems -ItemNames @("Row3ReportingPanel")
        HideItems -ItemNames @("Row2ReportingPanel")
        
        # Check if this is for User Details report (hide dropdown for direct UPN input)
        if ($Form.FindName("ReportType").SelectedItem -like "Get User Details*") {
            $Form.FindName("MultipleDevicesInfoChoice").Visibility = "Collapsed"
        } else {
            $Form.FindName("MultipleDevicesInfoChoice").Visibility = "Visible"
            # Clear Combo Box
            [void]$Form.FindName("MultipleDevicesInfoChoice").Items.Clear()
            # Iterate through each device ID type and add it as a choice for the multiple devices selection
            foreach ($choice in $DeviceIDs) {
                [void]$Form.FindName("MultipleDevicesInfoChoice").Items.Add($choice)
            }
        }
        # Show group input (Row4) if Check Group Membership is selected
        if ($Form.FindName("ReportType").SelectedItem -like "Check Group Membership*") {
            UnhideItems -ItemNames @("Row4ReportingPanel")
        }
    }
})

#################################################### ACTIONS TAB #################################################### 

# Populate the dropdown choices for available actions in the Actions tab
# Initialize an array with action types (format: "Name - short description")
$actionTypes = @(
    "Import Devices to Group - Add to group",
    "Remove Devices from Group - Remove from group",
    "Empty Group Members - Clear all members",
    "Retire Devices - Remove company data",
    "Update Autopilot Group Tag - Change group tag",
    "Bulk Rename Devices - Rename by serial",
    "Remove Android App - Intune remote action",
    "Delete Device Records - Delete from Intune"
)

foreach ($choice in $actionTypes) {
    [void]$Form.FindName("ActionType").Items.Add($choice)
}

# Define descriptions for each action type (using script scope for access in event handlers)
# Keys match the dropdown items which include short descriptions after " - "
$script:actionDescriptions = @{
    "Import Devices to Group - Add to group" = "Adds one or multiple devices to an Entra ID group. Useful for dynamic deployment targeting or policy assignments."
    "Remove Devices from Group - Remove from group" = "Removes devices from an Entra ID group. Provide a file with device identifiers and the target group."
    "Empty Group Members - Clear all members" = "Removes ALL members from the specified Entra ID group. Use with extreme caution!"
    "Retire Devices - Remove company data" = "Initiates the Intune retire action on devices, removing company data while keeping personal data. Use with caution!"
    "Update Autopilot Group Tag - Change group tag" = "Updates the Autopilot group tag for devices using their serial numbers. Changes take effect on next Autopilot reset."
    "Bulk Rename Devices - Rename by serial" = "Renames devices based on a prefix and 8 last digit of serial number suffix. Choose 'All Corporate' or a File list."
    "Remove Android App - Intune remote action" = "Sends an Intune remote action to remove the selected Android app from target devices. The app can be reinstalled manually or via policy after removal."
    "Delete Device Records - Delete from Intune" = "DESTRUCTIVE: Permanently deletes device records from Intune, Autopilot, and Entra ID. This action CANNOT be undone!"
}

# Attach an event handler to the SelectionChanged event of the 'ActionType' dropdown
$Form.FindName("ActionType").Add_SelectionChanged({
    $selectedAction = $Form.FindName("ActionType").SelectedItem
    Write-AppLog -Message "User selected action type: '$selectedAction'" -Level "USER"
    
    # Hide export button when switching action types (will be shown when action is completed)
    HideItems -ItemNames @("ExportActionButton", "CopyActionButton")
    
    # Clear all input fields and results when switching action types
    $Form.FindName("SingleDeviceInfoBoxAction").Text = ""
    $Form.FindName("MultipleDevicesInfoBoxAction").Text = ""
    $WPFPastedDevicesTextBoxAction.Text = ""
    $WPFDeviceCountLabelAction.Text = ""
    $Form.FindName("SingleDeviceInfoChoiceAction").SelectedIndex = -1
    $Form.FindName("MultipleDevicesInfoChoiceAction").SelectedIndex = -1
    $Form.FindName("SingleOrMultipleDevicesAction").SelectedIndex = -1
    $WPFGroupInputBox.Text = ""
    $WPFGroupTagBox.Text = ""
    $WPFlistviewAction.Items.Clear()
    
    # Update and show description for selected action
    $actionDescriptionLabel = $Form.FindName("ActionDescriptionLabel")
    if ($selectedAction -and $script:actionDescriptions.ContainsKey($selectedAction)) {
        $actionDescriptionLabel.Text = $script:actionDescriptions[$selectedAction]
        $actionDescriptionLabel.Visibility = "Visible"
    } else {
        $actionDescriptionLabel.Text = ""
        $actionDescriptionLabel.Visibility = "Collapsed"
    }
    
    if ($selectedAction -like "Import Devices to Group*") {
        # Show single/multiple selection for devices (Row1: single/multiple dropdown)
        UnhideItems -ItemNames @("Row1ActionPanel")
        HideItems -ItemNames @("Row2ActionPanel", "Row3ActionPanel", "Row4ActionPanel", "Row5ActionPanel", "listviewAction", "RenameOptionsPanel", "RowAppSelectionPanel", "RowDeleteOptionsPanel")
        
        # Reset label
        $Form.FindName("MultipleDevicesAction").Content = "Multiple devices:`r`n(select a file or`r`npaste IDs`r`nbelow)"
    } elseif ($selectedAction -like "Remove Devices from Group*") {
        # Show file input and group input (Row3: multiple devices, Row4: group input)
        UnhideItems -ItemNames @("Row3ActionPanel", "Row4ActionPanel")
        HideItems -ItemNames @("Row1ActionPanel", "Row2ActionPanel", "Row5ActionPanel", "listviewAction", "RenameOptionsPanel", "RowAppSelectionPanel", "RowDeleteOptionsPanel")
        
        # Set flag for multiple devices
        $script:IsSingleDeviceAction = $false
        
        # Clear and populate with device ID types for remove
        [void]$Form.FindName("MultipleDevicesInfoChoiceAction").Items.Clear()
        $removeDeviceIDTypes = @("Serial Number", "EntraID ID", "Device Name")
        foreach ($choice in $removeDeviceIDTypes) {
            [void]$Form.FindName("MultipleDevicesInfoChoiceAction").Items.Add($choice)
        }
        
        # Update label to clarify
        $Form.FindName("MultipleDevicesAction").Content = "Multiple devices:`r`n(select a file or`r`npaste IDs`r`nbelow)"
    } elseif ($selectedAction -like "Empty Group Members*") {
        # Show only group input (Row4)
        UnhideItems -ItemNames @("Row4ActionPanel")
        HideItems -ItemNames @("Row1ActionPanel", "Row2ActionPanel", "Row3ActionPanel", "Row5ActionPanel", "listviewAction", "RenameOptionsPanel", "RowAppSelectionPanel", "RowDeleteOptionsPanel")
    } elseif ($selectedAction -like "Retire Devices*") {
        # Show file input for retire devices (Row3: multiple devices only)
        UnhideItems -ItemNames @("Row3ActionPanel")
        HideItems -ItemNames @("Row1ActionPanel", "Row2ActionPanel", "Row4ActionPanel", "Row5ActionPanel", "listviewAction", "RenameOptionsPanel", "RowAppSelectionPanel", "RowDeleteOptionsPanel")
        
        # Set flag for multiple devices
        $script:IsSingleDeviceAction = $false
        
        # Clear and populate with device ID types for retire
        [void]$Form.FindName("MultipleDevicesInfoChoiceAction").Items.Clear()
        $retireDeviceIDTypes = @("Intune ID", "EntraID ID", "Serial Number")
        foreach ($choice in $retireDeviceIDTypes) {
            [void]$Form.FindName("MultipleDevicesInfoChoiceAction").Items.Add($choice)
        }
        
        # Update label to clarify
        $Form.FindName("MultipleDevicesAction").Content = "Multiple devices:`r`n(select a file or`r`npaste IDs`r`nbelow)"
    } elseif ($selectedAction -like "Update Autopilot Group Tag*") {
        # Show file input and group tag input (Row3: multiple devices, Row5: group tag)
        UnhideItems -ItemNames @("Row3ActionPanel", "Row5ActionPanel")
        HideItems -ItemNames @("Row1ActionPanel", "Row2ActionPanel", "Row4ActionPanel", "listviewAction", "RenameOptionsPanel", "RowAppSelectionPanel", "RowDeleteOptionsPanel")
        
        # Set flag for multiple devices
        $script:IsSingleDeviceAction = $false
        
        # Update label to clarify (serial numbers only for Autopilot)
        $Form.FindName("MultipleDevicesAction").Content = "Serial Numbers:`r`n(select a file or`r`npaste serials`r`nbelow)"
    } elseif ($selectedAction -like "Bulk Rename Devices*") {
        # Show scope (Row1) and rename options
        UnhideItems -ItemNames @("Row1ActionPanel", "RenameOptionsPanel")
        HideItems -ItemNames @("Row2ActionPanel", "Row3ActionPanel", "Row4ActionPanel", "Row5ActionPanel", "listviewAction", "RowAppSelectionPanel", "RowDeleteOptionsPanel")
        
        # Customize Single/Multiple Combo for this action
        $combo = $Form.FindName("SingleOrMultipleDevicesAction")
        [void]$combo.Items.Clear()
        [void]$combo.Items.Add("All Corporate Devices")
        [void]$combo.Items.Add("Specific Devices from File")
        
        # Default choices
        $Form.FindName("MultipleDevicesAction").Content = "Device IDs:`r`n(select a file or`r`npaste serials`r`nbelow)"
    }
    elseif ($selectedAction -like "Remove Android App*") {
        # New action: supports single or multiple devices by Serial/Device Name/EntraID
        UnhideItems -ItemNames @("Row1ActionPanel", "RowAppSelectionPanel")
        HideItems -ItemNames @("Row2ActionPanel", "Row3ActionPanel", "Row4ActionPanel", "Row5ActionPanel", "listviewAction", "RenameOptionsPanel", "RowDeleteOptionsPanel")
        # Populate the Android app dropdown
        Initialize-AndroidAppSelection -ComboName "AndroidAppCombo"
    }
    elseif ($selectedAction -like "Delete Device Records*") {
        # DESTRUCTIVE ACTION: Delete device records from Intune, Autopilot, and Entra ID
        # Show file input (Row3: multiple devices only) and checkboxes panel for deletion options
        UnhideItems -ItemNames @("Row3ActionPanel", "RowDeleteOptionsPanel")
        HideItems -ItemNames @("Row1ActionPanel", "Row2ActionPanel", "Row4ActionPanel", "Row5ActionPanel", "listviewAction", "RenameOptionsPanel", "RowAppSelectionPanel")
        
        # Set flag for multiple devices only (no single device mode for destructive actions)
        $script:IsSingleDeviceAction = $false
        
        # Clear and populate with device ID types for delete
        [void]$Form.FindName("MultipleDevicesInfoChoiceAction").Items.Clear()
        $deleteDeviceIDTypes = @("Serial Number", "Device Name", "Intune ID")
        foreach ($choice in $deleteDeviceIDTypes) {
            [void]$Form.FindName("MultipleDevicesInfoChoiceAction").Items.Add($choice)
        }
        
        # Update label to clarify
        $Form.FindName("MultipleDevicesAction").Content = "Multiple devices:`r`n(select a file or`r`npaste IDs`r`nbelow)"
        
        # Initialize checkboxes to checked (default: delete all)
        $Form.FindName("DeleteIntuneCheckbox").IsChecked = $true
        $Form.FindName("DeleteAutopilotCheckbox").IsChecked = $true
        $Form.FindName("DeleteEntraCheckbox").IsChecked = $true
        $Form.FindName("WhatIfModeCheckbox").IsChecked = $true  # Default to WhatIf ON for safety
    }
    
    # Reset standard combo items if NOT Rename
    if ($selectedAction -notlike "Bulk Rename Devices*") {
         $combo = $Form.FindName("SingleOrMultipleDevicesAction")
         if (-not $combo.Items.Contains("Single Device")) {
             [void]$combo.Items.Clear()
             [void]$combo.Items.Add("Single Device")
             [void]$combo.Items.Add("Multiple Devices")
         }
    }
})

# Populate the dropdown for selecting between single or multiple devices in Actions tab
$multipleOrSingleDeviceAction = @("Single Device", "Multiple Devices")

foreach ($choice in $multipleOrSingleDeviceAction) {
    [void]$Form.FindName("SingleOrMultipleDevicesAction").Items.Add($choice)
}

# Store reference to the Actions ComboBox
$multipleOrSingleDeviceSelectionAction = $Form.FindName("SingleOrMultipleDevicesAction")

# Attach event handler for single/multiple selection in Actions tab
$multipleOrSingleDeviceSelectionAction.Add_SelectionChanged({
    $selectedItem = $multipleOrSingleDeviceSelectionAction.SelectedItem
    $selectedAction = $Form.FindName("ActionType").SelectedItem

    if ($selectedAction -like "Bulk Rename Devices*") {
        if ($selectedItem -eq "All Corporate Devices") {
            # "All" Mode
            $script:IsSingleDeviceAction = $true 
            UnhideItems -ItemNames @("RenameOptionsPanel")
            HideItems -ItemNames @("Row2ActionPanel", "Row3ActionPanel", "Row4ActionPanel")
            $Form.FindName("RenamePlatformLabel").Visibility = "Visible"
            $Form.FindName("RenamePlatformCombo").Visibility = "Visible"
            
        } elseif ($selectedItem -eq "Specific Devices from File") {
            # "File" Mode
            $script:IsSingleDeviceAction = $false
            UnhideItems -ItemNames @("RenameOptionsPanel", "Row3ActionPanel")
            HideItems -ItemNames @("Row2ActionPanel", "Row4ActionPanel")
            $Form.FindName("RenamePlatformLabel").Visibility = "Collapsed"
            $Form.FindName("RenamePlatformCombo").Visibility = "Collapsed"
            
             [void]$Form.FindName("MultipleDevicesInfoChoiceAction").Items.Clear()
             [void]$Form.FindName("MultipleDevicesInfoChoiceAction").Items.Add("Serial Number")
             $Form.FindName("MultipleDevicesInfoChoiceAction").SelectedIndex = 0
        }
    } else {
        # Row4 (group input) is only needed for group-related actions, not for Remove Android App
        $showGroupInput = -not ($selectedAction -like "Remove Android App*")

        if ($selectedItem -eq "Single Device") {
            $script:IsSingleDeviceAction = $true
            # Show Row2 (single device input) and optionally Row4 (group input)
            $unhideList = @("Row2ActionPanel")
            if ($showGroupInput) { $unhideList += "Row4ActionPanel" }
            UnhideItems -ItemNames $unhideList
            HideItems -ItemNames @("Row3ActionPanel", "RenameOptionsPanel")
            
            # Clear and populate device ID types (excluding Intune ID for group operations)
            [void]$Form.FindName("SingleDeviceInfoChoiceAction").Items.Clear()
            foreach ($choice in $DeviceIDsForActions) {
                [void]$Form.FindName("SingleDeviceInfoChoiceAction").Items.Add($choice)
            }
        } elseif ($selectedItem -eq "Multiple Devices") {
            $script:IsSingleDeviceAction = $false
            # Show Row3 (multiple devices input) and optionally Row4 (group input)
            $unhideList = @("Row3ActionPanel")
            if ($showGroupInput) { $unhideList += "Row4ActionPanel" }
            UnhideItems -ItemNames $unhideList
            HideItems -ItemNames @("Row2ActionPanel", "RenameOptionsPanel")
            
            # Clear and populate device ID types (excluding Intune ID for group operations)
            [void]$Form.FindName("MultipleDevicesInfoChoiceAction").Items.Clear()
            foreach ($choice in $DeviceIDsForActions) {
                [void]$Form.FindName("MultipleDevicesInfoChoiceAction").Items.Add($choice)
            }
        }
    }
})
#===========================================================================
# Action: Remove Android App (Intune remote action)
#===========================================================================

function Initialize-AndroidAppSelection {
    param([string]$ComboName)
    $combo = $Form.FindName($ComboName)
    if ($null -eq $combo) { return }
    [void]$combo.Items.Clear()

    Invoke-AsyncOperation -ScriptBlock {
        param($params)
        $resp = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps" -ErrorAction Stop
        $values = if ($resp.ContainsKey('value')) { $resp['value'] } else { $resp }
        $apps = @()
        foreach ($app in $values) {
            $odata = if ($app -is [System.Collections.IDictionary]) { $app['@odata.type'] } else { $app.'@odata.type' }
            $name  = if ($app -is [System.Collections.IDictionary]) { $app['displayName'] } else { $app.displayName }
            $id    = if ($app -is [System.Collections.IDictionary]) { $app['id'] } else { $app.id }
            if ($id -and $name -and ($odata -match 'android')) {
                $apps += [PSCustomObject]@{ Name = $name; Id = $id }
            }
        }
        return @{ Apps = $apps; ComboName = $params.ComboName }
    } -ArgumentList @{ ComboName = $ComboName } `
      -BusyMessage "Loading Android apps..." -Tab "Action" `
      -ControlsToDisable @("ActionType", "PerformActionButton") `
      -OnSuccess {
        param($result)
        $c = $Form.FindName($result.ComboName)
        if ($null -eq $c) { return }
        [void]$c.Items.Clear()
        foreach ($app in $result.Apps) {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $app.Name
            $item.Tag = $app.Id
            [void]$c.Items.Add($item)
        }
    } -OnError {
        param($exception)
        Write-AppLog -Message "Failed to populate Android apps" -Level "ERROR" -Details "$($exception.Message)"
    }
}


# Add tab change handler to clear descriptions when switching tabs
$mainTabControl = $Form.FindName("MainTabControl")
if ($mainTabControl) {
    $mainTabControl.Add_SelectionChanged({
        param($tabSender, $e)
        
        # Only respond to tab changes, not ComboBox selections (event bubbling)
        if ($e.OriginalSource -eq $tabSender) {
            # Clear description labels when switching tabs
            $Form.FindName("ReportDescriptionLabel").Text = ""
            $Form.FindName("ReportDescriptionLabel").Visibility = "Collapsed"
            $Form.FindName("ActionDescriptionLabel").Text = ""
            $Form.FindName("ActionDescriptionLabel").Visibility = "Collapsed"
            
            # Hide all dynamic panels
            HideItems -ItemNames @(
                "Row1ReportingPanel", "Row2ReportingPanel", "Row3ReportingPanel", "Row4ReportingPanel", "Row5ReportingPanel",
                "Row1ActionPanel", "Row2ActionPanel", "Row3ActionPanel", "Row4ActionPanel", "Row5ActionPanel"
            )
            
            # Reset the dropdowns so descriptions show again on re-selection
            $Form.FindName("ReportType").SelectedIndex = -1
            $Form.FindName("ActionType").SelectedIndex = -1
        }
    })
}

# Add click handler for Force Stop button (Actions tab)
$Form.FindName("ForceStopActionButton").Add_Click({
    Write-AppLog -Message "Force Stop requested for Actions tab" -Level "WARNING"
    $ctx = $script:ActiveAsyncContext["Action"]
    if ($null -ne $ctx -and $null -ne $ctx.PowerShell -and -not $ctx.Completed) {
        # Mark as completed and force-stopped to prevent timer tick from processing
        $ctx.ForceStopped = $true
        $ctx.Completed = $true
        $ctx.Timer.Stop()
        
        try {
            $ctx.PowerShell.Stop()
            Write-AppLog -Message "Active operation stopped successfully" -Level "WARNING"
        } catch {
            Write-AppLog -Message "Error stopping operation: $($_.Exception.Message)" -Level "ERROR"
        }
        
        # Clean up: drain EndInvoke, restore UI, dispose
        try { $ctx.PowerShell.EndInvoke($ctx.AsyncHandle) } catch { <# Expected PipelineStoppedException #> }
        Set-UiBusy -IsBusy $false -Tab $ctx.Tab -ControlsToDisable $ctx.Controls
        $ctx.PowerShell.Dispose()
        $script:ActiveAsyncContext["Action"] = $null
        
        [System.Windows.MessageBox]::Show("Operation was stopped by user.", "Force Stopped", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    } else {
        Write-AppLog -Message "No active operation to stop" -Level "DEBUG"
    }
})

# Add click handler for Perform Action button
$WPFPerformActionButton.Add_Click({
    
    # Validate connection before proceeding
    if (-not (Test-MGGraphConnection)) {
        Write-AppLog -Message "Action attempted without Graph connection" -Level "WARNING"
        [System.Windows.MessageBox]::Show("Not connected to Microsoft Graph. Please sign in first.", "Connection Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    
    # Validate permissions for actions
    $permissionCheck = Test-GraphPermissions -OperationType "Action"
    if (-not $permissionCheck.IsValid) {
        Write-AppLog -Message "Insufficient permissions for action" -Level "WARNING" -Details $permissionCheck.Message
        [System.Windows.MessageBox]::Show($permissionCheck.Message, "Insufficient Permissions", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    
    $selectedAction = $Form.FindName("ActionType").Text
    Write-AppLogSection -Title "ACTION EXECUTION: $selectedAction"
    Write-AppLog -Message "User clicked 'Perform Action' button" -Level "USER" -Details "Action: $selectedAction"
    
    # Clean up any temp file from a previous action run
    if ($null -ne $script:LastActionTempFile -and (Test-Path $script:LastActionTempFile -ErrorAction SilentlyContinue)) {
        Remove-Item $script:LastActionTempFile -Force -ErrorAction SilentlyContinue
        $script:LastActionTempFile = $null
    }
    
    # Resolve multiple-device input (file or pasted text) for action handlers
    # Only actions that use the Row3ActionPanel (multiple-device file input) need this
    $script:ActionInputResolution = $null
    $actionsUsingMultipleDeviceInput = @("Remove Devices from Group*", "Retire Devices*", "Update Autopilot Group Tag*", "Delete Device Records*")
    $needsMultiDeviceInput = ($actionsUsingMultipleDeviceInput | Where-Object { $selectedAction -like $_ }).Count -gt 0
    # Also resolve for Import (if multiple mode) and Rename (if file mode) and Remove Android App (if multiple mode)
    if ($needsMultiDeviceInput -or 
        ($selectedAction -like "Import Devices to Group*" -and -not $script:IsSingleDeviceAction) -or
        ($selectedAction -like "Bulk Rename Devices*") -or
        ($selectedAction -like "Remove Android App*")) {
        $script:ActionInputResolution = Resolve-MultipleDeviceInput -FilePath $WPFMultipleDevicesInfoBoxAction.Text -PastedText $WPFPastedDevicesTextBoxAction.Text
        $script:LastActionTempFile = if ($script:ActionInputResolution.TempCreated) { $script:ActionInputResolution.Path } else { $null }
    }
    
    if ($selectedAction -like "Import Devices to Group*") {
        # (Import Devices to Group logic)
        $groupInput = $WPFGroupInputBox.Text
        if ([string]::IsNullOrWhiteSpace($groupInput)) {
            Write-AppLog -Message "Validation failed: No group specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please enter a Group Name or Group Object ID.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        $groupIDType = Get-IdentifierType -Identifier $groupInput -GuidTypeName "Group Object ID" -NameTypeName "Group Name"
        Write-AppLog -Message "Import Devices to Group action starting (async)" -Level "ACTION" -Details "Group: $groupInput ($groupIDType)"
        
        # Capture parameters for async execution
        $script:AsyncImportParams = @{
            IsSingleDevice = $script:IsSingleDeviceAction
            GroupInput = $groupInput
            GroupIDType = $groupIDType
        }
        
        if ($script:IsSingleDeviceAction) {
            $script:AsyncImportParams.DeviceInput = $WPFSingleDeviceInfoBoxAction.Text
            $script:AsyncImportParams.IdType = $WPFSingleDeviceInfoChoiceAction.Text
        } else {
            $script:AsyncImportParams.FilePath = $script:ActionInputResolution.Path
            $script:AsyncImportParams.IdType = $WPFMultipleDevicesInfoChoiceAction.Text
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            if ($params.IsSingleDevice) {
                return Import-DevicesToGroup -IsSingleDevice $true -IDorFilePath $params.DeviceInput -DesiredID $params.IdType -GroupID $params.GroupInput -GroupIDType $params.GroupIDType
            } else {
                return Import-DevicesToGroup -IsSingleDevice $false -IDorFilePath $params.FilePath -DesiredID $params.IdType -GroupID $params.GroupInput -GroupIDType $params.GroupIDType
            }
        } -ArgumentList $script:AsyncImportParams `
          -BusyMessage "Importing devices to group..." -Tab "Action" `
          -ControlsToDisable @("ActionType", "PerformActionButton", "SingleDeviceInfoBoxAction", "MultipleDevicesInfoBoxAction", "GroupInputBox") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData) {
                if ($script:AsyncImportParams.IsSingleDevice) {
                    Write-AppLog -Message "Import completed for single device" -Level "ACTION" -Details "Status: $($returnedData['Status'])"
                } else {
                    Write-AppLogResults -Results $returnedData -Operation "Import Devices to Group"
                }
                $Headers = @("DeviceID", "DeviceName", "Status", "Message")
                UnhideItems -ItemNames @("listviewAction", "ExportActionButton", "CopyActionButton")
                FillDataListView -ListView $WPFlistviewAction -Headers $Headers -Data $returnedData
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Import Devices to Group failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to import devices to group: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    } elseif ($selectedAction -like "Remove Devices from Group*") {
        # Remove Devices from Group action
        $filePath = $script:ActionInputResolution.Path
        $idType = $WPFMultipleDevicesInfoChoiceAction.Text
        $groupInput = $WPFGroupInputBox.Text
        
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            Write-AppLog -Message "Validation failed: No device input specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a file or paste device IDs below.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        if ([string]::IsNullOrWhiteSpace($idType)) {
            Write-AppLog -Message "Validation failed: No ID type selected" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a Device ID type.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        if ([string]::IsNullOrWhiteSpace($groupInput)) {
            Write-AppLog -Message "Validation failed: No group specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please enter a Group Name or Group Object ID.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        # Determine group ID type using helper
        $groupIDType = Get-IdentifierType -Identifier $groupInput -GuidTypeName "Group Object ID" -NameTypeName "Group Name"
        
        # Show confirmation
        $deviceCount = (Get-Content $filePath -Encoding UTF8 -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-AppLog -Message "Remove from Group confirmation requested" -Level "INFO" -Details "Devices: $deviceCount, Group: $groupInput"
        $confirmResult = [System.Windows.MessageBox]::Show("You are about to REMOVE $deviceCount devices from group '$groupInput'.`r`n`r`nDo you want to continue?", "Confirm Remove from Group", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        
        if ($confirmResult -eq [System.Windows.MessageBoxResult]::No) {
            Write-AppLog -Message "Remove from Group action cancelled by user" -Level "USER"
            return
        }
        
        Write-AppLog -Message "Remove from Group action confirmed by user" -Level "USER"
        
        Write-AppLog -Message "Executing Remove Devices from Group (async)" -Level "ACTION" -Details "File: $filePath, ID Type: $idType, Group: $groupInput ($groupIDType)"
        
        $script:AsyncRemoveParams = @{ FilePath = $filePath; IdType = $idType; GroupInput = $groupInput; GroupIDType = $groupIDType }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            return Remove-DevicesFromGroup -FilePath $params.FilePath -DesiredID $params.IdType -GroupID $params.GroupInput -GroupIDType $params.GroupIDType
        } -ArgumentList $script:AsyncRemoveParams `
          -BusyMessage "Removing devices from group..." -Tab "Action" `
          -ControlsToDisable @("ActionType", "PerformActionButton", "MultipleDevicesInfoBoxAction", "GroupInputBox") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData) {
                $Headers = @("DeviceID", "DeviceName", "Status", "Message")
                UnhideItems -ItemNames @("listviewAction", "ExportActionButton", "CopyActionButton")
                FillDataListView -ListView $WPFlistviewAction -Headers $Headers -Data $returnedData
                
                $removedCount = ($returnedData["Status"] | Where-Object { $_ -eq "Removed" }).Count
                $notMemberCount = ($returnedData["Status"] | Where-Object { $_ -eq "Not a Member" }).Count
                $errorCount = ($returnedData["Status"] | Where-Object { $_ -eq "Error" -or $_ -eq "Not Found" }).Count
                
                Write-AppLogResults -Results $returnedData -Operation "Remove Devices from Group"
                Write-AppLog -Message "Remove from Group completed" -Level "ACTION" -Details "Removed: $removedCount, Not a Member: $notMemberCount, Errors: $errorCount"
                
                [System.Windows.MessageBox]::Show("Remove from group operation completed.`r`n`r`nRemoved: $removedCount`r`nNot a Member: $notMemberCount`r`nErrors: $errorCount", "Remove Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Remove Devices from Group failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to remove devices from group: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    } elseif ($selectedAction -like "Empty Group Members*") {
        # Empty Group Members action
        $groupInput = $WPFGroupInputBox.Text
        
        if ([string]::IsNullOrWhiteSpace($groupInput)) {
            Write-AppLog -Message "Validation failed: No group specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please enter a Group Name or Group Object ID.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        # Determine group ID type using helper
        $groupIDType = Get-IdentifierType -Identifier $groupInput -GuidTypeName "Group Object ID" -NameTypeName "Group Name"
        
        Write-AppLog -Message "Empty Group confirmation requested" -Level "INFO" -Details "Group: $groupInput ($groupIDType)"
        
        # Strong warning!
        $confirmResult = [System.Windows.MessageBox]::Show("CRITICAL WARNING: You are about to remove ALL members from group '$groupInput'.`r`n`r`nThis action CANNOT BE UNDONE.`r`n`r`nAre you absolutely sure you want to proceed?", "Confirm Empty Group", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        
        if ($confirmResult -eq [System.Windows.MessageBoxResult]::No) {
            Write-AppLog -Message "Empty Group action cancelled by user" -Level "USER"
            return
        }
        
        # Second confirmation just to be safe
        $confirmResult2 = [System.Windows.MessageBox]::Show("Please confirm again.`r`n`r`nRemove ALL members from '$groupInput'?", "Final Confirmation", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Exclamation)
        
        if ($confirmResult2 -eq [System.Windows.MessageBoxResult]::No) {
            Write-AppLog -Message "Empty Group action cancelled by user (2nd prompt)" -Level "USER"
            return
        }
        
        Write-AppLog -Message "Empty Group action confirmed by user" -Level "USER"
        
        Write-AppLog -Message "Executing Empty Group Members (async)" -Level "ACTION" -Details "Group: $groupInput ($groupIDType)"
        
        $script:AsyncEmptyGroupParams = @{ GroupInput = $groupInput; GroupIDType = $groupIDType }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            return Clear-GroupMembers -GroupID $params.GroupInput -GroupIDType $params.GroupIDType
        } -ArgumentList $script:AsyncEmptyGroupParams `
          -BusyMessage "Emptying group members..." -Tab "Action" `
          -ControlsToDisable @("ActionType", "PerformActionButton", "GroupInputBox") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData) {
                $Headers = @("MemberID", "DisplayName", "Type", "Status", "Message")
                UnhideItems -ItemNames @("listviewAction", "ExportActionButton", "CopyActionButton")
                FillDataListView -ListView $WPFlistviewAction -Headers $Headers -Data $returnedData
                
                $removedCount = ($returnedData["Status"] | Where-Object { $_ -eq "Removed" }).Count
                $errorCount = ($returnedData["Status"] | Where-Object { $_ -eq "Error" }).Count
                
                Write-AppLogResults -Results $returnedData -Operation "Empty Group Members"
                Write-AppLog -Message "Empty Group completed" -Level "ACTION" -Details "Removed: $removedCount, Errors: $errorCount"
                
                [System.Windows.MessageBox]::Show("Empty group operation completed.`r`n`r`nRemoved Members: $removedCount`r`nErrors: $errorCount", "Empty Group Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Empty Group Members failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to empty group members: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    } elseif ($selectedAction -like "Retire Devices*") {
        # Retire Devices action
        $filePath = $script:ActionInputResolution.Path
        $idType = $WPFMultipleDevicesInfoChoiceAction.Text
        
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            Write-AppLog -Message "Validation failed: No device input specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a file or paste device IDs below.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        if ([string]::IsNullOrWhiteSpace($idType)) {
            Write-AppLog -Message "Validation failed: No ID type selected" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a Device ID type.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        # Show initial confirmation
        $deviceCount = (Get-Content $filePath -Encoding UTF8 -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-AppLog -Message "Retire Devices confirmation requested" -Level "INFO" -Details "File: $filePath, Device Count: $deviceCount, ID Type: $idType"
        $initialConfirm = [System.Windows.MessageBox]::Show("You are about to retire $deviceCount devices.`r`n`r`nThis action will:`r`n- Remove company data from devices`r`n- Remove devices from Intune management`r`n`r`nYou will be prompted to confirm EACH device individually.`r`n`r`nDo you want to continue?", "Confirm Retire Action", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Warning)
        
        if ($initialConfirm -eq [System.Windows.MessageBoxResult]::No) {
            Write-AppLog -Message "Retire Devices action cancelled by user" -Level "USER"
            return
        }
        
        Write-AppLog -Message "Retire Devices action confirmed by user" -Level "USER"
        Write-AppLog -Message "Executing Retire Devices (async)" -Level "ACTION" -Details "File: $filePath, ID Type: $idType, Device Count: $deviceCount"
        
        $script:AsyncRetireParams = @{ FilePath = $filePath; IdType = $idType }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            return Invoke-IntuneDeviceRetire -FilePath $params.FilePath -DesiredID $params.IdType
        } -ArgumentList $script:AsyncRetireParams `
          -BusyMessage "Retiring devices..." -Tab "Action" `
          -ControlsToDisable @("ActionType", "PerformActionButton", "MultipleDevicesInfoBoxAction") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData) {
                $Headers = @("DeviceID", "DeviceName", "LastSync", "Ownership", "Status", "Message")
                UnhideItems -ItemNames @("listviewAction", "ExportActionButton", "CopyActionButton")
                FillDataListView -ListView $WPFlistviewAction -Headers $Headers -Data $returnedData
                
                $retiredCount = ($returnedData["Status"] | Where-Object { $_ -eq "Retired" }).Count
                $skippedCount = ($returnedData["Status"] | Where-Object { $_ -eq "Skipped" }).Count
                $errorCount = ($returnedData["Status"] | Where-Object { $_ -eq "Error" -or $_ -eq "Not Found" }).Count
                
                Write-AppLogResults -Results $returnedData -Operation "Retire Devices"
                Write-AppLog -Message "Retire Devices completed" -Level "ACTION" -Details "Retired: $retiredCount, Skipped: $skippedCount, Errors: $errorCount"
                
                [System.Windows.MessageBox]::Show("Retire operation completed.`r`n`r`nRetired: $retiredCount`r`nSkipped: $skippedCount`r`nErrors: $errorCount", "Retire Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Retire Devices failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to retire devices: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    } elseif ($selectedAction -like "Update Autopilot Group Tag*") {
        # Update Autopilot Group Tag action
        $filePath = $script:ActionInputResolution.Path
        $groupTag = $WPFGroupTagBox.Text
        
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            Write-AppLog -Message "Validation failed: No device input specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a file or paste serial numbers below.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        if ([string]::IsNullOrWhiteSpace($groupTag)) {
            Write-AppLog -Message "Validation failed: No group tag specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please enter the new Group Tag value.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        # Show confirmation
        $deviceCount = (Get-Content $filePath -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' } | Measure-Object).Count
        Write-AppLog -Message "Update Autopilot Group Tag confirmation requested" -Level "INFO" -Details "File: $filePath, Device Count: $deviceCount, New Tag: $groupTag"
        $confirmResult = [System.Windows.MessageBox]::Show("You are about to update the Autopilot Group Tag for $deviceCount devices.`r`n`r`nNew Group Tag: '$groupTag'`r`n`r`nDo you want to continue?", "Confirm Update Group Tag", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        
        if ($confirmResult -eq [System.Windows.MessageBoxResult]::No) {
            Write-AppLog -Message "Update Autopilot Group Tag action cancelled by user" -Level "USER"
            return
        }
        
        Write-AppLog -Message "Update Autopilot Group Tag action confirmed by user" -Level "USER"
        Write-AppLog -Message "Executing Update Autopilot Group Tag (async)" -Level "ACTION" -Details "File: $filePath, New Tag: $groupTag, Device Count: $deviceCount"
        
        $script:AsyncGroupTagParams = @{ FilePath = $filePath; GroupTag = $groupTag }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            return Update-AutopilotGroupTag -FilePath $params.FilePath -GroupTag $params.GroupTag
        } -ArgumentList $script:AsyncGroupTagParams `
          -BusyMessage "Updating Autopilot group tags..." -Tab "Action" `
          -ControlsToDisable @("ActionType", "PerformActionButton", "MultipleDevicesInfoBoxAction", "GroupTagBox") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData) {
                $Headers = @("SerialNumber", "DeviceId", "Status", "Message")
                UnhideItems -ItemNames @("listviewAction", "ExportActionButton", "CopyActionButton")
                FillDataListView -ListView $WPFlistviewAction -Headers $Headers -Data $returnedData
                
                $successCount = ($returnedData["Status"] | Where-Object { $_ -eq "Updated" }).Count
                $errorCount = ($returnedData["Status"] | Where-Object { $_ -eq "Error" -or $_ -eq "Not Found" }).Count
                
                Write-AppLogResults -Results $returnedData -Operation "Update Autopilot Group Tag"
                Write-AppLog -Message "Update Autopilot Group Tag completed" -Level "ACTION" -Details "Updated: $successCount, Errors: $errorCount"
                
                [System.Windows.MessageBox]::Show("Update Autopilot Group Tag operation completed.`r`n`r`nSuccessfully Updated: $successCount`r`nErrors: $errorCount", "Update Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Update Autopilot Group Tag failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to update Autopilot group tags: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    } elseif ($selectedAction -like "Bulk Rename Devices*") {
        $namingPrefix = $Form.FindName("RenamePrefixBox").Text
        if ([string]::IsNullOrWhiteSpace($namingPrefix)) {
            Write-AppLog -Message "Validation failed: No prefix specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please enter a naming prefix.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }

        $scopeMode = "All"
        $platform = $Form.FindName("RenamePlatformCombo").Text
        if ($Form.FindName("RenamePlatformCombo").Visibility -eq "Collapsed") { $platform = $null }

        $scopeSelection = $Form.FindName("SingleOrMultipleDevicesAction").SelectedItem
        $filePath = $null
        if ($scopeSelection -eq "Specific Devices from File") {
            $scopeMode = "File"
            $resolvedInput = $script:ActionInputResolution
            if ($null -eq $resolvedInput -or $resolvedInput.Source -eq "None") {
                Write-AppLog -Message "Validation failed: No device input specified" -Level "WARNING"
                [System.Windows.MessageBox]::Show("Please select a file or paste serial numbers below.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                return
            }
            $filePath = $resolvedInput.Path
        }
        
        Write-AppLog -Message "Starting Bulk Rename Devices (async)" -Level "ACTION" -Details "Prefix: $namingPrefix, Scope: $scopeMode, Platform: $platform"
        
        $script:AsyncRenameParams = @{ 
            NamingPrefix = $namingPrefix
            ScopeMode = $scopeMode
            Platform = $platform
            FilePath = $filePath
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            
            $targetDevices = @()
            
            if ($params.ScopeMode -eq "File") {
                $serialsFromFile = Get-Content -Path $params.FilePath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
                $allDevices = Get-IntuneDevicesForRename -FilterPlatform $null -CorporateOnly:$false
                
                foreach ($serial in $serialsFromFile) {
                    $device = $allDevices | Where-Object { $_.SerialNumber -eq $serial }
                    if ($device) { $targetDevices += $device }
                }
            } else {
                $targetDevices = Get-IntuneDevicesForRename -FilterPlatform $params.Platform -CorporateOnly:$true
            }

            if ($null -eq $targetDevices -or $targetDevices.Count -eq 0) {
                return @{ NoDevices = $true }
            }
            
            # Return devices for confirmation (confirmation happens on UI thread via callback)
            return @{ Devices = $targetDevices; NamingPrefix = $params.NamingPrefix; NeedConfirmation = $true }
        } -ArgumentList $script:AsyncRenameParams `
          -BusyMessage "Fetching devices for rename..." -Tab "Action" `
          -ControlsToDisable @("ActionType", "PerformActionButton", "MultipleDevicesInfoBoxAction") `
          -OnSuccess {
            param($returnedData)
            
            if ($returnedData.NoDevices) {
                [System.Windows.MessageBox]::Show("No devices found to rename.", "Info", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                return
            }
            
            if ($returnedData.NeedConfirmation) {
                $targetDevices = $returnedData.Devices
                $namingPrefix = $returnedData.NamingPrefix
                $count = $targetDevices.Count
                
                $confirm = [System.Windows.MessageBox]::Show("Ready to rename $count devices using prefix '$namingPrefix'. Continue?", "Confirm Rename", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
                if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
                
                # Store devices and prefix for the second phase
                $script:AsyncRenameDevices = $targetDevices
                $script:AsyncRenamePrefix = $namingPrefix
                
                # Start the actual renaming in a second async operation
                Invoke-AsyncOperation -ScriptBlock {
                    param($params)
                    $devices = $params.Devices
                    $prefix = $params.Prefix
                    
                    $results = @{
                        "SerialNumber" = @()
                        "OldDeviceName" = @()
                        "NewDeviceName" = @()
                        "Status" = @()
                        "Message" = @()
                    }
                    $successCount = 0
                    $failCount = 0
                    $skipCount = 0

                    foreach ($device in $devices) {
                        $oldName = $device.DeviceName
                        $serial = $device.SerialNumber
                        $id = $device.Id
                        
                        if ([string]::IsNullOrWhiteSpace($serial)) {
                            $results["SerialNumber"] += "N/A"
                            $results["OldDeviceName"] += $oldName
                            $results["NewDeviceName"] += "N/A"
                            $results["Status"] += "Skipped (No Serial)"
                            $results["Message"] += "Device has no serial number"
                            $skipCount++
                            continue
                        }
                        
                        $last8 = if ($serial.Length -gt 8) { $serial.Substring($serial.Length - 8) } else { $serial }
                        $newName = "$prefix-$last8"
                        
                        if ($oldName -eq $newName) {
                            $results["SerialNumber"] += $serial
                            $results["OldDeviceName"] += $oldName
                            $results["NewDeviceName"] += $newName
                            $results["Status"] += "Skipped"
                            $results["Message"] += "Name already matches"
                            $skipCount++
                            continue
                        }

                        $res = Set-IntuneDeviceName -IntuneDeviceID $id -NewDeviceName $newName
                        if ($res) {
                            $results["SerialNumber"] += $serial
                            $results["OldDeviceName"] += $oldName
                            $results["NewDeviceName"] += $newName
                            $results["Status"] += "Renamed"
                            $results["Message"] += "Success"
                            $successCount++
                        } else {
                            $results["SerialNumber"] += $serial
                            $results["OldDeviceName"] += $oldName
                            $results["NewDeviceName"] += $newName
                            $results["Status"] += "Failed"
                            $results["Message"] += "API Error"
                            $failCount++
                        }
                    }
                    
                    return @{ Results = $results; SuccessCount = $successCount; FailCount = $failCount; SkipCount = $skipCount }
                } -ArgumentList @{ Devices = $script:AsyncRenameDevices; Prefix = $script:AsyncRenamePrefix } `
                  -BusyMessage "Renaming devices..." -Tab "Action" `
                  -ControlsToDisable @("ActionType", "PerformActionButton") `
                  -OnSuccess {
                    param($renameResult)
                    $results = $renameResult.Results
                    $Headers = @("SerialNumber", "OldDeviceName", "NewDeviceName", "Status", "Message")
                    UnhideItems -ItemNames @("listviewAction", "ExportActionButton", "CopyActionButton")
                    FillDataListView -ListView $WPFlistviewAction -Headers $Headers -Data $results
                    
                    [System.Windows.MessageBox]::Show("Rename Complete. Success: $($renameResult.SuccessCount), Failed: $($renameResult.FailCount), Skipped: $($renameResult.SkipCount)", "Done", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                } -OnError {
                    param($exception)
                    Write-AppLog -Message "Bulk Rename Devices failed" -Level "ERROR" -Details $exception.Message
                    [System.Windows.MessageBox]::Show("Failed to rename devices: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                }
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Failed to fetch devices for rename" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to fetch devices: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($selectedAction -like "Remove Android App*") {
        # Resolve device IDs based on current selection (single or multiple)
        $scopeSelection = $Form.FindName("SingleOrMultipleDevicesAction").SelectedItem
        
        # Capture params based on scope
        $script:AsyncAndroidAppParams = @{ ScopeSelection = $scopeSelection }
        
        if ($scopeSelection -eq "Single Device") {
            $idType = $WPFSingleDeviceInfoChoiceAction.Text
            $idVal  = $WPFSingleDeviceInfoBoxAction.Text
            if ([string]::IsNullOrWhiteSpace($idType) -or [string]::IsNullOrWhiteSpace($idVal)) {
                [System.Windows.MessageBox]::Show("Please enter the device identifier and select ID type.", "Input Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                return
            }
            $script:AsyncAndroidAppParams.IsSingle = $true
            $script:AsyncAndroidAppParams.IdVal = $idVal
            $script:AsyncAndroidAppParams.IdType = $idType
        } elseif ($scopeSelection -eq "Multiple Devices") {
            $idType   = $WPFMultipleDevicesInfoChoiceAction.Text
            $resolvedInput = $script:ActionInputResolution
            if ($null -eq $resolvedInput -or $resolvedInput.Source -eq "None") {
                [System.Windows.MessageBox]::Show("Please select a file or paste device IDs below.", "Input Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                return
            }
            if ([string]::IsNullOrWhiteSpace($idType)) {
                [System.Windows.MessageBox]::Show("Please select a Device ID type.", "Selection Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
                return
            }
            $script:AsyncAndroidAppParams.IsSingle = $false
            $script:AsyncAndroidAppParams.FilePath = $resolvedInput.Path
            $script:AsyncAndroidAppParams.IdType = $idType
        } else {
            [System.Windows.MessageBox]::Show("Please choose Single or Multiple devices.", "Selection Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }

        # Ensure app selected
        $appCombo = $Form.FindName("AndroidAppCombo")
        $selItem = $appCombo.SelectedItem
        if ($null -eq $selItem -or -not ($selItem -is [System.Windows.Controls.ComboBoxItem]) -or [string]::IsNullOrWhiteSpace($selItem.Tag)) {
            [System.Windows.MessageBox]::Show("Please select an Android app.", "Selection Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning) | Out-Null
            return
        }
        $script:AsyncAndroidAppParams.SelectedAppId = [string]$selItem.Tag
        $appName = $selItem.Content
        
        # Show confirmation dialog
        $deviceCountText = if ($script:AsyncAndroidAppParams.IsSingle) { "1 device" } else { "multiple devices" }
        Write-AppLog -Message "Remove Android App action confirmation requested" -Level "INFO" -Details "App: $appName, Devices: $deviceCountText"
        $confirmResult = [System.Windows.MessageBox]::Show("You are about to send a Remove App remote action for '$appName' to $deviceCountText.`r`n`r`nThis will:`r`n- Send an Intune remote action to remove the app from the device(s)`r`n`r`nNote: this does NOT reinstall the app. To redeploy, update the app assignment in Intune.`r`n`r`nDo you want to continue?", "Confirm Remove App", [System.Windows.MessageBoxButton]::YesNo, [System.Windows.MessageBoxImage]::Question)
        
        if ($confirmResult -eq [System.Windows.MessageBoxResult]::No) {
            Write-AppLog -Message "Remove Android App action cancelled by user" -Level "USER"
            return
        }
        
        Write-AppLog -Message "Remove Android App action confirmed by user" -Level "USER"
        Write-AppLog -Message "Starting Android app removal via Intune remote action (async)" -Level "ACTION" -Details "AppId: $($script:AsyncAndroidAppParams.SelectedAppId)"
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            
            # Resolve device IDs
            if ($params.IsSingle) {
                $deviceIds = Resolve-DeviceIdsFromInput -IsSingle $true -IDorFilePath $params.IdVal -IDType $params.IdType
            } else {
                $deviceIds = Resolve-DeviceIdsFromInput -IsSingle $false -IDorFilePath $params.FilePath -IDType $params.IdType
            }
            
            if (-not $deviceIds -or $deviceIds.Count -eq 0) {
                return @{ NoDevices = $true }
            }
            
            $result = Invoke-AndroidAppChangeAssignments -DeviceIds $deviceIds -SelectedAppId $params.SelectedAppId
            return @{ Data = $result; DeviceCount = $deviceIds.Count }
        } -ArgumentList $script:AsyncAndroidAppParams `
          -BusyMessage "Sending Remove App remote action..." -Tab "Action" `
          -ControlsToDisable @("ActionType", "PerformActionButton", "SingleDeviceInfoBoxAction", "MultipleDevicesInfoBoxAction") `
          -OnSuccess {
            param($returnedData)
            if ($returnedData.NoDevices) {
                [System.Windows.MessageBox]::Show("No matching devices found.", "Info", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
                return
            }
            
            if ($null -ne $returnedData.Data) {
                $Headers = @("DeviceID", "Status", "Message")
                UnhideItems -ItemNames @("listviewAction", "ExportActionButton", "CopyActionButton")
                FillDataListView -ListView $WPFlistviewAction -Headers $Headers -Data $returnedData.Data
                [System.Windows.MessageBox]::Show("Remove App remote action sent successfully.", "Done", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information) | Out-Null
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Remove Android App action failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to send Remove App remote action: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    } elseif ($selectedAction -like "Delete Device Records*") {
        # ========================================
        # DELETE DEVICE RECORDS - DESTRUCTIVE ACTION
        # ========================================
        $filePath = $script:ActionInputResolution.Path
        $idType = $WPFMultipleDevicesInfoChoiceAction.Text
        
        # Get checkbox values for deletion targets
        $deleteIntune = $Form.FindName("DeleteIntuneCheckbox").IsChecked
        $deleteAutopilot = $Form.FindName("DeleteAutopilotCheckbox").IsChecked
        $deleteEntra = $Form.FindName("DeleteEntraCheckbox").IsChecked
        $whatIfMode = $Form.FindName("WhatIfModeCheckbox").IsChecked
        
        # Validation: File path or pasted text
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            Write-AppLog -Message "Validation failed: No device input specified for Delete Device Records" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a file or paste device identifiers below.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        # Validation: ID type
        if ([string]::IsNullOrWhiteSpace($idType)) {
            Write-AppLog -Message "Validation failed: No ID type selected for Delete Device Records" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a Device ID type.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        # Validation: At least one deletion target selected
        if (-not $deleteIntune -and -not $deleteAutopilot -and -not $deleteEntra) {
            Write-AppLog -Message "Validation failed: No deletion targets selected" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select at least one deletion target (Intune, Autopilot, or Entra ID).", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        # Count devices in file
        $deviceCount = (Get-Content $filePath -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' } | Measure-Object).Count
        
        # Build targets description
        $targetsDesc = @()
        if ($deleteIntune) { $targetsDesc += "Intune" }
        if ($deleteAutopilot) { $targetsDesc += "Autopilot" }
        if ($deleteEntra) { $targetsDesc += "Entra ID" }
        $targetsText = $targetsDesc -join ", "
        
        $modeText = if ($whatIfMode) { "DRY RUN (WhatIf Mode - No actual deletions)" } else { "LIVE DELETION - RECORDS WILL BE PERMANENTLY DELETED" }
        
        Write-AppLog -Message "Delete Device Records requested" -Level "INFO" -Details "File: $filePath, Count: $deviceCount, Targets: $targetsText, WhatIf: $whatIfMode"
        
        # FIRST CONFIRMATION - Overview
        $firstConfirm = [System.Windows.MessageBox]::Show(
            "DELETE DEVICE RECORDS`r`n`r`n" +
            "Mode: $modeText`r`n`r`n" +
            "Devices: $deviceCount`r`n" +
            "ID Type: $idType`r`n" +
            "Deletion Targets: $targetsText`r`n`r`n" +
            "Do you want to continue?",
            "Confirm Delete Action",
            [System.Windows.MessageBoxButton]::YesNo,
            $(if ($whatIfMode) { [System.Windows.MessageBoxImage]::Question } else { [System.Windows.MessageBoxImage]::Warning })
        )
        
        if ($firstConfirm -eq [System.Windows.MessageBoxResult]::No) {
            Write-AppLog -Message "Delete Device Records cancelled by user (first confirmation)" -Level "USER"
            return
        }
        
        # SECOND CONFIRMATION (only for LIVE mode) - Type DELETE to confirm
        if (-not $whatIfMode) {
            $typePrompt = [System.Windows.MessageBox]::Show(
                "⚠️ FINAL WARNING ⚠️`r`n`r`n" +
                "You are about to PERMANENTLY DELETE records for $deviceCount devices from:`r`n" +
                "• $targetsText`r`n`r`n" +
                "THIS ACTION CANNOT BE UNDONE!`r`n`r`n" +
                "Are you absolutely sure you want to proceed?",
                "FINAL CONFIRMATION - DESTRUCTIVE ACTION",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Stop
            )
            
            if ($typePrompt -eq [System.Windows.MessageBoxResult]::No) {
                Write-AppLog -Message "Delete Device Records cancelled by user (final confirmation)" -Level "USER"
                [System.Windows.MessageBox]::Show("Delete operation cancelled.", "Cancelled", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                return
            }
            
            Write-AppLog -Message "Delete Device Records LIVE MODE confirmed by user" -Level "USER" -Details "Count: $deviceCount, Targets: $targetsText"
        } else {
            Write-AppLog -Message "Delete Device Records DRY RUN confirmed by user" -Level "USER"
        }
        
        Write-AppLog -Message "Executing Delete Device Records (async)" -Level "ACTION" -Details "File: $filePath, ID Type: $idType, WhatIf: $whatIfMode, Targets: $targetsText"
        
        $script:AsyncDeleteParams = @{
            FilePath = $filePath
            IdType = $idType
            DeleteIntune = $deleteIntune
            DeleteAutopilot = $deleteAutopilot
            DeleteEntra = $deleteEntra
            WhatIfMode = $whatIfMode
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            return Remove-IntuneDeviceRecords -FilePath $params.FilePath -DesiredID $params.IdType `
                -DeleteIntune $params.DeleteIntune -DeleteAutopilot $params.DeleteAutopilot `
                -DeleteEntraId $params.DeleteEntra -WhatIf $params.WhatIfMode
        } -ArgumentList $script:AsyncDeleteParams `
          -BusyMessage $(if ($whatIfMode) { "Analyzing devices (WhatIf mode)..." } else { "Deleting device records..." }) -Tab "Action" `
          -ControlsToDisable @("ActionType", "PerformActionButton", "MultipleDevicesInfoBoxAction") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData) {
                $Headers = @("InputValue", "DeviceName", "SerialNumber", "IntuneDeleteStatus", "AutopilotDeleteStatus", "EntraDeleteStatus", "WhatIfMode")
                UnhideItems -ItemNames @("listviewAction", "ExportActionButton", "CopyActionButton")
                FillDataListView -ListView $WPFlistviewAction -Headers $Headers -Data $returnedData
                
                # Calculate summary
                $intuneSuccess = ($returnedData["IntuneDeleteStatus"] | Where-Object { $_ -eq "Success" }).Count
                $intuneFailed = ($returnedData["IntuneDeleteStatus"] | Where-Object { $_ -eq "Failed" }).Count
                $autopilotSuccess = ($returnedData["AutopilotDeleteStatus"] | Where-Object { $_ -eq "Success" }).Count
                $autopilotFailed = ($returnedData["AutopilotDeleteStatus"] | Where-Object { $_ -eq "Failed" }).Count
                $entraSuccess = ($returnedData["EntraDeleteStatus"] | Where-Object { $_ -eq "Success" }).Count
                $entraFailed = ($returnedData["EntraDeleteStatus"] | Where-Object { $_ -eq "Failed" }).Count
                
                $whatIfCount = ($returnedData["IntuneDeleteStatus"] | Where-Object { $_ -like "*WhatIf*" }).Count
                
                Write-AppLogResults -Results $returnedData -Operation "Delete Device Records"
                
                $summaryMsg = if ($whatIfCount -gt 0) {
                    "DRY RUN COMPLETE (No changes made)`r`n`r`n" +
                    "Devices analyzed: $whatIfCount`r`n`r`n" +
                    "Review the results to see what WOULD be deleted."
                } else {
                    "DELETE OPERATION COMPLETE`r`n`r`n" +
                    "Intune: $intuneSuccess deleted, $intuneFailed failed`r`n" +
                    "Autopilot: $autopilotSuccess deleted, $autopilotFailed failed`r`n" +
                    "Entra ID: $entraSuccess deleted, $entraFailed failed"
                }
                
                Write-AppLog -Message "Delete Device Records completed" -Level "ACTION" -Details "IntuneOK: $intuneSuccess, AutopilotOK: $autopilotSuccess, EntraOK: $entraSuccess"
                
                [System.Windows.MessageBox]::Show($summaryMsg, "Delete Device Records Complete", [System.Windows.MessageBoxButton]::OK, $(if ($whatIfCount -gt 0) { [System.Windows.MessageBoxImage]::Information } else { [System.Windows.MessageBoxImage]::Warning }))
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Delete Device Records failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to delete device records: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
})

# Add click handler for Force Stop button (Reporting tab)
$Form.FindName("ForceStopReportButton").Add_Click({
    Write-AppLog -Message "Force Stop requested for Reporting tab" -Level "WARNING"
    $ctx = $script:ActiveAsyncContext["Reporting"]
    if ($null -ne $ctx -and $null -ne $ctx.PowerShell -and -not $ctx.Completed) {
        # Mark as completed and force-stopped to prevent timer tick from processing
        $ctx.ForceStopped = $true
        $ctx.Completed = $true
        $ctx.Timer.Stop()
        
        try {
            $ctx.PowerShell.Stop()
            Write-AppLog -Message "Active report operation stopped successfully" -Level "WARNING"
        } catch {
            Write-AppLog -Message "Error stopping report operation: $($_.Exception.Message)" -Level "ERROR"
        }
        
        # Clean up: drain EndInvoke, restore UI, dispose
        try { $ctx.PowerShell.EndInvoke($ctx.AsyncHandle) } catch { <# Expected PipelineStoppedException #> }
        Set-UiBusy -IsBusy $false -Tab $ctx.Tab -ControlsToDisable $ctx.Controls
        $ctx.PowerShell.Dispose()
        $script:ActiveAsyncContext["Reporting"] = $null
        
        [System.Windows.MessageBox]::Show("Operation was stopped by user.", "Force Stopped", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    } else {
        Write-AppLog -Message "No active report operation to stop" -Level "DEBUG"
    }
})

#################################################### GENERATE REPORT BUTTON ####################################################

$WPFGenerateReportButton.Add_Click({ 
    # Validate connection before proceeding
    if (-not (Test-MGGraphConnection)) {
        Write-AppLog -Message "Report attempted without Graph connection" -Level "WARNING"
        [System.Windows.MessageBox]::Show("Not connected to Microsoft Graph. Please sign in first.", "Connection Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    
    # Validate permissions for reports
    $permissionCheck = Test-GraphPermissions -OperationType "Report"
    if (-not $permissionCheck.IsValid) {
        Write-AppLog -Message "Insufficient permissions for report" -Level "WARNING" -Details $permissionCheck.Message
        [System.Windows.MessageBox]::Show($permissionCheck.Message, "Insufficient Permissions", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    
    $selectedReportType = $Form.FindName("ReportType").Text
    
    # Validate report type is selected
    if ([string]::IsNullOrWhiteSpace($selectedReportType)) {
        Write-AppLog -Message "Report generation attempted without selecting report type" -Level "WARNING"
        [System.Windows.MessageBox]::Show("Please select a report type.", "Selection Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }
    
    # Define which reports use which input modes
    $reportsWithNoInput = @("Export TPM/Hardware Info for All Devices - Export all TPM/BIOS")
    $reportsWithSingleInputOnly = @("Get Group Assignments - Group memberships")
    $reportsWithFileInputOnly = @("Get Autopilot Info - Autopilot registration")
    $reportsWithPlatformOnly = @("Get OS Distribution - OS version counts")
    $reportsWithPlatformAndApp = @("Get App Version Distribution - App version counts")
    $reportsWithGroupInput = @("Get Group Members Intune Info - Group devices info")
    
    # Validate input fields based on report type
    if ($selectedReportType -in $reportsWithGroupInput) {
        # Reports that need group input
        $groupInput = $Form.FindName("GroupInputBoxReporting").Text
        if ([string]::IsNullOrWhiteSpace($groupInput)) {
            Write-AppLog -Message "Report generation attempted without entering group" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please enter a group name or Object ID.", "Input Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
    } elseif ($selectedReportType -in $reportsWithPlatformAndApp) {
        # Reports that need platform and app selection
        $selectedPlatform = $Form.FindName("PlatformSelectCombo").Text
        if ([string]::IsNullOrWhiteSpace($selectedPlatform)) {
            Write-AppLog -Message "Report generation attempted without selecting platform" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a platform.", "Selection Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
        $selectedApp = $Form.FindName("AppSelectCombo").SelectedItem
        if ($null -eq $selectedApp -or [string]::IsNullOrWhiteSpace($selectedApp.Tag)) {
            Write-AppLog -Message "Report generation attempted without selecting app" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select an app.", "Selection Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
    } elseif ($selectedReportType -in $reportsWithPlatformOnly) {
        # Reports that only need platform selection
        $selectedPlatform = $Form.FindName("PlatformSelectCombo").Text
        if ([string]::IsNullOrWhiteSpace($selectedPlatform)) {
            Write-AppLog -Message "Report generation attempted without selecting platform" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a platform.", "Selection Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return
        }
    } elseif ($selectedReportType -notin $reportsWithNoInput) {
        if ($selectedReportType -in $reportsWithSingleInputOnly) {
            # Reports that only use single input box (like group assignments)
            if ([string]::IsNullOrWhiteSpace($WPFSingleDeviceInfoBox.Text)) {
                Write-AppLog -Message "Report generation attempted with empty input" -Level "WARNING"
                [System.Windows.MessageBox]::Show("Please enter the required input.", "Input Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                return
            }
        } elseif ($selectedReportType -in $reportsWithFileInputOnly) {
            # Reports that only use file/paste input (like autopilot info)
            $hasValidInput = (-not [string]::IsNullOrWhiteSpace($WPFMultipleDevicesInfoBox.Text) -and (Test-Path $WPFMultipleDevicesInfoBox.Text -PathType Leaf)) -or
                             (-not [string]::IsNullOrWhiteSpace($WPFPastedDevicesTextBox.Text))
            if (-not $hasValidInput) {
                Write-AppLog -Message "Report generation attempted with no device input" -Level "WARNING"
                [System.Windows.MessageBox]::Show("Please select a file or paste device IDs below.", "Input Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                return
            }
        } elseif ($IsSingleDevice -eq $true) {
            # Single device mode - validate input box
            if ([string]::IsNullOrWhiteSpace($WPFSingleDeviceInfoBox.Text)) {
                Write-AppLog -Message "Report generation attempted with empty device input" -Level "WARNING"
                [System.Windows.MessageBox]::Show("Please enter a device identifier.", "Input Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                return
            }
            if ([string]::IsNullOrWhiteSpace($WPFSingleDeviceInfoChoice.Text)) {
                Write-AppLog -Message "Report generation attempted without selecting ID type" -Level "WARNING"
                [System.Windows.MessageBox]::Show("Please select an ID type.", "Selection Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                return
            }
        } elseif ($IsSingleDevice -eq $false) {
            # Multiple device mode - validate file path or pasted text
            $hasValidInput = (-not [string]::IsNullOrWhiteSpace($WPFMultipleDevicesInfoBox.Text) -and (Test-Path $WPFMultipleDevicesInfoBox.Text -PathType Leaf)) -or
                             (-not [string]::IsNullOrWhiteSpace($WPFPastedDevicesTextBox.Text))
            if (-not $hasValidInput) {
                Write-AppLog -Message "Report generation attempted with no device input" -Level "WARNING"
                [System.Windows.MessageBox]::Show("Please select a file or paste device IDs below.", "Input Required", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
                return
            }
        }
    }
    
    # Clean up any temp file from a previous report run
    if ($null -ne $script:LastReportTempFile -and (Test-Path $script:LastReportTempFile -ErrorAction SilentlyContinue)) {
        Remove-Item $script:LastReportTempFile -Force -ErrorAction SilentlyContinue
        $script:LastReportTempFile = $null
    }
    
    # Resolve multiple-device input (file or pasted text) for all report handlers that need it
    $script:ReportInputResolution = $null
    if ($IsSingleDevice -eq $false -or $selectedReportType -in $reportsWithFileInputOnly) {
        $script:ReportInputResolution = Resolve-MultipleDeviceInput -FilePath $WPFMultipleDevicesInfoBox.Text -PastedText $WPFPastedDevicesTextBox.Text
        $script:LastReportTempFile = if ($script:ReportInputResolution.TempCreated) { $script:ReportInputResolution.Path } else { $null }
    }
    
    Write-AppLogSection -Title "REPORT EXECUTION: $selectedReportType"
    Write-AppLog -Message "User clicked 'Generate Report' button" -Level "USER" -Details "Report: $selectedReportType, Single Device: $IsSingleDevice"
    
    if ($Form.FindName("ReportType").Text -like "Get Device Information*"){
        # Capture UI values BEFORE going async (we're on UI thread here)
        # Use script-scope so callbacks can access these values
        $script:AsyncDeviceInfoParams = @{
            IsSingleDevice = $isSingleDevice
            DeviceInput    = if ($isSingleDevice) { $WPFSingleDeviceInfoBox.Text } else { $script:ReportInputResolution.Path }
            IdType         = if ($isSingleDevice) { $WPFSingleDeviceInfoChoice.Text } else { $WPFMultipleDevicesInfoChoice.Text }
        }
        
        # Log the operation
        if ($isSingleDevice) {
            Write-AppLog -Message "Executing Get Device Information (Single) - ASYNC" -Level "REPORT" -Details "Device: $($script:AsyncDeviceInfoParams.DeviceInput), ID Type: $($script:AsyncDeviceInfoParams.IdType)"
        } else {
            $deviceCount = (Get-Content $script:AsyncDeviceInfoParams.DeviceInput -Encoding UTF8 -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-AppLog -Message "Executing Get Device Information (Multiple) - ASYNC" -Level "REPORT" -Details "File: $($script:AsyncDeviceInfoParams.DeviceInput), ID Type: $($script:AsyncDeviceInfoParams.IdType), Count: $deviceCount"
        }
        
        # Run the Graph API call asynchronously
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            # This runs in background thread - no UI access allowed here
            Get-IntuneDeviceInfo -IsSingleDevice $params.IsSingleDevice -IDorFilePath $params.DeviceInput -DesiredID $params.IdType
        } -ArgumentList $script:AsyncDeviceInfoParams `
          -BusyMessage "Fetching device details from Intune..." `
          -Tab "Reporting" `
          -ControlsToDisable @("GenerateReportButton", "ReportType", "SingleOrMultipleDevices") `
          -OnSuccess {
            param($returnedData)
            # This runs on UI thread - safe to update UI here
            if ($null -ne $returnedData) {
                if ($script:AsyncDeviceInfoParams.IsSingleDevice) {
                    Write-AppLog -Message "Device info retrieved successfully" -Level "INFO" -Details "Device Name: $($returnedData['DeviceName'])"
                    $Headers = $returnedData.Keys
                    UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                    FillDataListView -ListView $WPFlistview -Headers $Headers -Data $returnedData
                } else {
                    Write-AppLogResults -Results $returnedData -Operation "Get Device Information"
                    UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                    FillDataListView -ListView $WPFlistview -Headers @("DeviceName", "PrimaryUser", "LastSyncDate", "OperatingSystem", "OSVersion", "Model", "ComplianceState") -Data $returnedData
                }
            } else {
                Write-AppLog -Message "No data returned for device info" -Level "WARNING"
                [System.Windows.MessageBox]::Show("No data was returned. The device may not exist or you may not have permission to access it.", "No Results", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        } `
          -OnError {
            param($exception)
            # This runs on UI thread - safe to show message box
            Write-AppLog -Message "Get Device Information failed" -Level "ERROR" -Details $exception.Message
            $errorMsg = Format-ActionableError -ErrorType $(if ($exception.Message -match "not found") { "DeviceNotFound" } elseif ($exception.Message -match "403|Forbidden|permission") { "PermissionDenied" } elseif ($exception.Message -match "429|throttl") { "RateLimited" } else { "APIError" }) -Identifier $script:AsyncDeviceInfoParams.DeviceInput -IdentifierType $script:AsyncDeviceInfoParams.IdType -OriginalError $exception.Message -Operation "Get Device Information"
            [System.Windows.MessageBox]::Show($errorMsg, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        
        # Return from the click handler - the async operation continues in background
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Get Bitlocker Status*") {
        # Capture UI values BEFORE going async
        $script:AsyncBitlockerParams = @{
            IsSingleDevice = $isSingleDevice
            DeviceInput    = if ($isSingleDevice) { $WPFSingleDeviceInfoBox.Text } else { $script:ReportInputResolution.Path }
            IdType         = if ($isSingleDevice) { $WPFSingleDeviceInfoChoice.Text } else { $WPFMultipleDevicesInfoChoice.Text }
        }
        
        if ($isSingleDevice) {
            Write-AppLog -Message "Executing Get Bitlocker Status (Single) - ASYNC" -Level "REPORT" -Details "Device: $($script:AsyncBitlockerParams.DeviceInput), ID Type: $($script:AsyncBitlockerParams.IdType)"
        } else {
            $deviceCount = (Get-Content $script:AsyncBitlockerParams.DeviceInput -Encoding UTF8 -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-AppLog -Message "Executing Get Bitlocker Status (Multiple) - ASYNC" -Level "REPORT" -Details "File: $($script:AsyncBitlockerParams.DeviceInput), ID Type: $($script:AsyncBitlockerParams.IdType), Count: $deviceCount"
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            Get-IntuneDeviceEncryptionDetails -IsSingleDevice $params.IsSingleDevice -IDorFilePath $params.DeviceInput -DesiredID $params.IdType
        } -ArgumentList $script:AsyncBitlockerParams `
          -BusyMessage "Fetching Bitlocker encryption status..." `
          -Tab "Reporting" `
          -ControlsToDisable @("GenerateReportButton", "ReportType", "SingleOrMultipleDevices") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData) {
                if ($script:AsyncBitlockerParams.IsSingleDevice) {
                    Write-AppLog -Message "Bitlocker status retrieved" -Level "INFO" -Details "Encrypted: $($returnedData['IsEncrypted'])"
                    UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                    FillDataListView -ListView $WPFlistview -Headers $returnedData.Keys -Data $returnedData
                } else {
                    Write-AppLogResults -Results $returnedData -Operation "Get Bitlocker Status"
                    UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                    FillDataListView -ListView $WPFlistview -Headers @("LastSyncDate", "IntuneID", "IsEncrypted", "DeviceName") -Data $returnedData
                }
            } else {
                Write-AppLog -Message "No data returned for bitlocker status" -Level "WARNING"
                [System.Windows.MessageBox]::Show("No data was returned.", "No Results", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        } `
          -OnError {
            param($exception)
            Write-AppLog -Message "Get Bitlocker Status failed" -Level "ERROR" -Details $exception.Message
            $errorMsg = Format-ActionableError -ErrorType $(if ($exception.Message -match "not found") { "DeviceNotFound" } elseif ($exception.Message -match "403|Forbidden|permission") { "PermissionDenied" } elseif ($exception.Message -match "429|throttl") { "RateLimited" } else { "APIError" }) -Identifier $script:AsyncBitlockerParams.DeviceInput -IdentifierType $script:AsyncBitlockerParams.IdType -OriginalError $exception.Message -Operation "Get Bitlocker Status"
            [System.Windows.MessageBox]::Show($errorMsg, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Get Device Last Logged-on User*") {
        # Capture UI values BEFORE going async
        $script:AsyncLoggedOnUserParams = @{
            IsSingleDevice = $isSingleDevice
            DeviceInput    = if ($isSingleDevice) { $WPFSingleDeviceInfoBox.Text } else { $script:ReportInputResolution.Path }
            IdType         = if ($isSingleDevice) { $WPFSingleDeviceInfoChoice.Text } else { $WPFMultipleDevicesInfoChoice.Text }
        }
        
        if ($isSingleDevice) {
            Write-AppLog -Message "Executing Get Device Last Logged-on User (Single) - ASYNC" -Level "REPORT" -Details "Device: $($script:AsyncLoggedOnUserParams.DeviceInput), ID Type: $($script:AsyncLoggedOnUserParams.IdType)"
        } else {
            $deviceCount = (Get-Content $script:AsyncLoggedOnUserParams.DeviceInput -Encoding UTF8 -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-AppLog -Message "Executing Get Device Last Logged-on User (Multiple) - ASYNC" -Level "REPORT" -Details "File: $($script:AsyncLoggedOnUserParams.DeviceInput), ID Type: $($script:AsyncLoggedOnUserParams.IdType), Count: $deviceCount"
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            Get-IntuneDeviceLastLoggedOnUser -IsSingleDevice $params.IsSingleDevice -IDorFilePath $params.DeviceInput -DesiredID $params.IdType
        } -ArgumentList $script:AsyncLoggedOnUserParams `
          -BusyMessage "Fetching last logged-on user information..." `
          -Tab "Reporting" `
          -ControlsToDisable @("GenerateReportButton", "ReportType", "SingleOrMultipleDevices") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData) {
                if ($script:AsyncLoggedOnUserParams.IsSingleDevice) {
                    Write-AppLog -Message "Last logged-on user retrieved" -Level "INFO" -Details "User: $($returnedData['UserDisplayName'])"
                    UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                    FillDataListView -ListView $WPFlistview -Headers $returnedData.Keys -Data $returnedData
                } else {
                    Write-AppLogResults -Results $returnedData -Operation "Get Device Last Logged-on User"
                    UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                    FillDataListView -ListView $WPFlistview -Headers @("DeviceName", "UserDisplayName", "UserId", "LastLogOnDateTime") -Data $returnedData
                }
            } else {
                Write-AppLog -Message "No data returned for last logged-on user" -Level "WARNING"
                [System.Windows.MessageBox]::Show("No data was returned.", "No Results", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        } `
          -OnError {
            param($exception)
            Write-AppLog -Message "Get Device Last Logged-on User failed" -Level "ERROR" -Details $exception.Message
            $errorMsg = Format-ActionableError -ErrorType $(if ($exception.Message -match "not found") { "DeviceNotFound" } elseif ($exception.Message -match "403|Forbidden|permission") { "PermissionDenied" } elseif ($exception.Message -match "429|throttl") { "RateLimited" } else { "APIError" }) -Identifier $script:AsyncLoggedOnUserParams.DeviceInput -IdentifierType $script:AsyncLoggedOnUserParams.IdType -OriginalError $exception.Message -Operation "Get Device Last Logged-on User"
            [System.Windows.MessageBox]::Show($errorMsg, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Get Detected Apps*") {
        # Capture UI values BEFORE going async
        $script:AsyncDetectedAppsParams = @{
            IsSingleDevice = $isSingleDevice
            DeviceInput    = if ($isSingleDevice) { $WPFSingleDeviceInfoBox.Text } else { $script:ReportInputResolution.Path }
            IdType         = if ($isSingleDevice) { $WPFSingleDeviceInfoChoice.Text } else { $WPFMultipleDevicesInfoChoice.Text }
        }
        
        if ($isSingleDevice) {
            Write-AppLog -Message "Executing Get Detected Apps (Single) - ASYNC" -Level "REPORT" -Details "Device: $($script:AsyncDetectedAppsParams.DeviceInput), ID Type: $($script:AsyncDetectedAppsParams.IdType)"
        } else {
            $deviceCount = (Get-Content $script:AsyncDetectedAppsParams.DeviceInput -Encoding UTF8 -ErrorAction SilentlyContinue | Measure-Object).Count
            Write-AppLog -Message "Executing Get Detected Apps (Multiple) - ASYNC" -Level "REPORT" -Details "File: $($script:AsyncDetectedAppsParams.DeviceInput), ID Type: $($script:AsyncDetectedAppsParams.IdType), Count: $deviceCount"
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            Get-IntuneDetectedApps -IsSingleDevice $params.IsSingleDevice -IDorFilePath $params.DeviceInput -DesiredID $params.IdType
        } -ArgumentList $script:AsyncDetectedAppsParams `
          -BusyMessage "Fetching detected apps from devices... This may take a moment." `
          -Tab "Reporting" `
          -ControlsToDisable @("GenerateReportButton", "ReportType", "SingleOrMultipleDevices") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData -and $returnedData["AppDisplayName"].Count -gt 0) {
                Write-AppLog -Message "Detected apps retrieved" -Level "INFO" -Details "Total app entries: $($returnedData['AppDisplayName'].Count)"
                UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                FillDataListView -ListView $WPFlistview -Headers @("DeviceName", "IntuneDeviceId", "AppDisplayName", "AppVersion", "SizeInByte", "DeviceCount") -Data $returnedData
                
                # Show summary message
                $uniqueDevices = ($returnedData["DeviceName"] | Select-Object -Unique).Count
                $totalApps = $returnedData["AppDisplayName"].Count
                [System.Windows.MessageBox]::Show("Detected apps retrieved successfully.`n`nDevices processed: $uniqueDevices`nTotal app entries: $totalApps", "Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            } else {
                Write-AppLog -Message "No detected apps found" -Level "WARNING"
                [System.Windows.MessageBox]::Show("No detected apps were found for the specified device(s).", "No Results", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            }
        } `
          -OnError {
            param($exception)
            Write-AppLog -Message "Get Detected Apps failed" -Level "ERROR" -Details $exception.Message
            $errorMsg = Format-ActionableError -ErrorType $(if ($exception.Message -match "not found") { "DeviceNotFound" } elseif ($exception.Message -match "403|Forbidden|permission") { "PermissionDenied" } elseif ($exception.Message -match "429|throttl") { "RateLimited" } else { "APIError" }) -Identifier $script:AsyncDetectedAppsParams.DeviceInput -IdentifierType $script:AsyncDetectedAppsParams.IdType -OriginalError $exception.Message -Operation "Get Detected Apps"
            [System.Windows.MessageBox]::Show($errorMsg, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Get Group Assignments*") {
        $script:AsyncGroupAssignParams = @{
            GroupInput = $WPFSingleDeviceInfoBox.Text
            IdType     = $WPFSingleDeviceInfoChoice.Text
        }
        Write-AppLog -Message "Executing Get Group Assignments - ASYNC" -Level "REPORT" -Details "Group: $($script:AsyncGroupAssignParams.GroupInput), ID Type: $($script:AsyncGroupAssignParams.IdType)"
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            Get-IntuneGroupAssignments -GroupID $params.GroupInput -IDType $params.IdType
        } -ArgumentList $script:AsyncGroupAssignParams `
          -BusyMessage "Fetching group assignments..." `
          -Tab "Reporting" `
          -ControlsToDisable @("GenerateReportButton", "ReportType") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData -and $returnedData["PolicyName"].Count -gt 0) {
                Write-AppLog -Message "Group assignments retrieved" -Level "INFO" -Details "Total assignments: $($returnedData['PolicyName'].Count)"
                $resultText = "Group Assignment Results`r`n"
                $resultText += "=" * 80 + "`r`n`r`n"
                
                for ($i = 0; $i -lt $returnedData["PolicyName"].Count; $i++) {
                    $resultText += "Policy Name: $($returnedData['PolicyName'][$i])`r`n"
                    $resultText += "Policy Type: $($returnedData['PolicyType'][$i])`r`n"
                    $resultText += "Assignment Type: $($returnedData['AssignmentType'][$i])`r`n"
                    $resultText += "Policy ID: $($returnedData['PolicyId'][$i])`r`n"
                    $resultText += "-" * 80 + "`r`n"
                }
                
                $resultText += "`r`nTotal Assignments Found: $($returnedData['PolicyName'].Count)"
                $WPFResultsTextBox.Text = $resultText
                HideItems -ItemNames @("listview")
                UnhideItems -ItemNames @("ResultsTextBox")
            } else {
                Write-AppLog -Message "No group assignments found" -Level "INFO" -Details "Group: $($script:AsyncGroupAssignParams.GroupInput)"
                $WPFResultsTextBox.Text = "No assignments found for this group."
                HideItems -ItemNames @("listview")
                UnhideItems -ItemNames @("ResultsTextBox")
            }
        } `
          -OnError {
            param($exception)
            Write-AppLog -Message "Get Group Assignments failed" -Level "ERROR" -Details $exception.Message
            $errorMsg = Format-ActionableError -ErrorType $(if ($exception.Message -match "not found") { "GroupNotFound" } elseif ($exception.Message -match "403|Forbidden|permission") { "PermissionDenied" } elseif ($exception.Message -match "429|throttl") { "RateLimited" } else { "APIError" }) -Identifier $script:AsyncGroupAssignParams.GroupInput -IdentifierType "Group" -OriginalError $exception.Message -Operation "Get Group Assignments"
            [System.Windows.MessageBox]::Show($errorMsg, "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Check Group Membership*") {
        # Get group name from textbox
        $groupName = $WPFGroupInputBoxReporting.Text
        
        if ([string]::IsNullOrWhiteSpace($groupName)) {
            Write-AppLog -Message "Validation failed: No group specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please enter a Group Name or Object ID.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        Write-AppLog -Message "Executing Check Group Membership (async)" -Level "REPORT" -Details "Group: $groupName"
        
        # Capture parameters for async execution
        $script:AsyncGroupMembershipParams = @{
            IsSingleDevice = $isSingleDevice
            GroupName = $groupName
        }
        
        if ($isSingleDevice) {
            $script:AsyncGroupMembershipParams.DeviceInput = $WPFSingleDeviceInfoBox.Text
            $script:AsyncGroupMembershipParams.IdType = $WPFSingleDeviceInfoChoice.Text
        } else {
            $script:AsyncGroupMembershipParams.FilePath = $script:ReportInputResolution.Path
            $script:AsyncGroupMembershipParams.IdType = $WPFMultipleDevicesInfoChoice.Text
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            if ($params.IsSingleDevice) {
                $result = Test-IntuneDeviceGroupMembership -IsSingleDevice $true -IDorFilePath $params.DeviceInput -DesiredID $params.IdType -GroupNameOrID $params.GroupName
            } else {
                $result = Test-IntuneDeviceGroupMembership -IsSingleDevice $false -IDorFilePath $params.FilePath -DesiredID $params.IdType -GroupNameOrID $params.GroupName
            }
            return @{ Data = $result; IsSingleDevice = $params.IsSingleDevice }
        } -ArgumentList $script:AsyncGroupMembershipParams `
          -BusyMessage "Checking group membership..." -Tab "Reporting" `
          -ControlsToDisable @("ReportType", "GenerateReportButton", "SingleDeviceInfoBox", "MultipleDevicesInfoBox") `
          -OnSuccess {
            param($returnedData)
            $data = $returnedData.Data
            $isSingle = $returnedData.IsSingleDevice
            if ($null -ne $data) {
                if ($isSingle) {
                    Write-AppLog -Message "Group membership check completed" -Level "INFO" -Details "State: $($data['State'])"
                    $Headers = $data.Keys
                } else {
                    Write-AppLogResults -Results $data -Operation "Check Group Membership"
                    $Headers = @("DeviceID", "DeviceName", "DeviceAzureADID", "GroupName", "State")
                }
                UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                HideItems -ItemNames @("ResultsTextBox")
                FillDataListView -ListView $WPFlistview -Headers $Headers -Data $data
            } else {
                Write-AppLog -Message "No data returned for group membership check" -Level "WARNING"
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Check Group Membership failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to check group membership: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Get Autopilot Info*") {
        # This report only works with multiple devices and Entra ID Device IDs
        $filePath = $script:ReportInputResolution.Path
        $deviceCount = (Get-Content $filePath -Encoding UTF8 -ErrorAction SilentlyContinue | Measure-Object).Count
        Write-AppLog -Message "Executing Get Autopilot Info (async)" -Level "REPORT" -Details "File: $filePath, Device Count: $deviceCount"
        
        $script:AsyncAutopilotParams = @{ FilePath = $filePath }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            return Get-IntuneAutopilotInfo -FilePath $params.FilePath
        } -ArgumentList $script:AsyncAutopilotParams `
          -BusyMessage "Getting Autopilot info..." -Tab "Reporting" `
          -ControlsToDisable @("ReportType", "GenerateReportButton", "MultipleDevicesInfoBox") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData) {
                Write-AppLogResults -Results $returnedData -Operation "Get Autopilot Info"
                UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                HideItems -ItemNames @("ResultsTextBox")                              
                FillDataListView -ListView $WPFlistview -Headers @("DeviceName", "LastSyncDateTime", "Ownership", "EntraID", "IntuneID", "AutopilotInfo") -Data $returnedData
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Get Autopilot Info failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to get Autopilot info: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Get User Details*") {
        
        if ($isSingleDevice) {
            # Single user - get UPN from text box
            $upn = $WPFSingleDeviceInfoBox.Text
            
            if ([string]::IsNullOrWhiteSpace($upn)) {
                Write-AppLog -Message "Validation failed: No user ID specified" -Level "WARNING"
                [System.Windows.MessageBox]::Show("Please enter a UPN or Object ID.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                return
            }
            
            Write-AppLog -Message "Executing Get User Details (Single, async)" -Level "REPORT" -Details "UPN: $upn"
            $script:AsyncUserDetailsParams = @{ IsSingleUser = $true; UPN = $upn }
        } else {
            # Multiple users - resolve input from file path or pasted text
            $filePath = $script:ReportInputResolution.Path
            
            if ([string]::IsNullOrWhiteSpace($filePath)) {
                Write-AppLog -Message "Validation failed: No UPN input specified" -Level "WARNING"
                [System.Windows.MessageBox]::Show("Please enter the path to the file containing UPNs or paste UPNs below.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
                return
            }
            
            $userCount = (Get-Content $filePath -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' } | Measure-Object).Count
            Write-AppLog -Message "Executing Get User Details (Multiple, async)" -Level "REPORT" -Details "File: $filePath, User Count: $userCount"
            $script:AsyncUserDetailsParams = @{ IsSingleUser = $false; FilePath = $filePath }
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            if ($params.IsSingleUser) {
                return @{ Data = (Get-EntraUserDetails -IsSingleUser $true -UPNorFilePath $params.UPN); IsSingleUser = $true }
            } else {
                return @{ Data = (Get-EntraUserDetails -IsSingleUser $false -UPNorFilePath $params.FilePath); IsSingleUser = $false }
            }
        } -ArgumentList $script:AsyncUserDetailsParams `
          -BusyMessage "Getting user details..." -Tab "Reporting" `
          -ControlsToDisable @("ReportType", "GenerateReportButton", "SingleDeviceInfoBox", "MultipleDevicesInfoBox") `
          -OnSuccess {
            param($returnedData)
            $data = $returnedData.Data
            $isSingle = $returnedData.IsSingleUser
            if ($null -ne $data) {
                if ($isSingle) {
                    Write-AppLog -Message "User details retrieved" -Level "INFO" -Details "Display Name: $($data['DisplayName']), Status: $($data['Status'])"
                    $Headers = $data.Keys
                } else {
                    Write-AppLogResults -Results $data -Operation "Get User Details"
                    $Headers = @("UserPrincipalName", "DisplayName", "Mail", "JobTitle", "Department", "MobilePhone", "AccountEnabled", "Status")
                }
                UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                HideItems -ItemNames @("ResultsTextBox")
                FillDataListView -ListView $WPFlistview -Headers $Headers -Data $data
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Get User Details failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to get user details: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Get Policy Non-Compliance*") {
        
        $filePath = $script:ReportInputResolution.Path
        $idType = $WPFMultipleDevicesInfoChoice.Text
        $policyId = $WPFPolicyIDBox.Text
        
        if ([string]::IsNullOrWhiteSpace($filePath)) {
            Write-AppLog -Message "Validation failed: No device input specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a file or paste device IDs below.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        if ([string]::IsNullOrWhiteSpace($idType)) {
            Write-AppLog -Message "Validation failed: No ID type selected" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please select a Device ID type.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        if ([string]::IsNullOrWhiteSpace($policyId)) {
            Write-AppLog -Message "Validation failed: No Policy ID specified" -Level "WARNING"
            [System.Windows.MessageBox]::Show("Please enter a Policy ID (GUID).", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        # Validate Policy ID format
        if ($policyId -notmatch '^[{]?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}[}]?$') {
            Write-AppLog -Message "Validation failed: Invalid Policy ID format" -Level "ERROR" -Details "Policy ID: $policyId"
            [System.Windows.MessageBox]::Show("Invalid Policy ID format. Please enter a valid GUID.", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
            return
        }
        
        $deviceCount = (Get-Content $filePath -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' } | Measure-Object).Count
        Write-AppLog -Message "Executing Get Policy Non-Compliance Settings (async)" -Level "REPORT" -Details "File: $filePath, ID Type: $idType, Policy ID: $policyId, Device Count: $deviceCount"
        
        $script:AsyncPolicyNonComplianceParams = @{ FilePath = $filePath; IdType = $idType; PolicyId = $policyId }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            return Get-PolicyNonComplianceSettings -FilePath $params.FilePath -DesiredID $params.IdType -PolicyID $params.PolicyId
        } -ArgumentList $script:AsyncPolicyNonComplianceParams `
          -BusyMessage "Getting policy non-compliance settings..." -Tab "Reporting" `
          -ControlsToDisable @("ReportType", "GenerateReportButton", "MultipleDevicesInfoBox", "PolicyIDBox") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData -and $returnedData["DeviceID"].Count -gt 0) {
                Write-AppLogResults -Results $returnedData -Operation "Get Policy Non-Compliance Settings"
                $Headers = @("DeviceID", "DeviceName", "SettingName", "SettingStatus", "ErrorCode", "ErrorType", "ErrorMessage")
                UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                HideItems -ItemNames @("ResultsTextBox")
                FillDataListView -ListView $WPFlistview -Headers $Headers -Data $returnedData
                
                $totalSettings = $returnedData["SettingName"].Count
                Write-AppLog -Message "Policy non-compliance report completed" -Level "REPORT" -Details "Total settings found: $totalSettings"
                [System.Windows.MessageBox]::Show("Policy non-compliance report completed.`r`n`r`nTotal non-compliant settings found: $totalSettings", "Report Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
            } else {
                Write-AppLog -Message "No non-compliant settings found" -Level "INFO" -Details "Policy ID: $($script:AsyncPolicyNonComplianceParams.PolicyId)"
                $WPFResultsTextBox.Text = "No non-compliant settings found for the specified devices and policy."
                HideItems -ItemNames @("listview")
                UnhideItems -ItemNames @("ResultsTextBox")
            }
        } -OnError {
            param($exception)
            Write-AppLog -Message "Get Policy Non-Compliance Settings failed" -Level "ERROR" -Details $exception.Message
            [System.Windows.MessageBox]::Show("Failed to get policy non-compliance settings: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Export TPM/Hardware Info*") {
        Write-AppLog -Message "Executing Export TPM/Hardware Info for All Devices (async)" -Level "REPORT" -Details "Filter: Windows corporate-managed MDM devices"
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            return Get-TPMAndBIOSInfo -BatchSize 20 -ThrottleLimit 10
        } -ArgumentList @{} `
          -BusyMessage "Exporting TPM/Hardware info for all devices..." -Tab "Reporting" `
          -ControlsToDisable @("ReportType", "GenerateReportButton") `
          -OnSuccess {
            param($returnedData)
            if ($null -ne $returnedData -and $returnedData["DeviceName"].Count -gt 0) {
                $displayHeaders = @("DeviceName", "SerialNumber", "UserPrincipalName", "Model", "Manufacturer", "TPMVersion", "TPMSpecificationVersion", "BIOSVersion", "OSBuildNumber", "ComplianceState", "Status")
                
                UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
                HideItems -ItemNames @("ResultsTextBox")
                FillDataListView -ListView $WPFlistview -Headers $displayHeaders -Data $returnedData
                
                $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                $exportDir = Get-ExportDirectory
                $exportPath = Join-Path -Path $exportDir -ChildPath "TPMAndBIOSInfo_$timestamp.csv"
                
                $rawResults = $returnedData["_RawResults"]
                if ($null -ne $rawResults) {
                    $rawResults | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
                    Write-AppLog -Message "TPM/BIOS info exported" -Level "REPORT" -Details "Export path: $exportPath, Devices: $($rawResults.Count)"
                    
                    $successCount = ($rawResults | Where-Object { $_.Status -eq "Success" }).Count
                    $failedCount = ($rawResults | Where-Object { $_.Status -eq "Failed" }).Count
                    
                    [System.Windows.MessageBox]::Show("TPM/BIOS info collection completed.`r`n`r`nTotal Devices: $($rawResults.Count)`r`nSuccessful: $successCount`r`nFailed: $failedCount`r`n`r`nExported to: $exportPath", "Export Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
                }
            } else {
                Write-AppLog -Message "No devices returned from TPM/BIOS info collection" -Level "WARNING"
                HideItems -ItemNames @("listview")
                $WPFResultsTextBox.Text = "No devices returned by the selected filter."
                UnhideItems -ItemNames @("ResultsTextBox")
            }
        } -OnError {
            param($exception)
            Write-Error "Failed to retrieve TPM/BIOS info: $($exception.Message)"
            Write-AppLog -Message "TPM/BIOS info collection failed" -Level "ERROR" -Details "$($exception.Message)"
            [System.Windows.MessageBox]::Show("Failed to retrieve TPM/BIOS info. See console for details.`r`n`r`nError: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Get OS Distribution*") {
        $selectedPlatform = $Form.FindName("PlatformSelectCombo").Text
        Write-AppLog -Message "Executing Get OS Distribution (async)" -Level "REPORT" -Details "Platform: $selectedPlatform"
        
        $script:AsyncOSDistParams = @{
            Platform = $selectedPlatform
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            
            $platform = $params.Platform
            
            # Build filter for corporate devices of the selected platform
            $filter = "managedDeviceOwnerType eq 'company' and operatingSystem eq '$platform'"
            
            Write-AppLog -Message "Fetching devices with filter: $filter" -Level "INFO"
            $devices = Get-MgDeviceManagementManagedDevice -All -Filter $filter -Property "id,deviceName,osVersion,operatingSystem"
            
            if ($null -eq $devices -or $devices.Count -eq 0) {
                return @{ NoDevices = $true; Platform = $platform }
            }
            
            # Group by OS version and count
            $osDistribution = $devices | Group-Object -Property osVersion | 
                Select-Object @{N='OS Version';E={$_.Name}}, @{N='Device Count';E={$_.Count}} |
                Sort-Object -Property 'Device Count' -Descending
            
            # Convert to hashtable format for FillDataListView
            $results = @{
                "OS Version" = @()
                "Device Count" = @()
            }
            
            foreach ($item in $osDistribution) {
                $results["OS Version"] += $item.'OS Version'
                $results["Device Count"] += $item.'Device Count'
            }
            
            return @{ 
                Results = $results
                TotalDevices = $devices.Count
                UniqueVersions = $osDistribution.Count
                Platform = $platform
            }
        } -ArgumentList $script:AsyncOSDistParams `
          -BusyMessage "Fetching OS distribution for $selectedPlatform devices..." -Tab "Reporting" `
          -ControlsToDisable @("ReportType", "GenerateReportButton") `
          -OnSuccess {
            param($returnedData)
            
            if ($returnedData.NoDevices) {
                Write-AppLog -Message "No devices found for platform: $($returnedData.Platform)" -Level "WARNING"
                HideItems -ItemNames @("listview")
                $WPFResultsTextBox.Text = "No corporate $($returnedData.Platform) devices found."
                UnhideItems -ItemNames @("ResultsTextBox")
                return
            }
            
            $results = $returnedData.Results
            $totalDevices = $returnedData.TotalDevices
            $uniqueVersions = $returnedData.UniqueVersions
            $platform = $returnedData.Platform
            
            Write-AppLog -Message "OS Distribution report completed" -Level "REPORT" -Details "Platform: $platform, Total: $totalDevices, Unique versions: $uniqueVersions"
            
            # Display in ListView
            $displayHeaders = @("OS Version", "Device Count")
            UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
            HideItems -ItemNames @("ResultsTextBox")
            FillDataListView -ListView $WPFlistview -Headers $displayHeaders -Data $results
            
            [System.Windows.MessageBox]::Show("OS Distribution for $platform`r`n`r`nTotal Corporate Devices: $totalDevices`r`nUnique OS Versions: $uniqueVersions", "Report Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        } -OnError {
            param($exception)
            Write-Error "Failed to retrieve OS distribution: $($exception.Message)"
            Write-AppLog -Message "OS Distribution report failed" -Level "ERROR" -Details "$($exception.Message)"
            [System.Windows.MessageBox]::Show("Failed to retrieve OS distribution: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Get App Version Distribution*") {
        $selectedPlatform = $Form.FindName("PlatformSelectCombo").Text
        $selectedAppItem = $Form.FindName("AppSelectCombo").SelectedItem
        $selectedAppId = $selectedAppItem.Tag
        $selectedAppName = $selectedAppItem.Content
        
        Write-AppLog -Message "Executing Get App Version Distribution (async)" -Level "REPORT" -Details "App: $selectedAppName, ID: $selectedAppId, Platform: $selectedPlatform"
        
        $script:AsyncAppVersionParams = @{
            AppId = $selectedAppId
            AppName = $selectedAppName
            Platform = $selectedPlatform
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            
            $appId = $params.AppId
            $appName = $params.AppName
            
            try {
                # Get app details to determine the current version
                $appDetailsUri = "https://graph.microsoft.com/beta/deviceAppManagement/mobileApps/$appId"
                $appDetails = Invoke-MgGraphRequest -Method GET -Uri $appDetailsUri
                $currentVersion = $appDetails.displayVersion
                
                # Use the retrieveDeviceAppInstallationStatusReport endpoint (this is what Intune portal uses)
                $reportUri = "https://graph.microsoft.com/beta/deviceManagement/reports/retrieveDeviceAppInstallationStatusReport"
                
                $allRows = @()
                $skip = 0
                $top = 50
                $hasMore = $true
                $schema = $null
                
                while ($hasMore) {
                    $body = @{
                        select = @("AppInstallState", "AppInstallStateDetails", "ApplicationId", "AppVersion", "DeviceId", "DeviceName", "Platform", "UserName", "UserPrincipalName", "LastModifiedDateTime")
                        filter = "(ApplicationId eq '$appId')"
                        skip = $skip
                        top = $top
                        orderBy = @()
                    }
                    
                    # Use temp file approach since report endpoint returns binary stream
                    $tempFile = [System.IO.Path]::GetTempFileName()
                    try {
                        Invoke-MgGraphRequest -Method POST -Uri $reportUri -Body $body -OutputFilePath $tempFile
                        $responseJson = Get-Content -Path $tempFile -Raw
                        $response = $responseJson | ConvertFrom-Json
                    }
                    finally {
                        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }
                    }
                    
                    if ($null -eq $schema -and $response.Schema) {
                        $schema = $response.Schema
                    }
                    
                    if ($response.Values -and $response.Values.Count -gt 0) {
                        $allRows += $response.Values
                        $skip += $top
                        
                        # Check if we got a full page (might have more)
                        if ($response.Values.Count -lt $top) {
                            $hasMore = $false
                        }
                    } else {
                        $hasMore = $false
                    }
                }
                
                if ($allRows.Count -eq 0) {
                    # No install status data found
                    return @{ 
                        NoDevices = $true
                        AppName = $appName
                        CurrentVersion = $currentVersion
                        Message = "No installation status data found for this app."
                    }
                }
                
                # Parse the report response - Schema tells us column order, Values has the data
                # Column order from schema: AppInstallState, AppInstallStateDetails, ApplicationId, AppVersion, DeviceId, DeviceName, Platform, UserName, UserPrincipalName, LastModifiedDateTime
                
                # Build a lookup for column indices
                $columnMap = @{}
                for ($i = 0; $i -lt $schema.Count; $i++) {
                    $columnMap[$schema[$i].Column] = $i
                }
                
                # Group by version and install state
                $versionStats = @{}
                
                foreach ($row in $allRows) {
                    $version = $row[$columnMap["AppVersion"]]
                    $installState = $row[$columnMap["AppInstallState"]]
                    
                    if ([string]::IsNullOrWhiteSpace($version)) { $version = "(Unknown)" }
                    
                    if (-not $versionStats.ContainsKey($version)) {
                        $versionStats[$version] = @{
                            Total = 0
                            Installed = 0
                            Pending = 0
                            Failed = 0
                            Other = 0
                        }
                    }
                    
                    $versionStats[$version].Total++
                    
                    # S1 = Installed, S2 = Pending, S3 = Failed, etc.
                    switch ($installState) {
                        "S1" { $versionStats[$version].Installed++ }
                        "S2" { $versionStats[$version].Pending++ }
                        "S3" { $versionStats[$version].Failed++ }
                        default { $versionStats[$version].Other++ }
                    }
                }
                
                # Convert to hashtable format for FillDataListView
                $results = @{
                    "Version" = @()
                    "Total Devices" = @()
                    "Installed" = @()
                    "Pending" = @()
                    "Failed" = @()
                    "Is Current" = @()
                }
                
                # Sort by total count descending
                $sortedVersions = $versionStats.GetEnumerator() | Sort-Object { $_.Value.Total } -Descending
                
                foreach ($entry in $sortedVersions) {
                    $results["Version"] += $entry.Key
                    $results["Total Devices"] += $entry.Value.Total
                    $results["Installed"] += $entry.Value.Installed
                    $results["Pending"] += $entry.Value.Pending
                    $results["Failed"] += $entry.Value.Failed
                    $results["Is Current"] += if ($entry.Key -eq $currentVersion) { "Yes" } else { "No" }
                }
                
                return @{ 
                    Results = $results
                    TotalDevices = $allRows.Count
                    UniqueVersions = $versionStats.Count
                    AppName = $appName
                    CurrentVersion = $currentVersion
                }
            }
            catch {
                return @{ Error = $_.Exception.Message; AppName = $appName }
            }
        } -ArgumentList $script:AsyncAppVersionParams `
          -BusyMessage "Fetching version distribution for '$selectedAppName'..." -Tab "Reporting" `
          -ControlsToDisable @("ReportType", "GenerateReportButton") `
          -OnSuccess {
            param($returnedData)
            
            if ($returnedData.Error) {
                Write-AppLog -Message "App Version Distribution report failed" -Level "ERROR" -Details $returnedData.Error
                HideItems -ItemNames @("listview")
                $WPFResultsTextBox.Text = "Error retrieving version distribution for '$($returnedData.AppName)':`r`n`r`n$($returnedData.Error)"
                UnhideItems -ItemNames @("ResultsTextBox")
                return
            }
            
            if ($returnedData.NoDevices) {
                Write-AppLog -Message "No device statuses found for app: $($returnedData.AppName)" -Level "WARNING"
                HideItems -ItemNames @("listview")
                $message = $returnedData.Message
                if (-not $message) { $message = "No device install statuses found." }
                $WPFResultsTextBox.Text = "No version data found for '$($returnedData.AppName)':`r`n`r`n$message`r`n`r`nCurrent version in Intune: $($returnedData.CurrentVersion)"
                UnhideItems -ItemNames @("ResultsTextBox")
                return
            }
            
            $results = $returnedData.Results
            $totalDevices = $returnedData.TotalDevices
            $uniqueVersions = $returnedData.UniqueVersions
            $appName = $returnedData.AppName
            $currentVersion = $returnedData.CurrentVersion
            $note = $returnedData.Note
            
            Write-AppLog -Message "App Version Distribution report completed" -Level "REPORT" -Details "App: $appName, Total: $totalDevices, Unique versions: $uniqueVersions"
            
            # Display in ListView - determine headers from the results
            $displayHeaders = @($results.Keys)
            UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
            HideItems -ItemNames @("ResultsTextBox")
            FillDataListView -ListView $WPFlistview -Headers $displayHeaders -Data $results
            
            $currentVersionInfo = if ($currentVersion) { "Current Version: $currentVersion" } else { "Current Version: Unknown" }
            $noteInfo = if ($note) { "`r`n`r`nNote: $note" } else { "" }
            [System.Windows.MessageBox]::Show("App Version Distribution for:`r`n$appName`r`n`r`n$currentVersionInfo`r`nDevices Checked: $totalDevices`r`nUnique Versions Found: $uniqueVersions$noteInfo", "Report Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        } -OnError {
            param($exception)
            Write-Error "Failed to retrieve app version distribution: $($exception.Message)"
            Write-AppLog -Message "App Version Distribution report failed" -Level "ERROR" -Details "$($exception.Message)"
            [System.Windows.MessageBox]::Show("Failed to retrieve app version distribution: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
    elseif ($Form.FindName("ReportType").Text -like "Get Group Members Intune Info*") {
        $groupInput = $Form.FindName("GroupInputBoxReporting").Text.Trim()
        
        Write-AppLog -Message "Executing Get Group Members Intune Info (async)" -Level "REPORT" -Details "Group: $groupInput"
        
        $script:AsyncGroupMembersParams = @{
            GroupInput = $groupInput
        }
        
        Invoke-AsyncOperation -ScriptBlock {
            param($params)
            
            $groupInput = $params.GroupInput
            
            try {
                # Determine if input is GUID or name
                $isGuid = $groupInput -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
                
                # Get the group
                if ($isGuid) {
                    $group = Get-MgGroup -GroupId $groupInput -ErrorAction Stop
                    $groupId = $group.Id
                    $groupDisplayName = $group.DisplayName
                } else {
                    # Escape single quotes for OData filter safety
                    $safeGroupName = $groupInput -replace "'", "''"
                    $uri = "https://graph.microsoft.com/v1.0/groups?`$filter=displayName eq '$safeGroupName'"
                    $response = Invoke-MgGraphRequest -Method GET -Uri $uri
                    $groups = $response.value
                    
                    if ($groups.Count -eq 0) {
                        return @{ Error = "Group '$groupInput' not found." }
                    } elseif ($groups.Count -gt 1) {
                        return @{ Error = "Multiple groups found with name '$groupInput'. Please use the Object ID instead." }
                    }
                    $groupId = $groups[0].id
                    $groupDisplayName = $groups[0].displayName
                }
                
                Write-Host "Fetching device members of group '$groupDisplayName'..."
                
                # Fetch device members directly via the typed endpoint in a single paginated call.
                # This returns device objects with 'deviceId' (= azureADDeviceId in Intune) already
                # included, eliminating one individual API call per device compared to Get-MgGroupMember.
                $deviceMembers = @()
                $membersUri = "https://graph.microsoft.com/v1.0/groups/$groupId/members/microsoft.graph.device?`$select=id,deviceId,displayName&`$top=999"
                do {
                    $membersResponse = Invoke-MgGraphRequest -Method GET -Uri $membersUri -ErrorAction Stop
                    if ($membersResponse.value) { $deviceMembers += $membersResponse.value }
                    $membersUri = $membersResponse.'@odata.nextLink'
                } while ($membersUri)
                
                if ($deviceMembers.Count -eq 0) {
                    # Check whether the group has any members at all (users, etc.)
                    $totalMembersCount = (Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/groups/$groupId/members/`$count" -Headers @{ ConsistencyLevel = "eventual" } -ErrorAction SilentlyContinue)
                    if ($totalMembersCount -gt 0) {
                        return @{
                            NoDevices = $true
                            GroupName = $groupDisplayName
                            GroupId = $groupId
                            TotalMembers = $totalMembersCount
                        }
                    }
                    return @{
                        NoMembers = $true
                        GroupName = $groupDisplayName
                        GroupId = $groupId
                    }
                }
                
                Write-Host "Found $($deviceMembers.Count) device member(s). Pre-fetching Intune records..."
                
                # Pre-fetch ALL Intune managed devices once and build a hashtable for O(1) lookups.
                # This replaces per-device filter queries (which were O(N) API calls) with a single
                # paginated call, making the report dramatically faster for large groups.
                $allIntuneDevices = Get-MgDeviceManagementManagedDevice -All `
                    -Property "id,deviceName,azureADDeviceId,operatingSystem,osVersion,complianceState,lastSyncDateTime,userPrincipalName,enrolledDateTime" `
                    -ErrorAction Stop
                
                $intuneDeviceLookup = @{}
                foreach ($d in $allIntuneDevices) {
                    if (-not [string]::IsNullOrWhiteSpace($d.AzureADDeviceId)) {
                        $intuneDeviceLookup[$d.AzureADDeviceId] = $d
                    }
                }
                Write-Host "Intune records loaded ($($allIntuneDevices.Count) total). Matching group members..."
                
                # Build results by matching each device member to its Intune record in memory
                $results = @{
                    "Device Name" = @()
                    "Entra Device ID" = @()
                    "Intune ID" = @()
                    "OS" = @()
                    "OS Version" = @()
                    "Compliance" = @()
                    "Last Sync" = @()
                    "Primary User" = @()
                    "Enrollment Date" = @()
                }
                
                $foundCount = 0
                $notInIntuneCount = 0
                
                foreach ($deviceMember in $deviceMembers) {
                    $entraObjectId = $deviceMember.id
                    # 'deviceId' from the typed members endpoint equals azureADDeviceId in Intune
                    $azureADDeviceId = $deviceMember.deviceId
                    $deviceDisplayName = $deviceMember.displayName
                    
                    if ([string]::IsNullOrWhiteSpace($azureADDeviceId)) {
                        $notInIntuneCount++
                        $results["Device Name"] += if ($deviceDisplayName) { $deviceDisplayName } else { "Unknown" }
                        $results["Entra Device ID"] += $entraObjectId
                        $results["Intune ID"] += "No deviceId on Entra record"
                        $results["OS"] += "-"
                        $results["OS Version"] += "-"
                        $results["Compliance"] += "-"
                        $results["Last Sync"] += "-"
                        $results["Primary User"] += "-"
                        $results["Enrollment Date"] += "-"
                        continue
                    }
                    
                    $intuneDevice = $intuneDeviceLookup[$azureADDeviceId]
                    
                    if ($intuneDevice) {
                        $foundCount++
                        $results["Device Name"] += $intuneDevice.DeviceName
                        $results["Entra Device ID"] += $azureADDeviceId
                        $results["Intune ID"] += $intuneDevice.Id
                        $results["OS"] += $intuneDevice.OperatingSystem
                        $results["OS Version"] += $intuneDevice.OsVersion
                        $results["Compliance"] += $intuneDevice.ComplianceState
                        $results["Last Sync"] += if ($intuneDevice.LastSyncDateTime) { $intuneDevice.LastSyncDateTime.ToString("yyyy-MM-dd HH:mm") } else { "Never" }
                        $results["Primary User"] += if ($intuneDevice.UserPrincipalName) { $intuneDevice.UserPrincipalName } else { "No user" }
                        $results["Enrollment Date"] += if ($intuneDevice.EnrolledDateTime) { $intuneDevice.EnrolledDateTime.ToString("yyyy-MM-dd") } else { "Unknown" }
                    } else {
                        $notInIntuneCount++
                        $results["Device Name"] += if ($deviceDisplayName) { $deviceDisplayName } else { "Unknown" }
                        $results["Entra Device ID"] += $azureADDeviceId
                        $results["Intune ID"] += "Not in Intune"
                        $results["OS"] += "-"
                        $results["OS Version"] += "-"
                        $results["Compliance"] += "-"
                        $results["Last Sync"] += "-"
                        $results["Primary User"] += "-"
                        $results["Enrollment Date"] += "-"
                    }
                }
                
                return @{
                    Results = $results
                    GroupName = $groupDisplayName
                    GroupId = $groupId
                    TotalDevices = $deviceMembers.Count
                    InIntuneCount = $foundCount
                    NotInIntuneCount = $notInIntuneCount
                }
            }
            catch {
                return @{ Error = $_.Exception.Message }
            }
        } -ArgumentList $script:AsyncGroupMembersParams `
          -BusyMessage "Fetching group members and Intune info for '$groupInput'..." -Tab "Reporting" `
          -ControlsToDisable @("GenerateReportButton", "ReportType") `
          -OnSuccess {
            param($returnedData)
            
            if ($returnedData.Error) {
                Write-AppLog -Message "Group Members Intune Info report failed" -Level "ERROR" -Details $returnedData.Error
                HideItems -ItemNames @("listview")
                $WPFResultsTextBox.Text = "Error retrieving group members:`r`n`r`n$($returnedData.Error)"
                UnhideItems -ItemNames @("ResultsTextBox")
                return
            }
            
            if ($returnedData.NoMembers) {
                Write-AppLog -Message "Group has no members" -Level "WARNING" -Details "Group: $($returnedData.GroupName)"
                HideItems -ItemNames @("listview")
                $WPFResultsTextBox.Text = "Group '$($returnedData.GroupName)' has no members."
                UnhideItems -ItemNames @("ResultsTextBox")
                return
            }
            
            if ($returnedData.NoDevices) {
                Write-AppLog -Message "Group has no device members" -Level "WARNING" -Details "Group: $($returnedData.GroupName), Total members: $($returnedData.TotalMembers)"
                HideItems -ItemNames @("listview")
                $WPFResultsTextBox.Text = "Group '$($returnedData.GroupName)' has $($returnedData.TotalMembers) member(s), but none are devices.`r`n`r`nThis report only shows device members."
                UnhideItems -ItemNames @("ResultsTextBox")
                return
            }
            
            $results = $returnedData.Results
            $groupName = $returnedData.GroupName
            $totalDevices = $returnedData.TotalDevices
            $inIntuneCount = $returnedData.InIntuneCount
            $notInIntuneCount = $returnedData.NotInIntuneCount
            
            Write-AppLog -Message "Group Members Intune Info report completed" -Level "REPORT" -Details "Group: $groupName, Total: $totalDevices, In Intune: $inIntuneCount"
            
            # Display in ListView
            $displayHeaders = @("Device Name", "Entra Device ID", "Intune ID", "OS", "OS Version", "Compliance", "Last Sync", "Primary User", "Enrollment Date")
            UnhideItems -ItemNames @("listview", "ExportReportButton", "CopyReportButton")
            HideItems -ItemNames @("ResultsTextBox")
            FillDataListView -ListView $WPFlistview -Headers $displayHeaders -Data $results
            
            [System.Windows.MessageBox]::Show("Group Members Intune Info for:`r`n$groupName`r`n`r`nTotal Device Members: $totalDevices`r`nFound in Intune: $inIntuneCount`r`nNot in Intune: $notInIntuneCount", "Report Complete", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Information)
        } -OnError {
            param($exception)
            Write-Error "Failed to retrieve group members: $($exception.Message)"
            Write-AppLog -Message "Group Members Intune Info report failed" -Level "ERROR" -Details "$($exception.Message)"
            [System.Windows.MessageBox]::Show("Failed to retrieve group members: $($exception.Message)", "Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        }
        return
    }
})

#===========================================================================
# Export to CSV Button Handlers
#===========================================================================

# Export Report button click handler
$WPFExportReportButton.Add_Click({
    Write-AppLog -Message "User clicked Export Report button" -Level "USER"
    $reportType = $WPFReportType.SelectedItem
    $exportName = if ($reportType) { $reportType } else { "Report" }
    Export-ListViewToCsv -ListView $WPFlistview -ExportName $exportName
})

# Export Action button click handler
$WPFExportActionButton.Add_Click({
    Write-AppLog -Message "User clicked Export Action button" -Level "USER"
    $actionType = $WPFActionType.SelectedItem
    $exportName = if ($actionType) { $actionType } else { "Action" }
    Export-ListViewToCsv -ListView $WPFlistviewAction -ExportName $exportName
})


#===========================================================================
# Shows the form
#===========================================================================

# Add event handler for when the form is closing
$Form.Add_Closing({
    Write-AppLogSection -Title "APPLICATION CLOSING"
    Write-AppLog -Message "The Powerful Intune Bulk Actions Tool closing" -Level "INFO"
    Write-AppLog -Message "Log file location: $(Get-AppLogPath)" -Level "INFO"
    
    # Clean up the async RunspacePool
    Close-AsyncRunspacePool
})

function Show-Form{
    Write-AppLog -Message "Displaying main application window" -Level "INFO"
    try {
        $Form.ShowDialog() | out-null
        Write-AppLog -Message "Application session ended" -Level "INFO"
    }
    catch {
        $errDetails = "$($_.Exception.Message)`nStackTrace: $($_.ScriptStackTrace)`nInnerException: $($_.Exception.InnerException)"
        Write-AppLog -Message "Error displaying form" -Level "ERROR" -Details $errDetails
        Write-Error "Failed to display form: $($_.Exception.Message)`nScript Stack: $($_.ScriptStackTrace)"
        [System.Windows.MessageBox]::Show("An error occurred while displaying the application. Please check the log file for details.`n`nError: $($_.Exception.Message)`n`nStack: $($_.ScriptStackTrace)", "Application Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
    }
}
    
Show-Form
