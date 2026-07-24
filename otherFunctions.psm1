#region Logging Functions
# Global log file path - will be initialized when the app starts
$script:LogFilePath = $null

# Base export/log directory (no date suffix) - dated subfolders are created automatically
# Files are written to $BaseExportDirectory\YYYYMMDD\ (e.g. C:\Temp\20260315\)
$script:BaseExportDirectory = $null

# Log settings
$script:MaxLogFiles = 5          # Maximum number of log files to keep
$script:MaxLogSizeMB = 10        # Maximum log file size in MB before rotation
$script:LogLevel = "DEBUG"       # Minimum log level: DEBUG, INFO, WARNING, ERROR

# Log level priority (lower = more verbose)
$script:LogLevelPriority = @{
    "DEBUG"   = 0
    "INFO"    = 1
    "USER"    = 1
    "REPORT"  = 1
    "ACTION"  = 1
    "WARNING" = 2
    "ERROR"   = 3
}

function Set-ExportDirectory {
    <#
    .SYNOPSIS
        Sets the base directory for log files and exports.
    .DESCRIPTION
        Allows configuration of the base export/log directory. Files are placed in a dated
        subfolder under this path (e.g. C:\Temp\20260315). If not set, defaults to C:\Temp.
    .PARAMETER Path
        The base directory path to use for exports and logs.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Path
    )
    
    if (-not (Test-Path $Path)) {
        try {
            New-Item -ItemType Directory -Path $Path -Force | Out-Null
            Write-Host "Created export directory: $Path" -ForegroundColor Green
        } catch {
            Write-Error "Failed to create directory: $Path. Error: $_"
            return $false
        }
    }
    
    $script:BaseExportDirectory = $Path
    Write-Host "Base export directory set to: $Path (files will be saved under $Path\YYYYMMDD\)" -ForegroundColor Cyan
    return $true
}

function Get-ExportDirectory {
    <#
    .SYNOPSIS
        Gets the current working export/log directory (date-stamped subfolder).
    .DESCRIPTION
        Returns the base directory with today's date appended as a subfolder (YYYYMMDD).
        All logs and exports for a given day are grouped under the same folder, e.g.
        C:\Temp\20260315. The subfolder is created automatically if it does not exist.
    .OUTPUTS
        Returns the full path to today's working directory, e.g. C:\Temp\20260315
    .NOTES
        If the configured base directory cannot be created or written to (e.g. a
        locked-down machine where C:\Temp is not allowed), the function falls back
        to a IntuneTool folder inside the user's %TEMP% directory.
    #>
    $base = if ([string]::IsNullOrWhiteSpace($script:BaseExportDirectory)) { "C:\Temp" } else { $script:BaseExportDirectory }
    $dateFolder = Get-Date -Format "yyyyMMdd"
    try {
        $dated = [System.IO.Path]::Combine($base, $dateFolder)
        if (-not (Test-Path -LiteralPath $dated)) {
            New-Item -ItemType Directory -Path $dated -Force -ErrorAction Stop | Out-Null
        }
    }
    catch {
        # Configured base is not writable - fall back to the user's temp directory
        $fallbackBase = [System.IO.Path]::Combine($env:TEMP, "IntuneTool")
        $dated = [System.IO.Path]::Combine($fallbackBase, $dateFolder)
        if (-not (Test-Path -LiteralPath $dated)) {
            New-Item -ItemType Directory -Path $dated -Force | Out-Null
        }
        if ($script:BaseExportDirectory -ne $fallbackBase) {
            Write-Host "Warning: Cannot write to '$base' – falling back to '$fallbackBase'" -ForegroundColor Yellow
            $script:BaseExportDirectory = $fallbackBase
        }
    }
    return $dated
}

function Initialize-AppLogging {
    <#
    .SYNOPSIS
        Initializes the logging system for The Powerful Intune Bulk Actions Tool.
    .DESCRIPTION
        Creates a log file in a date-based subfolder under the configured base directory
        (e.g. C:\Temp\20260315). Includes log rotation to keep the last N log files per day.
        This function should be called when the application starts.
    .PARAMETER LogDirectory
        Optional. Override the default base directory for this session (e.g. "D:\Logs").
        Files will be saved under a YYYYMMDD subfolder within this base directory.
    .PARAMETER MaxLogFiles
        Optional. Maximum number of log files to keep. Default is 5.
    .PARAMETER MaxLogSizeMB
        Optional. Maximum log file size in MB. Default is 10.
    .PARAMETER MinLogLevel
        Optional. Minimum log level to record. Default is DEBUG (all).
    #>
    param (
        [Parameter(Mandatory = $false)]
        [string]$LogDirectory = "",
        
        [Parameter(Mandatory = $false)]
        [int]$MaxLogFiles = 5,
        
        [Parameter(Mandatory = $false)]
        [int]$MaxLogSizeMB = 10,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR")]
        [string]$MinLogLevel = "DEBUG"
    )
    
    # Store the base directory (without date) so Get-ExportDirectory can append today's date
    if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
        # Caller specified a custom base directory
        $script:BaseExportDirectory = $LogDirectory
    } elseif ([string]::IsNullOrWhiteSpace($script:BaseExportDirectory)) {
        $script:BaseExportDirectory = "C:\Temp"
    }
    
    # Get today's dated working directory - created automatically by Get-ExportDirectory
    $LogDirectory = Get-ExportDirectory
    
    # Update the script-level settings
    $script:MaxLogFiles = $MaxLogFiles
    $script:MaxLogSizeMB = $MaxLogSizeMB
    $script:LogLevel = $MinLogLevel
    
    # Perform log rotation - clean up old log files
    try {
        $existingLogs = Get-ChildItem -Path $LogDirectory -Filter "IntuneTool_*.log" -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending
        
        if ($existingLogs.Count -ge $script:MaxLogFiles) {
            # Keep only the most recent (MaxLogFiles - 1) to make room for the new one
            $logsToDelete = $existingLogs | Select-Object -Skip ($script:MaxLogFiles - 1)
            foreach ($log in $logsToDelete) {
                Remove-Item -Path $log.FullName -Force -ErrorAction SilentlyContinue
                Write-Host "Removed old log file: $($log.Name)" -ForegroundColor DarkGray
            }
        }
    }
    catch {
        Write-Host "Warning: Could not perform log rotation: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    
    # Create log file with timestamp
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $script:LogFilePath = Join-Path $LogDirectory "IntuneTool_$timestamp.log"
    
    # Write initial log entry
    $header = @"
================================================================================
           THE POWERFUL INTUNE BULK ACTIONS TOOL - APPLICATION LOG
================================================================================
Log File Created: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Computer Name: $env:COMPUTERNAME
Username: $env:USERNAME
PowerShell Version: $($PSVersionTable.PSVersion)
Export Directory: $LogDirectory
Log Level: $MinLogLevel
Max Log Files: $MaxLogFiles
Max Log Size: ${MaxLogSizeMB}MB
================================================================================

"@
    
    $header | Out-File -FilePath $script:LogFilePath -Encoding UTF8
    
    Write-Host "Logging initialized. Log file: $script:LogFilePath" -ForegroundColor Green
    return $script:LogFilePath
}

function Write-AppLog {
    <#
    .SYNOPSIS
        Writes a log entry to the application log file.
    .PARAMETER Message
        The message to log.
    .PARAMETER Level
        The log level: INFO, WARNING, ERROR, ACTION, REPORT, DEBUG, USER
    .PARAMETER Details
        Optional additional details to include in the log entry.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("INFO", "WARNING", "ERROR", "ACTION", "REPORT", "DEBUG", "USER")]
        [string]$Level = "INFO",
        
        [Parameter(Mandatory = $false)]
        [string]$Details = ""
    )
    
    if ([string]::IsNullOrEmpty($script:LogFilePath)) {
        # Logging not initialized, skip
        return
    }
    
    # Check log level filtering - only log if level meets minimum threshold
    $messagePriority = $script:LogLevelPriority[$Level]
    $minPriority = $script:LogLevelPriority[$script:LogLevel]
    if ($null -eq $messagePriority) { $messagePriority = 1 }
    if ($null -eq $minPriority) { $minPriority = 0 }
    
    if ($messagePriority -lt $minPriority) {
        # Skip logging for levels below minimum threshold
        return
    }
    
    # Check log file size and rotate if needed
    try {
        if (Test-Path $script:LogFilePath) {
            $logFileSize = (Get-Item $script:LogFilePath).Length / 1MB
            if ($logFileSize -ge $script:MaxLogSizeMB) {
                # Rotate the log file
                $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
                $logDir = Split-Path $script:LogFilePath -Parent
                $newLogPath = Join-Path $logDir "IntuneTool_$timestamp.log"
                
                # Add rotation notice to current log
                "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [INFO] Log file size limit reached (${logFileSize:N2}MB). Rotating to new file..." | 
                    Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
                
                # Create new log file
                $script:LogFilePath = $newLogPath
                "================================================================================`r`n  THE POWERFUL INTUNE BULK ACTIONS TOOL - LOG CONTINUATION`r`n  Rotated from previous log at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`n================================================================================" |
                    Out-File -FilePath $script:LogFilePath -Encoding UTF8
                
                # Clean up old log files
                $existingLogs = Get-ChildItem -Path $logDir -Filter "IntuneTool_*.log" -File -ErrorAction SilentlyContinue |
                    Sort-Object LastWriteTime -Descending
                if ($existingLogs.Count -gt $script:MaxLogFiles) {
                    $logsToDelete = $existingLogs | Select-Object -Skip $script:MaxLogFiles
                    foreach ($log in $logsToDelete) {
                        Remove-Item -Path $log.FullName -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }
    }
    catch {
        # Silently continue if rotation fails
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $logEntry = "[$timestamp] [$Level] $Message"
    
    if (-not [string]::IsNullOrEmpty($Details)) {
        $logEntry += "`r`n                    Details: $Details"
    }
    
    # Append to log file
    try {
        $logEntry | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    }
    catch {
        Write-Host "Failed to write to log file: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Also output to console with color coding
    switch ($Level) {
        "ERROR"   { Write-Host $logEntry -ForegroundColor Red }
        "WARNING" { Write-Host $logEntry -ForegroundColor Yellow }
        "ACTION"  { Write-Host $logEntry -ForegroundColor Cyan }
        "REPORT"  { Write-Host $logEntry -ForegroundColor Magenta }
        "USER"    { Write-Host $logEntry -ForegroundColor Green }
        "DEBUG"   { Write-Host $logEntry -ForegroundColor Gray }
        default   { Write-Host $logEntry }
    }
}

function Write-AuditLog {
    <#
    .SYNOPSIS
        Writes a compliance/audit log entry for tracked operations.
    .DESCRIPTION
        Creates detailed audit log entries for compliance tracking including:
        - Timestamp
        - Current user context
        - Operation performed
        - Target devices/groups
        - Before and after states (for changes)
        - Result status
    .PARAMETER Operation
        The type of operation being audited (e.g., "DeviceRetire", "GroupImport", "DeviceDelete").
    .PARAMETER Target
        The target of the operation (device name, serial number, group name, etc.).
    .PARAMETER TargetType
        The type of target: Device, Group, User, Policy.
    .PARAMETER BeforeState
        Optional. The state before the operation (for change tracking).
    .PARAMETER AfterState
        Optional. The state after the operation (for change tracking).
    .PARAMETER Result
        The result of the operation: Success, Failed, Skipped, WhatIf.
    .PARAMETER Details
        Optional. Additional details about the operation.
    .PARAMETER ErrorMessage
        Optional. Error message if the operation failed.
    .EXAMPLE
        Write-AuditLog -Operation "DeviceRetire" -Target "PC001" -TargetType "Device" -Result "Success" -Details "Device retired from Intune"
    .EXAMPLE
        Write-AuditLog -Operation "GroupImport" -Target "PC001" -TargetType "Device" -BeforeState "Not in group" -AfterState "Member of 'All Devices'" -Result "Success"
    #>
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("DeviceRetire", "DeviceDelete", "GroupImport", "GroupRemove", "GroupClear", "AutopilotTagUpdate", "RecordDelete", "DeviceQuery", "GroupMembershipCheck", "Other")]
        [string]$Operation,
        
        [Parameter(Mandatory = $true)]
        [string]$Target,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Device", "Group", "User", "Policy", "Multiple")]
        [string]$TargetType = "Device",
        
        [Parameter(Mandatory = $false)]
        [string]$BeforeState = "",
        
        [Parameter(Mandatory = $false)]
        [string]$AfterState = "",
        
        [Parameter(Mandatory = $true)]
        [ValidateSet("Success", "Failed", "Skipped", "WhatIf", "PartialSuccess", "InProgress")]
        [string]$Result,
        
        [Parameter(Mandatory = $false)]
        [string]$Details = "",
        
        [Parameter(Mandatory = $false)]
        [string]$ErrorMessage = ""
    )
    
    if ([string]::IsNullOrEmpty($script:LogFilePath)) {
        return
    }
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $utcTimestamp = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
    
    # Build the audit entry using ASCII-safe characters
    $line = "+" + ("-" * 77) + "+"
    $auditEntry = @"

$line
| AUDIT LOG ENTRY                                                             |
$line
| Timestamp (Local): $timestamp
| Timestamp (UTC):   $utcTimestamp
| Computer:          $env:COMPUTERNAME
| User:              $env:USERDOMAIN\$env:USERNAME
| Operation:         $Operation
| Target Type:       $TargetType
| Target:            $Target
| Result:            $Result
"@

    if (-not [string]::IsNullOrEmpty($BeforeState)) {
        $auditEntry += "`n| Before State:      $BeforeState"
    }
    
    if (-not [string]::IsNullOrEmpty($AfterState)) {
        $auditEntry += "`n| After State:       $AfterState"
    }
    
    if (-not [string]::IsNullOrEmpty($Details)) {
        $auditEntry += "`n| Details:           $Details"
    }
    
    if (-not [string]::IsNullOrEmpty($ErrorMessage)) {
        $auditEntry += "`n| Error:             $ErrorMessage"
    }
    
    $auditEntry += "`n$line"
    
    # Write to log file
    try {
        $auditEntry | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    }
    catch {
        Write-Host "Failed to write audit log: $($_.Exception.Message)" -ForegroundColor Red
    }
    
    # Console output with color based on result
    $color = switch ($Result) {
        "Success"        { "Green" }
        "PartialSuccess" { "Yellow" }
        "Failed"         { "Red" }
        "WhatIf"         { "Cyan" }
        "Skipped"        { "DarkGray" }
        default          { "White" }
    }
    
    Write-Host "[AUDIT] $Operation on $TargetType - $Target - $Result" -ForegroundColor $color
}

function Format-ActionableError {
    <#
    .SYNOPSIS
        Creates a user-friendly, actionable error message.
    .DESCRIPTION
        Takes an error context and returns a formatted error message with:
        - Clear description of what went wrong
        - Specific identifier that caused the issue
        - Suggested actions to resolve the issue
    .PARAMETER ErrorType
        The type of error that occurred.
    .PARAMETER Identifier
        The device/group/user identifier involved.
    .PARAMETER IdentifierType
        The type of identifier (e.g., "Device Name", "Serial Number", "Group ID").
    .PARAMETER OriginalError
        Optional. The original exception message for technical details.
    .PARAMETER Operation
        The operation that was being performed when the error occurred.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("DeviceNotFound", "GroupNotFound", "PermissionDenied", "RateLimited", "NetworkError", "InvalidInput", "APIError", "NotEnrolled", "AlreadyExists", "Timeout", "Unknown")]
        [string]$ErrorType,
        
        [Parameter(Mandatory = $false)]
        [string]$Identifier = "",
        
        [Parameter(Mandatory = $false)]
        [string]$IdentifierType = "Device",
        
        [Parameter(Mandatory = $false)]
        [string]$OriginalError = "",
        
        [Parameter(Mandatory = $false)]
        [string]$Operation = ""
    )
    
    $message = switch ($ErrorType) {
        "DeviceNotFound" {
            $msg = if ([string]::IsNullOrEmpty($Identifier)) {
                "Device not found in Intune."
            } else {
                "$IdentifierType [$Identifier] not found in Intune."
            }
            $msg += "`n`nSuggested actions:`n- Verify the device is enrolled in Intune`n- Check the $IdentifierType for typos`n- Ensure the device has not been deleted"
            $msg
        }
        "GroupNotFound" {
            $msg = if ([string]::IsNullOrEmpty($Identifier)) {
                "Group not found in Entra ID."
            } else {
                "Group [$Identifier] not found in Entra ID."
            }
            $msg += "`n`nSuggested actions:`n- Verify the group name or ID is correct`n- Check if the group was recently deleted`n- Ensure you have permission to view the group"
            $msg
        }
        "PermissionDenied" {
            "Permission denied for this operation.`n`nSuggested actions:`n- Verify your account has the required permissions`n- Check if the resource requires additional admin consent`n- Try reconnecting with elevated permissions"
        }
        "RateLimited" {
            "API rate limit reached. The system will automatically retry.`n`nSuggested actions:`n- Wait a few minutes before retrying`n- Reduce the number of devices in batch operations`n- Try again during off-peak hours"
        }
        "NetworkError" {
            "Network connection error occurred.`n`nSuggested actions:`n- Check your internet connection`n- Verify firewall settings allow Graph API access`n- Try disconnecting and reconnecting"
        }
        "InvalidInput" {
            $msg = "Invalid input provided"
            if (-not [string]::IsNullOrEmpty($Identifier)) {
                $msg += ": [$Identifier]"
            }
            $msg += ".`n`nSuggested actions:`n- Check the input format is correct`n- Remove special characters if present`n- Verify the file format for bulk operations"
            $msg
        }
        "APIError" {
            $msg = "An error occurred communicating with Microsoft Graph API."
            if (-not [string]::IsNullOrEmpty($OriginalError)) {
                $msg += "`n`nTechnical details: $OriginalError"
            }
            $msg += "`n`nSuggested actions:`n- Try the operation again`n- Check Microsoft 365 service health`n- Verify your authentication is still valid"
            $msg
        }
        "NotEnrolled" {
            "Device [$Identifier] exists in Entra ID but is not enrolled in Intune.`n`nSuggested actions:`n- Verify this is the correct device`n- Check the device enrollment status in Intune portal`n- Re-enroll the device if needed"
        }
        "AlreadyExists" {
            "The operation could not be completed because the resource already exists.`n`nSuggested actions:`n- Verify if the device is already a member of the group`n- Check for duplicate entries"
        }
        "Timeout" {
            "The operation timed out while waiting for a response.`n`nSuggested actions:`n- Try the operation again`n- Reduce the batch size for bulk operations`n- Check network connectivity"
        }
        default {
            $msg = "An unexpected error occurred"
            if (-not [string]::IsNullOrEmpty($Operation)) {
                $msg += " during [$Operation]"
            }
            $msg += "."
            if (-not [string]::IsNullOrEmpty($OriginalError)) {
                $msg += "`n`nTechnical details: $OriginalError"
            }
            $msg
        }
    }
    
    return $message
}

function Write-AppLogSection {
    <#
    .SYNOPSIS
        Writes a section header/separator to the log file.
    .PARAMETER Title
        The title of the section.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Title
    )
    
    if ([string]::IsNullOrEmpty($script:LogFilePath)) {
        return
    }
    
    $separator = @"

--------------------------------------------------------------------------------
  $Title - $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
--------------------------------------------------------------------------------
"@
    
    try {
        $separator | Out-File -FilePath $script:LogFilePath -Append -Encoding UTF8
    }
    catch {
        Write-Host "Failed to write section to log file: $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Write-AppLogDeviceList {
    <#
    .SYNOPSIS
        Logs a list of devices that were processed.
    .PARAMETER DeviceIDs
        Array of device IDs that were processed.
    .PARAMETER Action
        The action that was performed on the devices.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [array]$DeviceIDs,
        
        [Parameter(Mandatory = $true)]
        [string]$Action
    )
    
    Write-AppLog -Message "Devices processed for action: $Action" -Level "INFO" -Details "Count: $($DeviceIDs.Count)"
    
    $deviceList = $DeviceIDs -join ", "
    if ($deviceList.Length -gt 500) {
        $deviceList = $deviceList.Substring(0, 500) + "... [truncated]"
    }
    Write-AppLog -Message "Device IDs: $deviceList" -Level "DEBUG"
}

function Write-AppLogResults {
    <#
    .SYNOPSIS
        Logs the results of an action or report.
    .PARAMETER Results
        Hashtable containing the results data.
    .PARAMETER Operation
        The name of the operation that was performed.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [Hashtable]$Results,
        
        [Parameter(Mandatory = $true)]
        [string]$Operation
    )
    
    $totalCount = 0
    if ($Results.ContainsKey("Status")) {
        $totalCount = $Results["Status"].Count
    }
    elseif ($Results.ContainsKey("DeviceID")) {
        $totalCount = $Results["DeviceID"].Count
    }
    elseif ($Results.Keys.Count -gt 0) {
        $firstKey = $Results.Keys | Select-Object -First 1
        $totalCount = $Results[$firstKey].Count
    }
    
    Write-AppLog -Message "Operation '$Operation' completed" -Level "INFO" -Details "Total results: $totalCount"
    
    # Log status breakdown if available
    if ($Results.ContainsKey("Status")) {
        $statusCounts = $Results["Status"] | Group-Object | ForEach-Object { "$($_.Name): $($_.Count)" }
        Write-AppLog -Message "Status breakdown: $($statusCounts -join ', ')" -Level "INFO"
    }
}

function Get-AppLogPath {
    <#
    .SYNOPSIS
        Returns the current log file path.
    #>
    return $script:LogFilePath
}

function Set-LogLevel {
    <#
    .SYNOPSIS
        Sets the minimum log level for filtering log entries.
    .PARAMETER Level
        The minimum log level: DEBUG, INFO, WARNING, ERROR
    #>
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR")]
        [string]$Level
    )
    
    $script:LogLevel = $Level
    Write-AppLog -Message "Log level changed to: $Level" -Level "INFO"
}

function Get-LogLevel {
    <#
    .SYNOPSIS
        Gets the current minimum log level.
    #>
    return $script:LogLevel
}

function Measure-Operation {
    <#
    .SYNOPSIS
        Executes a script block and logs the execution time.
    .DESCRIPTION
        Wraps a script block execution with timing and logging for performance tracking.
    .PARAMETER Name
        The name of the operation being measured.
    .PARAMETER ScriptBlock
        The script block to execute and measure.
    .PARAMETER LogLevel
        The log level for the timing message. Default is DEBUG.
    .OUTPUTS
        Returns the output of the script block.
    .EXAMPLE
        $result = Measure-Operation -Name "Get Device Info" -ScriptBlock { Get-IntuneDeviceInfo -IsSingleDevice $true -IDorFilePath "device123" }
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,
        
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR", "ACTION", "REPORT", "USER")]
        [string]$LogLevel = "DEBUG"
    )
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    try {
        $result = & $ScriptBlock
        $stopwatch.Stop()
        
        $elapsed = $stopwatch.Elapsed
        $timeStr = if ($elapsed.TotalSeconds -ge 60) {
            "{0:N0}m {1:N1}s" -f [Math]::Floor($elapsed.TotalMinutes), ($elapsed.TotalSeconds % 60)
        } elseif ($elapsed.TotalSeconds -ge 1) {
            "{0:N2}s" -f $elapsed.TotalSeconds
        } else {
            "{0:N0}ms" -f $elapsed.TotalMilliseconds
        }
        
        Write-AppLog -Message "Operation '$Name' completed" -Level $LogLevel -Details "Duration: $timeStr"
        
        return $result
    }
    catch {
        $stopwatch.Stop()
        Write-AppLog -Message "Operation '$Name' failed" -Level "ERROR" -Details "Duration: $($stopwatch.Elapsed.TotalSeconds)s, Error: $($_.Exception.Message)"
        throw
    }
}
#endregion

#region ==================== VALIDATION HELPERS ====================

function Test-FileInputValidation {
    <#
    .SYNOPSIS
        Validates a file path input and shows appropriate error messages.
    .DESCRIPTION
        Performs common validation checks on file path inputs:
        - Checks if the path is empty/whitespace
        - Checks if the file exists
        - Logs validation failures
        - Shows MessageBox with appropriate error message
    .PARAMETER FilePath
        The file path to validate.
    .PARAMETER FieldName
        The name of the field for display in error messages (e.g., "device list file").
    .PARAMETER ShowMessageBox
        Whether to show a MessageBox on validation failure. Default is $true.
    .OUTPUTS
        Returns $true if valid, $false if invalid.
    .EXAMPLE
        if (-not (Test-FileInputValidation -FilePath $path -FieldName "device list file")) { return }
    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$FilePath,
        
        [Parameter(Mandatory = $false)]
        [string]$FieldName = "file",
        
        [Parameter(Mandatory = $false)]
        [bool]$ShowMessageBox = $true
    )
    
    # Check if path is empty
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        Write-AppLog -Message "Validation failed: No file path specified" -Level "WARNING" -Details "Field: $FieldName"
        if ($ShowMessageBox) {
            [System.Windows.MessageBox]::Show(
                "Please enter the path to the $FieldName.",
                "Validation Error",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Warning
            ) | Out-Null
        }
        return $false
    }
    
    # Check if file exists
    if (-not (Test-Path $FilePath)) {
        Write-AppLog -Message "Validation failed: File not found" -Level "ERROR" -Details "Path: $FilePath"
        if ($ShowMessageBox) {
            [System.Windows.MessageBox]::Show(
                "File not found: $FilePath`n`nPlease verify the path is correct.",
                "File Not Found",
                [System.Windows.MessageBoxButton]::OK,
                [System.Windows.MessageBoxImage]::Error
            ) | Out-Null
        }
        return $false
    }
    
    return $true
}

function Get-IdentifierType {
    <#
    .SYNOPSIS
        Detects whether an identifier is a GUID (Object ID) or a display name.
    .DESCRIPTION
        Uses regex pattern matching to determine if the input is a GUID format
        (for Group Object IDs, Device IDs, etc.) or a plain text name.
    .PARAMETER Identifier
        The identifier string to analyze.
    .PARAMETER GuidTypeName
        The name to return if the identifier is a GUID. Default is "Group Object ID".
    .PARAMETER NameTypeName
        The name to return if the identifier is a name. Default is "Group Name".
    .OUTPUTS
        Returns the appropriate type name string.
    .EXAMPLE
        $type = Get-IdentifierType -Identifier $groupInput
        # Returns "Group Object ID" or "Group Name"
    .EXAMPLE
        $type = Get-IdentifierType -Identifier $input -GuidTypeName "Device ID" -NameTypeName "Device Name"
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Identifier,
        
        [Parameter(Mandatory = $false)]
        [string]$GuidTypeName = "Group Object ID",
        
        [Parameter(Mandatory = $false)]
        [string]$NameTypeName = "Group Name"
    )
    
    # GUID pattern: 8-4-4-4-12 hex characters, optionally wrapped in braces
    $guidPattern = '^[{]?[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}[}]?$'
    
    if ($Identifier -match $guidPattern) {
        return $GuidTypeName
    }
    return $NameTypeName
}

function Get-ResultSummary {
    <#
    .SYNOPSIS
        Generates a summary of operation results from a results hashtable.
    .DESCRIPTION
        Counts occurrences of different status values in the results and returns
        a summary object with counts for each status type.
    .PARAMETER Results
        The results hashtable containing a "Status" key with status values.
    .PARAMETER StatusKey
        The key name containing status values. Default is "Status".
    .OUTPUTS
        Returns a hashtable with counts for Success, Error, NotFound, Skipped, and Total.
    .EXAMPLE
        $summary = Get-ResultSummary -Results $returnedData
        Write-Host "Success: $($summary.Success), Errors: $($summary.Error)"
    #>
    param (
        [Parameter(Mandatory = $true)]
        [Hashtable]$Results,
        
        [Parameter(Mandatory = $false)]
        [string]$StatusKey = "Status"
    )
    
    $summary = @{
        Success = 0
        Error = 0
        NotFound = 0
        Skipped = 0
        AlreadyMember = 0
        NotAMember = 0
        Total = 0
    }
    
    if (-not $Results.ContainsKey($StatusKey)) {
        return $summary
    }
    
    $statuses = $Results[$StatusKey]
    $summary.Total = $statuses.Count
    
    foreach ($status in $statuses) {
        switch -Wildcard ($status) {
            "Success*"       { $summary.Success++ }
            "Added*"         { $summary.Success++ }
            "Removed*"       { $summary.Success++ }
            "Retired*"       { $summary.Success++ }
            "Updated*"       { $summary.Success++ }
            "Error*"         { $summary.Error++ }
            "Failed*"        { $summary.Error++ }
            "Not Found*"     { $summary.NotFound++ }
            "Skipped*"       { $summary.Skipped++ }
            "Cancelled*"     { $summary.Skipped++ }
            "Already Member*" { $summary.AlreadyMember++ }
            "Not a Member*"  { $summary.NotAMember++ }
            "*WhatIf*"       { $summary.Skipped++ }
        }
    }
    
    return $summary
}

#endregion ==================== VALIDATION HELPERS ====================

function UnhideItems {
    <#
    .SYNOPSIS
        Makes UI elements visible.
    .PARAMETER ItemNames
        Array of element names to make visible.
    .PARAMETER Form
        Optional. The form object to search for items. If not provided, uses global $Form variable.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$ItemNames,
        
        [Parameter(Mandatory = $false)]
        [System.Windows.Window]$Form = $null
    )
    
    # Use provided form or fall back to global $Form
    $targetForm = if ($null -ne $Form) { $Form } else { $script:Form }
    if ($null -eq $targetForm) {
        $targetForm = Get-Variable -Name Form -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    }

    foreach ($itemName in $ItemNames) {
        # Retrieve the item object by name
        $item = $targetForm.FindName($itemName)

        if ($null -ne $item) {
            # Set the visibility of the item to Visible
            $item.Visibility = "Visible"
        } else {
            Write-Host "UnhideItems: Item '$itemName' not found." -ForegroundColor Yellow
        }
    }
}

function HideItems {
    <#
    .SYNOPSIS
        Hides UI elements.
    .PARAMETER ItemNames
        Array of element names to hide.
    .PARAMETER Form
        Optional. The form object to search for items. If not provided, uses global $Form variable.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$ItemNames,
        
        [Parameter(Mandatory = $false)]
        [System.Windows.Window]$Form = $null
    )
    
    # Use provided form or fall back to global $Form
    $targetForm = if ($null -ne $Form) { $Form } else { $script:Form }
    if ($null -eq $targetForm) {
        $targetForm = Get-Variable -Name Form -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    }

    foreach ($itemName in $ItemNames) {
        # Retrieve the item object by name
        $item = $targetForm.FindName($itemName)

        # Check if the item exists to avoid null reference exceptions
        if ($null -ne $item) {
            # Set the visibility of the item to Collapsed to hide it from the UI
            $item.Visibility = "Collapsed"
        } else {
            Write-Host "HideItems: Item '$itemName' not found." -ForegroundColor Yellow
        }
    }
}


function FillDataListView {
    param(
        # Declare the parameters that the function accepts. All are marked as mandatory, so they must be provided.
        [Parameter(Mandatory=$true)]
        [System.Windows.Controls.ListView]$ListView, # The ListView control that will be populated with data.

        [Parameter(Mandatory=$true)]
        [array]$Headers, # An array of strings where each item represents a column header in the ListView.

        [Parameter(Mandatory=$true)]
        [Hashtable]$Data # A hashtable where each key matches a header and the value is the data for that column.
    )

    # Clears all current items from the ListView to start fresh.
    $ListView.Items.Clear()
    # Creates a new GridView object and assigns it to the ListView to define how items should be displayed.
    $ListView.View = New-Object System.Windows.Controls.GridView

    # Loop through each header to create a corresponding column in the ListView.
    foreach ($header in $Headers) {
        # Create a new GridViewColumn object for each header.
        $column = New-Object System.Windows.Controls.GridViewColumn
        # Set the text of the column header.
        $column.Header = $header
        # Bind the column to display data from the hashtable based on the header name.
        $column.DisplayMemberBinding = New-Object System.Windows.Data.Binding $header
        # Add the newly created column to the ListView's GridView.
        $ListView.View.Columns.Add($column)
    }

    # Determine the number of rows to be added to the ListView.
    $maxRows = 0
    # Iterate over each key in the hashtable to find the maximum number of values (rows).
    foreach ($key in $Data.Keys) {
        # If the current key's value count is greater than the current $maxRows, update $maxRows.
        if ($Data[$key].Count -gt $maxRows) {
            $maxRows = $Data[$key].Count
        }
    }

    # Loop through each row index based on the $maxRows determined.
    for ($rowIndex = 0; $rowIndex -lt $maxRows; $rowIndex++) {
        # Create a new PSObject that will represent a row in the ListView.
        $item = New-Object PSObject
        # Loop over each header and assign the corresponding data to the row object.
        foreach ($header in $Headers) {
            # Retrieve the current header's data from the hashtable.
            $currentData = $Data[$header]
            # Ensure that the data is treated as an array even if it's a single value.
            if ($currentData -isnot [array]) {
                $currentData = @($currentData)
            }
            # Assign the value to the current cell in the row; if it's not available, assign null.
            $value = if ($currentData.Count -gt $rowIndex) { $currentData[$rowIndex] } else { $null }
            # Add the value to the row object as a property named after the header.
            $item | Add-Member -MemberType NoteProperty -Name $header -Value $value
        }
        # Add the fully populated row object to the ListView.
        $ListView.Items.Add($item)
    }
    
    # Add keyboard handler for Ctrl+C to copy selected items
    $ListView.Add_KeyDown({
        param($ctrl, $e)
        if ($e.Key -eq [System.Windows.Input.Key]::C -and $e.KeyboardDevice.Modifiers -eq [System.Windows.Input.ModifierKeys]::Control) {
            $selectedItems = $ctrl.SelectedItems
            if ($selectedItems.Count -gt 0) {
                $textToCopy = ""
                foreach ($item in $selectedItems) {
                    $rowText = ""
                    foreach ($prop in $item.PSObject.Properties) {
                        $rowText += "$($prop.Value)`t"
                    }
                    $textToCopy += $rowText.TrimEnd("`t") + "`r`n"
                }
                [System.Windows.Clipboard]::SetText($textToCopy.TrimEnd("`r`n"))
                Write-AppLog -Message "Copied $($selectedItems.Count) row(s) to clipboard" -Level "DEBUG"
            }
        }
    })
    
    # Log summary of ListView population
    Write-AppLog -Message "ListView populated" -Level "DEBUG" -Details "Columns: $($Headers.Count), Rows: $maxRows"
}

function Export-ListViewToCsv {
    <#
    .SYNOPSIS
        Exports the contents of a ListView to a CSV file.
    .DESCRIPTION
        Exports all items from a ListView control to a CSV file in the configured
        export directory. Creates the file with a timestamp in the filename.
    .PARAMETER ListView
        The ListView control to export from.
    .PARAMETER ExportName
        A descriptive name for the export (used in the filename).
    .OUTPUTS
        Returns the path to the created CSV file, or $null if export failed.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [System.Windows.Controls.ListView]$ListView,
        
        [Parameter(Mandatory = $false)]
        [string]$ExportName = "Export"
    )
    
    try {
        # Check if ListView has items
        if ($ListView.Items.Count -eq 0) {
            Write-AppLog -Message "Cannot export: ListView is empty" -Level "WARNING"
            [System.Windows.MessageBox]::Show("No data to export. Please run a report first.", "Export Warning", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
            return $null
        }
        
        # Build export path
        $exportDir = Get-ExportDirectory
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $safeExportName = $ExportName -replace '[^\w\-]', '_'
        $exportPath = Join-Path $exportDir "IntuneTool_${safeExportName}_$timestamp.csv"
        
        # Collect data from ListView
        $exportData = @()
        foreach ($item in $ListView.Items) {
            $exportData += $item
        }
        
        # Export to CSV
        $exportData | Export-Csv -Path $exportPath -NoTypeInformation -Encoding UTF8
        
        Write-AppLog -Message "Data exported to CSV" -Level "INFO" -Details "Path: $exportPath, Rows: $($exportData.Count)"
        
        # Show success message with option to open folder
        $result = [System.Windows.MessageBox]::Show(
            "Data exported successfully to:`r`n$exportPath`r`n`r`nWould you like to open the folder?",
            "Export Complete",
            [System.Windows.MessageBoxButton]::YesNo,
            [System.Windows.MessageBoxImage]::Information
        )
        
        if ($result -eq [System.Windows.MessageBoxResult]::Yes) {
            Start-Process "explorer.exe" -ArgumentList "/select,`"$exportPath`""
        }
        
        return $exportPath
    }
    catch {
        Write-AppLog -Message "Failed to export data to CSV" -Level "ERROR" -Details $_.Exception.Message
        [System.Windows.MessageBox]::Show("Failed to export data: $($_.Exception.Message)", "Export Error", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Error)
        return $null
    }
}

#region ==================== DEVICE RENAME FUNCTIONS ====================

function Get-IntuneDevicesForRename {
    <#
    .SYNOPSIS
        Fetches Intune managed devices with optional filtering for rename operations.
    .DESCRIPTION
        Retrieves devices from Intune with optional filtering by platform and ownership type.
        Used by the Bulk Rename Devices feature.
    .PARAMETER FilterPlatform
        Optional platform filter (Windows, Android, iOS, macOS, or All).
    .PARAMETER CorporateOnly
        If specified, only corporate-owned devices are returned.
    .OUTPUTS
        Array of managed device objects from Microsoft Graph.
    #>
    param(
        [string]$FilterPlatform,
        [switch]$CorporateOnly
    )

    try {
        Write-AppLog -Message "Fetching devices from Intune..." -Level "INFO"
        $filterClauses = @()
        if ($CorporateOnly) {
            $filterClauses += "managedDeviceOwnerType eq 'Company'"
        }

        if (-not [string]::IsNullOrEmpty($FilterPlatform) -and $FilterPlatform -ne 'All') {
            # Adjust platform names for Graph API filter syntax
            $graphPlatform = switch ($FilterPlatform) {
                'Windows' { 'Windows' }
                'Android' { 'Android' }
                'iOS'     { 'iOS' }
                'macOS'   { 'macOS' }
                Default   { $FilterPlatform }
            }
            $filterClauses += "operatingSystem eq '$graphPlatform'"
        }

        $filterQuery = $filterClauses -join ' and '
        
        if ([string]::IsNullOrEmpty($filterQuery)) {
            Write-AppLog -Message "No filters applied. Getting all devices." -Level "INFO"
            $devices = Get-MgDeviceManagementManagedDevice -All
        }
        else {
            Write-AppLog -Message "Applying filter: $filterQuery" -Level "INFO"
            $devices = Get-MgDeviceManagementManagedDevice -All -Filter $filterQuery
        }
        
        Write-AppLog -Message "Found $($devices.Count) devices matching filter criteria." -Level "INFO"
        return $devices
    }
    catch {
        Write-AppLog -Message "Failed to get devices from Intune. Error: $($_.Exception.Message)" -Level "ERROR"
        return $null
    }
}

function Set-IntuneDeviceName {
    <#
    .SYNOPSIS
        Renames an Intune managed device.
    .DESCRIPTION
        Uses the Microsoft Graph beta API to set a new device name for a managed device.
    .PARAMETER IntuneDeviceID
        The Intune device ID (GUID) of the device to rename.
    .PARAMETER NewDeviceName
        The new name to assign to the device.
    .OUTPUTS
        Returns $true on success, $false on failure.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$IntuneDeviceID,
        [Parameter(Mandatory = $true)]
        [string]$NewDeviceName
    )

    $resource = "deviceManagement/managedDevices('$IntuneDeviceID')/setDeviceName"
    $GraphApiVersion = "beta"
    $URI = "https://graph.microsoft.com/$GraphApiVersion/$resource"

    $JsonPayload = @"
{
  "deviceName": "$NewDeviceName"
}
"@

    try {
        Invoke-MgGraphRequest -Method POST -Uri $URI -Body $JsonPayload -ErrorAction Stop
        return $true
    }
    catch {
        # Capture the specific error message from the Graph API response
        $errorMessage = $_.ErrorDetails.Message | ConvertFrom-Json | Select-Object -ExpandProperty error | Select-Object -ExpandProperty message
        if ([string]::IsNullOrEmpty($errorMessage)) {
            $errorMessage = $_.Exception.Message
        }
        Write-AppLog -Message "Failed to rename device ID $IntuneDeviceID. Reason: $errorMessage" -Level "ERROR"
        return $false
    }
}

#endregion ==================== DEVICE RENAME FUNCTIONS ====================

#region ==================== MODULE EXPORTS ====================
# Explicitly export public functions
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

# Note: The following functions are currently unused but kept for potential future use:
# - Write-AppLogDeviceList: For logging device lists (not called anywhere)
# - Measure-Operation: For timing operations (not called anywhere)
# - New-ErrorResult: For creating error result objects (not called anywhere)
# - Set-LogLevel / Get-LogLevel: For log level control (not implemented)
#endregion ==================== MODULE EXPORTS ====================
