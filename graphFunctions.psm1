
function Test-MGGraphConnection{
    $currentConnection = Get-MgContext
    Write-AppLog -Message "Checking Graph connection status" -Level "DEBUG" -Details "Current session: $currentConnection"
    if ($null -eq $currentConnection){
        return $false
    }
    else{
        return $true
    }
}

# Required Microsoft Graph scopes for full functionality
$script:RequiredGraphScopes = @(
    "DeviceManagementManagedDevices.Read.All",      # Device info, encryption status, logged-on users
    "DeviceManagementConfiguration.Read.All",       # Configuration policies, settings catalog, compliance, remediation scripts
    "DeviceManagementApps.Read.All",                # Mobile apps, app protection policies, app configuration
    "DeviceManagementScripts.Read.All",             # PowerShell scripts and their assignments
    "Group.Read.All",                                # Group information for group assignment searches
    "DeviceManagementServiceConfig.Read.All",       # Endpoint security policies, Autopilot
    "Device.Read.All",                               # Device information for group import
    "GroupMember.ReadWrite.All",                     # Add/remove devices from groups
    "DeviceManagementManagedDevices.ReadWrite.All"  # Retire devices, Autopilot group tag updates
)

function Connect-ToMGGraph {
    Write-AppLog -Message "Checking if Graph connection already active" -Level "DEBUG"
    $isAlreadyConnected = Test-MGGraphConnection
    Write-AppLog -Message "Attempting to connect to MS Graph" -Level "DEBUG"
    try {
        if ($isAlreadyConnected){
            return $true
        }
        else{
            Connect-MgGraph -Scopes $script:RequiredGraphScopes
            return $true
        }
        
    } catch {
        Write-Error "An error occurred: $_. Exception message: $($_.Exception.Message)"
    }
}

<#
.SYNOPSIS
    Validates that the current Graph connection has required permissions for an operation.
.DESCRIPTION
    Checks if the current Microsoft Graph context has the necessary scopes/permissions
    for the specified operation type.
.PARAMETER OperationType
    The type of operation: "Report" or "Action"
.PARAMETER SpecificOperation
    Optional. The specific operation name to check for specialized permissions.
.RETURNS
    Hashtable with IsValid (bool), MissingScopes (array), and Message (string)
.EXAMPLE
    $validation = Test-GraphPermissions -OperationType "Action"
    if (-not $validation.IsValid) { Write-Warning $validation.Message }
#>
function Test-GraphPermissions {
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("Report", "Action")]
        [string]$OperationType,
        [Parameter(Mandatory = $false)]
        [string]$SpecificOperation = ""
    )
    
    $context = Get-MgContext
    
    if ($null -eq $context) {
        return @{
            IsValid = $false
            MissingScopes = @("Not connected")
            Message = "Not connected to Microsoft Graph. Please sign in first."
        }
    }
    
    $currentScopes = $context.Scopes
    $requiredScopes = @()
    
    # Base required scopes for all operations
    $baseScopes = @(
        "DeviceManagementManagedDevices.Read.All"
    )
    
    # Additional scopes for reports
    $reportScopes = @(
        "DeviceManagementConfiguration.Read.All",
        "Group.Read.All"
    )
    
    # Additional scopes for actions (write operations)
    $actionScopes = @(
        "DeviceManagementManagedDevices.ReadWrite.All",
        "GroupMember.ReadWrite.All",
        "Device.Read.All"
    )
    
    switch ($OperationType) {
        "Report" {
            $requiredScopes = $baseScopes + $reportScopes
        }
        "Action" {
            $requiredScopes = $baseScopes + $actionScopes
        }
    }
    
    # Check for missing scopes
    $missingScopes = @()
    foreach ($scope in $requiredScopes) {
        # Check if scope or a broader scope is present (e.g., .ReadWrite includes .Read)
        $scopeFound = $false
        foreach ($currentScope in $currentScopes) {
            if ($currentScope -like "*$($scope.Split('.')[0])*") {
                $scopeFound = $true
                break
            }
        }
        if (-not $scopeFound) {
            $missingScopes += $scope
        }
    }
    
    if ($missingScopes.Count -gt 0) {
        return @{
            IsValid = $false
            MissingScopes = $missingScopes
            Message = "Missing required permissions: $($missingScopes -join ', '). Please reconnect with appropriate scopes."
        }
    }
    
    return @{
        IsValid = $true
        MissingScopes = @()
        Message = "All required permissions are present."
    }
}

#region ==================== HELPER FUNCTIONS ====================

#region ===== INPUT SANITIZATION =====

<#
.SYNOPSIS
    Sanitizes a string for use in OData filter queries to prevent injection attacks.
.DESCRIPTION
    Escapes special characters that could be used for OData injection attacks.
    This includes single quotes (which must be doubled in OData), and removes
    or escapes other potentially dangerous characters.
.PARAMETER InputString
    The raw user input string to sanitize.
.EXAMPLE
    $safeValue = ConvertTo-SafeFilterString -InputString "Device's Name"
    # Returns: Device''s Name
.EXAMPLE
    $filter = "deviceName eq '$(ConvertTo-SafeFilterString -InputString $userInput)'"
#>
function ConvertTo-SafeFilterString {
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$InputString
    )
    
    if ([string]::IsNullOrEmpty($InputString)) {
        return $InputString
    }
    
    # Trim whitespace
    $sanitized = $InputString.Trim()
    
    # Escape single quotes by doubling them (OData standard)
    $sanitized = $sanitized -replace "'", "''"
    
    # Remove potentially dangerous characters that shouldn't appear in device names/serials
    # Keep alphanumeric, spaces, hyphens, underscores, periods, and common punctuation
    # Remove: semicolons, parentheses, brackets, and other OData operators
    $sanitized = $sanitized -replace '[;()\[\]{}]', ''
    
    # Remove any control characters
    $sanitized = $sanitized -replace '[\x00-\x1F\x7F]', ''
    
    return $sanitized
}

#endregion ===== INPUT SANITIZATION =====

#region ===== ERROR HANDLING HELPERS =====

<#
.SYNOPSIS
    Creates a structured error result hashtable for consistent error reporting.
.DESCRIPTION
    Returns a standardized error hashtable that can be used across all functions
    for consistent error reporting. Includes device/item identifier, error message,
    error type, and timestamp.
.PARAMETER Identifier
    The device/user/item identifier that caused the error.
.PARAMETER ErrorMessage
    The error message to include.
.PARAMETER ErrorType
    The type/category of error (e.g., "NotFound", "APIError", "ValidationError").
.PARAMETER ResultKeys
    Optional. Array of keys to populate with "N/A" or error values. If provided,
    returns a hashtable matching the expected result structure.
.EXAMPLE
    $error = New-ErrorResult -Identifier "ABC123" -ErrorMessage "Device not found" -ErrorType "NotFound"
#>
function New-ErrorResult {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Identifier,
        [Parameter(Mandatory = $true)]
        [string]$ErrorMessage,
        [Parameter(Mandatory = $false)]
        [string]$ErrorType = "Error",
        [Parameter(Mandatory = $false)]
        [string[]]$ResultKeys = @()
    )
    
    $errorResult = @{
        IsError = $true
        Identifier = $Identifier
        ErrorType = $ErrorType
        ErrorMessage = $ErrorMessage
        Timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    }
    
    # If result keys provided, add them with N/A values for structured output
    if ($ResultKeys.Count -gt 0) {
        foreach ($key in $ResultKeys) {
            if (-not $errorResult.ContainsKey($key)) {
                $errorResult[$key] = "N/A"
            }
        }
    }
    
    return $errorResult
}

<#
.SYNOPSIS
    Invokes a Microsoft Graph API request with automatic retry on throttling.
.DESCRIPTION
    Wraps Invoke-MgGraphRequest with exponential backoff retry logic for handling
    429 (Too Many Requests) throttling errors. Also handles transient errors.
.PARAMETER Uri
    The Graph API URI to call.
.PARAMETER Method
    The HTTP method (GET, POST, PATCH, DELETE). Defaults to GET.
.PARAMETER Body
    Optional. The request body for POST/PATCH requests.
.PARAMETER ContentType
    The content type header. Defaults to "application/json".
.PARAMETER MaxRetries
    Maximum number of retry attempts. Defaults to 3.
.PARAMETER InitialDelaySeconds
    Initial delay in seconds before first retry. Defaults to 2.
.EXAMPLE
    $response = Invoke-GraphRequestWithRetry -Uri "https://graph.microsoft.com/v1.0/me" -Method GET
.EXAMPLE
    $response = Invoke-GraphRequestWithRetry -Uri $uri -Method POST -Body $jsonBody
#>
function Invoke-GraphRequestWithRetry {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $false)]
        [ValidateSet("GET", "POST", "PATCH", "DELETE", "PUT")]
        [string]$Method = "GET",
        [Parameter(Mandatory = $false)]
        [object]$Body = $null,
        [Parameter(Mandatory = $false)]
        [string]$ContentType = "application/json",
        [Parameter(Mandatory = $false)]
        [int]$MaxRetries = 3,
        [Parameter(Mandatory = $false)]
        [int]$InitialDelaySeconds = 2
    )
    
    $retryCount = 0
    $delay = $InitialDelaySeconds
    
    while ($true) {
        try {
            $params = @{
                Uri = $Uri
                Method = $Method
                ErrorAction = "Stop"
            }
            
            if ($null -ne $Body) {
                $params["Body"] = $Body
                $params["ContentType"] = $ContentType
            }
            
            $response = Invoke-MgGraphRequest @params
            return @{
                Success = $true
                Data = $response
                Error = $null
            }
        }
        catch {
            $statusCode = $null
            $retryAfter = $null
            
            # Try to extract status code from exception
            if ($_.Exception.Response) {
                $statusCode = [int]$_.Exception.Response.StatusCode
                # Check for Retry-After header
                $retryAfterHeader = $_.Exception.Response.Headers | Where-Object { $_.Key -eq "Retry-After" }
                if ($retryAfterHeader) {
                    $retryAfter = [int]$retryAfterHeader.Value[0]
                }
            }
            
            # Handle throttling (429) or transient errors (500, 502, 503, 504)
            $isRetryable = $statusCode -eq 429 -or $statusCode -in @(500, 502, 503, 504)
            
            if ($isRetryable -and $retryCount -lt $MaxRetries) {
                $retryCount++
                
                # Use Retry-After header if available, otherwise use exponential backoff
                if ($retryAfter) {
                    $waitTime = $retryAfter
                } else {
                    $waitTime = $delay
                    $delay = $delay * 2  # Exponential backoff
                }
                
                Write-Warning "Graph API request failed (Status: $statusCode). Retry $retryCount of $MaxRetries in $waitTime seconds..."
                Start-Sleep -Seconds $waitTime
                continue
            }
            
            # Max retries exceeded or non-retryable error
            $errorMessage = $_.Exception.Message
            Write-Error "Graph API request failed. URI: $Uri. Error: $errorMessage"
            
            return @{
                Success = $false
                Data = $null
                Error = @{
                    Message = $errorMessage
                    StatusCode = $statusCode
                    Exception = $_
                }
            }
        }
    }
}

<#
.SYNOPSIS
    Validates that a file path exists and is accessible.
.DESCRIPTION
    Checks if a file exists at the specified path. Returns a structured result
    indicating success or failure with appropriate error details.
.PARAMETER FilePath
    The file path to validate.
.PARAMETER ParameterName
    Optional. The name of the parameter for better error messages.
.EXAMPLE
    $validation = Test-FilePath -FilePath "C:\devices.txt"
    if (-not $validation.IsValid) { Write-Error $validation.ErrorMessage }
#>
function Test-FilePath {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $false)]
        [string]$ParameterName = "FilePath"
    )
    
    if ([string]::IsNullOrWhiteSpace($FilePath)) {
        return @{
            IsValid = $false
            ErrorMessage = "$ParameterName cannot be null or empty."
            ErrorType = "ValidationError"
        }
    }
    
    if (-not (Test-Path -Path $FilePath -PathType Leaf)) {
        return @{
            IsValid = $false
            ErrorMessage = "File not found: $FilePath"
            ErrorType = "FileNotFound"
        }
    }
    
    return @{
        IsValid = $true
        ErrorMessage = $null
        ErrorType = $null
    }
}

#endregion ===== ERROR HANDLING HELPERS =====

<#
.SYNOPSIS
    Creates a new hashtable with arrays initialized for each specified key.
.DESCRIPTION
    Factory function that creates a properly initialized hashtable for storing 
    multiple device/user results. Each key gets an empty array.
.PARAMETER Keys
    An array of strings representing the keys to initialize in the hashtable.
.EXAMPLE
    $results = New-ResultsHashtable -Keys @("DeviceName", "Status", "Message")
#>
function New-ResultsHashtable {
    param (
        [Parameter(Mandatory = $true)]
        [string[]]$Keys
    )
    
    $hashtable = @{}
    foreach ($key in $Keys) {
        $hashtable[$key] = @()
    }
    return $hashtable
}

<#
.SYNOPSIS
    Adds a single result (hashtable) to a results collection hashtable.
.DESCRIPTION
    Takes a single result hashtable and appends each value to the corresponding 
    array in the results collection. This eliminates repetitive += operations.
.PARAMETER Results
    The results collection hashtable to append to.
.PARAMETER SingleResult
    A hashtable containing a single result to add.
.EXAMPLE
    Add-ResultToHashtable -Results $allResults -SingleResult $deviceInfo
#>
function Add-ResultToHashtable {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$Results,
        [Parameter(Mandatory = $true)]
        [hashtable]$SingleResult
    )
    
    foreach ($key in $SingleResult.Keys) {
        if ($Results.ContainsKey($key)) {
            $Results[$key] += $SingleResult[$key]
        }
    }
}

<#
.SYNOPSIS
    Resolves a device identifier to standardized device information.
.DESCRIPTION
    Takes a device identifier (EntraID, Intune ID, Device Name, or Serial Number)
    and returns a standardized object with IntuneDeviceId, AzureADDeviceId, and DeviceName.
.PARAMETER DeviceIdentifier
    The device identifier value to resolve.
.PARAMETER IDType
    The type of identifier: "EntraID ID", "Intune ID", "Device Name", or "Serial Number".
.PARAMETER SelectProperties
    Optional. Specific properties to retrieve. If not specified, retrieves common properties.
.EXAMPLE
    $deviceInfo = Resolve-DeviceIdentifier -DeviceIdentifier "ABC123" -IDType "Serial Number"
#>
function Resolve-DeviceIdentifier {
    param (
        [Parameter(Mandatory = $true)]
        [string]$DeviceIdentifier,
        [Parameter(Mandatory = $true)]
        [ValidateSet("EntraID ID", "Intune ID", "Device Name", "Serial Number")]
        [string]$IDType,
        [string[]]$SelectProperties = @()
    )
    
    try {
        $deviceInfo = $null
        # Sanitize input for OData filter queries
        $safeIdentifier = ConvertTo-SafeFilterString -InputString $DeviceIdentifier
        
        switch ($IDType) {
            "EntraID ID" {
                if ($SelectProperties.Count -gt 0) {
                    $deviceInfo = Get-MgDeviceManagementManagedDevice -Filter "AzureAdDeviceId eq '$safeIdentifier'" -Property ($SelectProperties -join ",") -ErrorAction Stop
                } else {
                    $deviceInfo = Get-MgDeviceManagementManagedDevice -Filter "AzureAdDeviceId eq '$safeIdentifier'" -ErrorAction Stop
                }
            }
            "Intune ID" {
                if ($SelectProperties.Count -gt 0) {
                    $deviceInfo = Get-MgDeviceManagementManagedDevice -ManagedDeviceId $DeviceIdentifier -Property ($SelectProperties -join ",") -ErrorAction Stop
                } else {
                    $deviceInfo = Get-MgDeviceManagementManagedDevice -ManagedDeviceId $DeviceIdentifier -ErrorAction Stop
                }
            }
            "Device Name" {
                if ($SelectProperties.Count -gt 0) {
                    $deviceInfo = Get-MgDeviceManagementManagedDevice -Filter "DeviceName eq '$safeIdentifier'" -Property ($SelectProperties -join ",") -ErrorAction Stop
                } else {
                    $deviceInfo = Get-MgDeviceManagementManagedDevice -Filter "DeviceName eq '$safeIdentifier'" -ErrorAction Stop
                }
            }
            "Serial Number" {
                if ($SelectProperties.Count -gt 0) {
                    $deviceInfo = Get-MgDeviceManagementManagedDevice -Filter "SerialNumber eq '$safeIdentifier'" -Property ($SelectProperties -join ",") -ErrorAction Stop
                } else {
                    $deviceInfo = Get-MgDeviceManagementManagedDevice -Filter "SerialNumber eq '$safeIdentifier'" -ErrorAction Stop
                }
            }
            default {
                Write-Error "Unsupported ID Type: $IDType"
                return $null
            }
        }
        
        if ($null -eq $deviceInfo) {
            $actionableMsg = Format-ActionableError -ErrorType "DeviceNotFound" -Identifier $DeviceIdentifier -IdentifierType $IDType -Operation "Device Resolution"
            Write-Warning $actionableMsg
            return $null
        }
        
        return $deviceInfo
    }
    catch {
        Write-Warning "Failed to resolve device identifier '$DeviceIdentifier' (Type: $IDType). Error: $($_.Exception.Message)"
        return $null
    }
}

<#
.SYNOPSIS
    Resolves a group identifier to a Group Object ID.
.DESCRIPTION
    Takes a group identifier (Object ID or Group Name) and returns the resolved 
    Group Object ID and group information.
.PARAMETER GroupIdentifier
    The group identifier value (Object ID or display name).
.PARAMETER IDType
    The type of identifier: "Group Object ID" or "Group Name".
.EXAMPLE
    $groupInfo = Resolve-GroupIdentifier -GroupIdentifier "My Group" -IDType "Group Name"
#>
function Resolve-GroupIdentifier {
    param (
        [Parameter(Mandatory = $true)]
        [string]$GroupIdentifier,
        [Parameter(Mandatory = $true)]
        [ValidateSet("Group Object ID", "Group Name")]
        [string]$IDType
    )
    
    try {
        switch ($IDType) {
            "Group Object ID" {
                $groupInfo = Get-MgGroup -GroupId $GroupIdentifier -ErrorAction Stop
                return @{
                    GroupId = $GroupIdentifier
                    DisplayName = $groupInfo.DisplayName
                    Success = $true
                }
            }
            "Group Name" {
                $safeGroupName = ConvertTo-SafeFilterString -InputString $GroupIdentifier
                $groupInfo = Get-MgGroup -Filter "displayName eq '$safeGroupName'" -ErrorAction Stop
                if ($null -eq $groupInfo) {
                    $actionableMsg = Format-ActionableError -ErrorType "GroupNotFound" -Identifier $GroupIdentifier -IdentifierType "Group Name" -Operation "Group Resolution"
                    Write-Error $actionableMsg
                    return @{
                        GroupId = $null
                        DisplayName = $null
                        Success = $false
                        Error = "Group not found"
                    }
                }
                Write-AppLog -Message "Found group: $($groupInfo.DisplayName)" -Level "DEBUG" -Details "Group ID: $($groupInfo.Id)"
                return @{
                    GroupId = $groupInfo.Id
                    DisplayName = $groupInfo.DisplayName
                    Success = $true
                }
            }
        }
    }
    catch {
        Write-Error "Failed to resolve group '$GroupIdentifier' (Type: $IDType). Error: $($_.Exception.Message)"
        return @{
            GroupId = $null
            DisplayName = $null
            Success = $false
            Error = $_.Exception.Message
        }
    }
}

<#
.SYNOPSIS
    Retrieves all pages from a Graph API endpoint that supports pagination.
.DESCRIPTION
    Makes a Graph API request and automatically follows @odata.nextLink to 
    retrieve all pages of results.
.PARAMETER Uri
    The initial Graph API URI to call.
.PARAMETER Method
    The HTTP method to use. Defaults to GET.
.EXAMPLE
    $allPolicies = Get-AllGraphPages -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceConfigurations"
#>
function Get-AllGraphPages {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [string]$Method = "GET"
    )
    
    $allResults = @()
    
    # Use retry wrapper for initial request
    $response = Invoke-GraphRequestWithRetry -Uri $Uri -Method $Method
    
    if (-not $response.Success) {
        Write-Error "Failed to retrieve data from Graph API. URI: $Uri. Error: $($response.Error.Message)"
        return @()
    }
    
    if ($null -ne $response.Data.value) {
        $allResults += $response.Data.value
    }
    
    # Handle pagination with retry logic
    while ($null -ne $response.Data.'@odata.nextLink') {
        $response = Invoke-GraphRequestWithRetry -Uri $response.Data.'@odata.nextLink' -Method $Method
        
        if (-not $response.Success) {
            Write-Warning "Failed to retrieve next page. Returning partial results. Error: $($response.Error.Message)"
            break
        }
        
        if ($null -ne $response.Data.value) {
            $allResults += $response.Data.value
        }
    }
    
    return $allResults
}

<#
.SYNOPSIS
    Processes multiple devices from a file using a provided scriptblock.
.DESCRIPTION
    Generic function that reads device IDs from a file and executes a scriptblock 
    for each device, collecting results into a hashtable.
.PARAMETER FilePath
    Path to the file containing device identifiers (one per line).
.PARAMETER IDType
    The type of device identifier in the file.
.PARAMETER ResultKeys
    Array of keys to initialize in the results hashtable.
.PARAMETER ProcessDevice
    A scriptblock that processes a single device and returns a hashtable.
    The scriptblock receives $DeviceID and $IDType as parameters.
.PARAMETER ThrottleDelayMs
    Delay in milliseconds between processing each device. Defaults to 500.
.EXAMPLE
    $results = Invoke-ForEachDevice -FilePath "C:\devices.txt" -IDType "Serial Number" `
        -ResultKeys @("DeviceName", "Status") -ProcessDevice { param($DeviceID, $IDType) ... }
#>
function Invoke-ForEachDevice {
    param (
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [string]$IDType,
        [Parameter(Mandatory = $true)]
        [string[]]$ResultKeys,
        [Parameter(Mandatory = $true)]
        [scriptblock]$ProcessDevice,
        [int]$ThrottleDelayMs = 500
    )
    
    # Validate file exists using helper
    $fileValidation = Test-FilePath -FilePath $FilePath -ParameterName "FilePath"
    if (-not $fileValidation.IsValid) {
        Write-Error $fileValidation.ErrorMessage
        return $null
    }
    
    # Read device IDs from file (filter out empty lines)
    $deviceIDs = Get-Content -Path $FilePath -Encoding UTF8 -ErrorAction Stop | Where-Object { $_ -match '\S' }
    
    if ($null -eq $deviceIDs -or $deviceIDs.Count -eq 0) {
        Write-Warning "No device IDs found in file: $FilePath"
        return $null
    }
    
    # Initialize results hashtable
    $results = New-ResultsHashtable -Keys $ResultKeys
    
    $counter = 1
    $totalDevices = $deviceIDs.Count
    Write-Host "Processing $totalDevices devices..." -ForegroundColor Yellow
    
    foreach ($deviceID in $deviceIDs) {
        $deviceID = $deviceID.Trim()
        Write-Host "`nProcessing device $counter of $totalDevices : $deviceID" -ForegroundColor Cyan
        $counter++
        
        # Execute the processing scriptblock
        $singleResult = & $ProcessDevice $deviceID $IDType
        
        # Add result to collection
        if ($null -ne $singleResult) {
            Add-ResultToHashtable -Results $results -SingleResult $singleResult
        }
        
        # Throttle to avoid API rate limiting
        if ($counter -le $totalDevices) {
            Start-Sleep -Milliseconds $ThrottleDelayMs
        }
    }
    
    Write-Host "`nProcessing complete. Processed $totalDevices devices." -ForegroundColor Green
    return $results
}

#endregion ==================== HELPER FUNCTIONS ====================

function Get-IntuneDeviceInfo {
    param (
        [bool]$IsSingleDevice,
        [string]$IDorFilePath,
        [string]$DesiredID
    )

    # Define the result keys for this function
    $resultKeys = @("DeviceName", "PrimaryUser", "LastSyncDate", "EnrollmentDate", "OperatingSystem", 
                    "OSVersion", "Model", "Manufacturer", "SerialNumber", "IntuneDeviceId", 
                    "AzureADDeviceId", "ComplianceState", "ManagementAgent", "EmailAddress", 
                    "IsEncrypted", "TotalStorageSpace", "FreeStorageSpace")

    # Scriptblock to process a single device
    $processDevice = {
        param([string]$DeviceID, [string]$IDType)
        
        Write-AppLog -Message "Querying device" -Level "DEBUG" -Details "Device: $DeviceID, Type: $IDType"
        
        # Use the helper function to resolve the device
        $deviceInfo = Resolve-DeviceIdentifier -DeviceIdentifier $DeviceID -IDType $IDType
        
        if ($null -eq $deviceInfo) {
            Write-Host "  Device not found: $DeviceID" -ForegroundColor Yellow
            return @{
                DeviceName = "Not Found"
                PrimaryUser = "N/A"
                LastSyncDate = "N/A"
                EnrollmentDate = "N/A"
                OperatingSystem = "N/A"
                OSVersion = "N/A"
                Model = "N/A"
                Manufacturer = "N/A"
                SerialNumber = $DeviceID
                IntuneDeviceId = "N/A"
                AzureADDeviceId = "N/A"
                ComplianceState = "N/A"
                ManagementAgent = "N/A"
                EmailAddress = "N/A"
                IsEncrypted = "N/A"
                TotalStorageSpace = "N/A"
                FreeStorageSpace = "N/A"
            }
        }

        Write-Host "  Device found: $($deviceInfo.DeviceName) | OS: $($deviceInfo.OperatingSystem) | Compliance: $($deviceInfo.ComplianceState)" -ForegroundColor Green
        return @{
            DeviceName = $deviceInfo.DeviceName
            PrimaryUser = $deviceInfo.UserDisplayName
            LastSyncDate = $deviceInfo.LastSyncDateTime
            EnrollmentDate = $deviceInfo.EnrolledDateTime
            OperatingSystem = $deviceInfo.OperatingSystem
            OSVersion = $deviceInfo.OsVersion
            Model = $deviceInfo.Model
            Manufacturer = $deviceInfo.Manufacturer
            SerialNumber = $deviceInfo.SerialNumber
            IntuneDeviceId = $deviceInfo.Id
            AzureADDeviceId = $deviceInfo.AzureAdDeviceId
            ComplianceState = $deviceInfo.ComplianceState
            ManagementAgent = $deviceInfo.ManagementAgent
            EmailAddress = $deviceInfo.EmailAddress
            IsEncrypted = $deviceInfo.IsEncrypted
            TotalStorageSpace = $deviceInfo.TotalStorageSpaceInBytes
            FreeStorageSpace = $deviceInfo.FreeStorageSpaceInBytes
        }
    }

    if ($IsSingleDevice) {
        # Process single device directly
        return (& $processDevice $IDorFilePath $DesiredID)
    } else {
        # Use helper function to process multiple devices from file
        return Invoke-ForEachDevice -FilePath $IDorFilePath -IDType $DesiredID -ResultKeys $resultKeys -ProcessDevice $processDevice
    }
}

function Get-IntuneDeviceEncryptionDetails {
    param (
        [bool]$IsSingleDevice,
        [string]$IDorFilePath,
        [string]$DesiredID
    )

    # Define the result keys for this function
    $resultKeys = @("DeviceName", "IntuneID", "LastSyncDate", "IsEncrypted")

    # Scriptblock to process a single device
    $processDevice = {
        param([string]$DeviceID, [string]$IDType)
        
        Write-AppLog -Message "Querying encryption details" -Level "DEBUG" -Details "Device: $DeviceID, Type: $IDType"
        
        # Use the helper function to resolve the device with specific properties
        $deviceInfo = Resolve-DeviceIdentifier -DeviceIdentifier $DeviceID -IDType $IDType -SelectProperties @("DeviceName", "IsEncrypted", "Id", "LastSyncDateTime")
        
        if ($null -eq $deviceInfo) {
            Write-Host "  Device not found: $DeviceID" -ForegroundColor Yellow
            return @{
                DeviceName = "Not Found"
                IntuneID = "N/A"
                LastSyncDate = "N/A"
                IsEncrypted = "N/A"
            }
        }

        $encryptionStatus = if ($deviceInfo.IsEncrypted) { "Encrypted" } else { "Not Encrypted" }
        $statusColor = if ($deviceInfo.IsEncrypted) { "Green" } else { "Yellow" }
        Write-Host "  $($deviceInfo.DeviceName) - BitLocker: $encryptionStatus" -ForegroundColor $statusColor
        return @{
            DeviceName = $deviceInfo.DeviceName
            IntuneID = $deviceInfo.Id
            LastSyncDate = $deviceInfo.LastSyncDateTime
            IsEncrypted = $deviceInfo.IsEncrypted
        }
    }

    if ($IsSingleDevice) {
        return (& $processDevice $IDorFilePath $DesiredID)
    } else {
        return Invoke-ForEachDevice -FilePath $IDorFilePath -IDType $DesiredID -ResultKeys $resultKeys -ProcessDevice $processDevice
    }
}

function Get-IntuneDeviceLastLoggedOnUser {
    param (
        [bool]$IsSingleDevice,
        [string]$IDorFilePath,
        [string]$DesiredID
    )

    # Define the result keys for this function
    $resultKeys = @("DeviceName", "UserDisplayName", "UserId", "LastLogOnDateTime")

    # Scriptblock to process a single device
    $processDevice = {
        param([string]$DeviceID, [string]$IDType)
        
        Write-AppLog -Message "Querying last logged-on user" -Level "DEBUG" -Details "Device: $DeviceID, Type: $IDType"
        
        # Use the helper function to resolve the device
        $deviceInfo = Resolve-DeviceIdentifier -DeviceIdentifier $DeviceID -IDType $IDType -SelectProperties @("Id", "DeviceName")
        
        if ($null -eq $deviceInfo) {
            Write-Host "  Device not found: $DeviceID" -ForegroundColor Yellow
            return @{
                DeviceName = "Not Found"
                UserDisplayName = "N/A"
                UserId = "N/A"
                LastLogOnDateTime = "N/A"
            }
        }

        try {
            # Call the Graph API to get usersLoggedOn information
            Write-AppLog -Message "Fetching last logged-in user from Graph API" -Level "DEBUG" -Details "Device: $($deviceInfo.DeviceName)"
            Write-Host "  Fetching last logged-on user for: $($deviceInfo.DeviceName)" -ForegroundColor Cyan
            $url = "https://graph.microsoft.com/beta/deviceManagement/managedDevices/$($deviceInfo.Id)"
            $apiResponse = Invoke-GraphRequestWithRetry -Uri $url -Method GET
            
            if (-not $apiResponse.Success) {
                Write-Error "Failed to retrieve device info from Graph API. Error: $($apiResponse.Error.Message)"
                return @{
                    DeviceName = if ($deviceInfo.DeviceName) { $deviceInfo.DeviceName } else { "Unknown" }
                    UserDisplayName = "API Error"
                    UserId = "N/A"
                    LastLogOnDateTime = "N/A"
                }
            }
            
            $usersLoggedOn = $apiResponse.Data.usersLoggedOn
            
            # Check if there are any logged-on users
            if ($null -eq $usersLoggedOn -or $usersLoggedOn.Count -eq 0) {
                Write-Warning "No logged-on user information found for device: $($deviceInfo.DeviceName)"
                return @{
                    DeviceName = $deviceInfo.DeviceName
                    UserDisplayName = "No User Found"
                    UserId = "N/A"
                    LastLogOnDateTime = "N/A"
                }
            }
            
            # Get the most recent user (first in the list)
            $lastLoggedOnUser = $usersLoggedOn[0]
            
            # Get detailed user information
            if ($null -ne $lastLoggedOnUser.userId -and $lastLoggedOnUser.userId -ne "") {
                Write-AppLog -Message "Fetching user details" -Level "DEBUG" -Details "User ID: $($lastLoggedOnUser.userId)"
                Write-Host "  Resolving user details for ID: $($lastLoggedOnUser.userId)" -ForegroundColor Cyan
                try {
                    $userDetails = Get-MgUser -UserId $lastLoggedOnUser.userId -ErrorAction Stop
                    
                    Write-Host "  Last logged-on user: $($userDetails.DisplayName)" -ForegroundColor Green
                    return @{
                        DeviceName = $deviceInfo.DeviceName
                        UserDisplayName = $userDetails.DisplayName
                        UserId = $userDetails.Id
                        LastLogOnDateTime = $lastLoggedOnUser.lastLogOnDateTime
                    }
                } catch {
                    Write-Warning "Could not retrieve user details for user ID: $($lastLoggedOnUser.userId). Error: $_"
                    return @{
                        DeviceName = $deviceInfo.DeviceName
                        UserDisplayName = "User Details Unavailable"
                        UserId = $lastLoggedOnUser.userId
                        LastLogOnDateTime = $lastLoggedOnUser.lastLogOnDateTime
                    }
                }
            } else {
                Write-Warning "No valid user ID found in logged-on user information"
                return @{
                    DeviceName = $deviceInfo.DeviceName
                    UserDisplayName = "No Valid User ID"
                    UserId = "N/A"
                    LastLogOnDateTime = if ($lastLoggedOnUser.lastLogOnDateTime) { $lastLoggedOnUser.lastLogOnDateTime } else { "N/A" }
                }
            }
        } catch {
            Write-Error "Failed to retrieve last logged-on user for device: $($deviceInfo.DeviceName). Error: $_"
            return @{
                DeviceName = if ($deviceInfo.DeviceName) { $deviceInfo.DeviceName } else { "Unknown" }
                UserDisplayName = "Error Occurred"
                UserId = "N/A"
                LastLogOnDateTime = "N/A"
            }
        }
    }

    if ($IsSingleDevice) {
        return (& $processDevice $IDorFilePath $DesiredID)
    } else {
        return Invoke-ForEachDevice -FilePath $IDorFilePath -IDType $DesiredID -ResultKeys $resultKeys -ProcessDevice $processDevice
    }
}

function Get-IntuneGroupAssignments {
    param (
        [string]$GroupID,
        [string]$IDType
    )

    Write-AppLog -Message "Searching for group assignments" -Level "DEBUG" -Details "GroupID: $GroupID, Type: $IDType"
    
    # Use the helper function to resolve the group
    $groupResult = Resolve-GroupIdentifier -GroupIdentifier $GroupID -IDType $IDType
    
    if (-not $groupResult.Success) {
        Write-Error "Could not resolve group: $($groupResult.Error)"
        return $null
    }
    
    $resolvedGroupId = $groupResult.GroupId
    Write-Host "Found group: $($groupResult.DisplayName)" -ForegroundColor Green

    # Initialize results using helper function
    $assignments = New-ResultsHashtable -Keys @("PolicyName", "PolicyType", "AssignmentType", "PolicyId")

    $graphBaseUrl = "https://graph.microsoft.com/beta"

    # Define policy types to search with their endpoints and name properties
    $policyTypes = @(
        @{ Name = "Device Configuration"; Endpoint = "/deviceManagement/deviceConfigurations"; NameProperty = "displayName" },
        @{ Name = "Settings Catalog"; Endpoint = "/deviceManagement/configurationPolicies"; NameProperty = "name" },
        @{ Name = "Compliance Policy"; Endpoint = "/deviceManagement/deviceCompliancePolicies"; NameProperty = "displayName" },
        @{ Name = "Mobile App"; Endpoint = "/deviceAppManagement/mobileApps"; NameProperty = "displayName" },
        @{ Name = "PowerShell Script"; Endpoint = "/deviceManagement/deviceManagementScripts"; NameProperty = "displayName" },
        @{ Name = "Remediation Script"; Endpoint = "/deviceManagement/deviceHealthScripts"; NameProperty = "displayName" },
        @{ Name = "iOS App Protection"; Endpoint = "/deviceAppManagement/iosManagedAppProtections"; NameProperty = "displayName" },
        @{ Name = "Android App Protection"; Endpoint = "/deviceAppManagement/androidManagedAppProtections"; NameProperty = "displayName" },
        @{ Name = "App Configuration"; Endpoint = "/deviceAppManagement/mobileAppConfigurations"; NameProperty = "displayName" },
        @{ Name = "Endpoint Security"; Endpoint = "/deviceManagement/intents"; NameProperty = "displayName" }
    )

    # Search each policy type
    foreach ($policyType in $policyTypes) {
        Write-Host "Searching $($policyType.Name) Policies..." -ForegroundColor Yellow
        try {
            # Use expansion for better performance (single API call per type instead of N+1)
            $uri = "$graphBaseUrl$($policyType.Endpoint)?`$expand=assignments"
            $policies = Get-AllGraphPages -Uri $uri
            
            foreach ($policy in $policies) {
                $policyName = $policy.($policyType.NameProperty)
                if ([string]::IsNullOrEmpty($policyName)) { $policyName = $policy.displayName }
                
                # Check for expanded assignments
                $policyAssignments = $policy.assignments
                
                if ($null -ne $policyAssignments) {
                    foreach ($assignment in $policyAssignments) {
                        # Check if target is a group and matches our resolved group ID
                        if ($assignment.target.groupId -eq $resolvedGroupId) {
                            $assignmentType = switch ($assignment.target.'@odata.type') {
                                '#microsoft.graph.groupAssignmentTarget' { "Include" }
                                '#microsoft.graph.exclusionGroupAssignmentTarget' { "Exclude" }
                                '#microsoft.graph.allLicensedUsersAssignmentTarget' { "All Users" }
                                '#microsoft.graph.allDevicesAssignmentTarget' { "All Devices" }
                                default { $assignment.target.'@odata.type' -replace '#microsoft.graph.', '' }
                            }
                            
                            $assignments["PolicyName"] += $policyName
                            $assignments["PolicyType"] += $policyType.Name
                            $assignments["AssignmentType"] += $assignmentType
                            $assignments["PolicyId"] += $policy.id
                            Write-AppLog -Message "Found assignment" -Level "DEBUG" -Details "$($policyType.Name): $policyName ($assignmentType)"
                        }
                    }
                }
            }
        } catch {
            $errorMessage = $_.Exception.Message
            # Check for permission-related errors (403 Forbidden or Authorization errors)
            if ($errorMessage -match "403|Forbidden|Authorization|Insufficient privileges|Access denied") {
                Write-Warning "Skipping $($policyType.Name) - Insufficient permissions. Required: DeviceManagementConfiguration.Read.All or DeviceManagementScripts.Read.All"
                Write-AppLog -Message "Permission denied for $($policyType.Name)" -Level "WARNING" -Details $errorMessage
            } else {
                Write-Warning "Error searching $($policyType.Name) Policies: $errorMessage"
                Write-AppLog -Message "Error searching $($policyType.Name)" -Level "ERROR" -Details $errorMessage
            }
        }
    }

    Write-Host "Group assignment search completed. Found $($assignments['PolicyName'].Count) assignments." -ForegroundColor Cyan
    return $assignments
}

function Import-DevicesToGroup {
    param (
        [bool]$IsSingleDevice,
        [string]$IDorFilePath,
        [string]$DesiredID,
        [string]$GroupID,
        [string]$GroupIDType
    )

    # Resolve the group ID using the helper function
    Write-Host "Resolving group..." -ForegroundColor Yellow
    $groupResult = Resolve-GroupIdentifier -GroupIdentifier $GroupID -IDType $GroupIDType
    
    if (-not $groupResult.Success) {
        Write-Error "Could not resolve group: $($groupResult.Error)"
        return $null
    }
    
    $resolvedGroupId = $groupResult.GroupId
    Write-Host "Found group: $($groupResult.DisplayName)" -ForegroundColor Green

    # Define the result keys for this function
    $resultKeys = @("DeviceID", "DeviceName", "Status", "Message")

    # Scriptblock to process a single device for import
    $processDevice = {
        param([string]$DeviceID, [string]$IDType)
        
        Write-AppLog -Message "Processing device for import" -Level "DEBUG" -Details "Device: $DeviceID, Type: $IDType"
        
        try {
            # Get the Entra device object based on ID type
            $entraDevice = $null
            $azureADDeviceId = $null
            
            # Sanitize input for OData filter queries
            $safeDeviceID = ConvertTo-SafeFilterString -InputString $DeviceID
            
            switch ($IDType) {
                "EntraID ID" {
                    # EntraID ID is the Azure AD Device ID (deviceId property in Graph)
                    Write-AppLog -Message "Getting device with Entra ID" -Level "DEBUG" -Details "DeviceID: $DeviceID"
                    $entraDevice = Get-MgDevice -Filter "deviceId eq '$safeDeviceID'" -ErrorAction Stop | Select-Object Id, DisplayName
                    $azureADDeviceId = $DeviceID
                }
                "Device Name" {
                    # Get Intune device by name to get Azure AD Device ID
                    Write-AppLog -Message "Getting EntraID device ID by name" -Level "DEBUG" -Details "Device: $DeviceID"
                    $intuneDevice = Resolve-DeviceIdentifier -DeviceIdentifier $DeviceID -IDType $IDType -SelectProperties @("AzureAdDeviceId", "DeviceName")
                    
                    if ($null -eq $intuneDevice -or [string]::IsNullOrEmpty($intuneDevice.AzureAdDeviceId)) {
                        Write-Warning "Device not found in Intune: $DeviceID"
                        return @{ DeviceID = $DeviceID; DeviceName = $DeviceID; Status = "Not Found"; Message = "Device not found in Intune" }
                    }
                    
                    $azureADDeviceId = $intuneDevice.AzureAdDeviceId
                    Write-AppLog -Message "Resolved EntraID ID" -Level "DEBUG" -Details "ID: $azureADDeviceId"
                    $safeAzureADDeviceId = ConvertTo-SafeFilterString -InputString $azureADDeviceId
                    $entraDevice = Get-MgDevice -Filter "deviceId eq '$safeAzureADDeviceId'" -ErrorAction Stop | Select-Object Id, DisplayName
                }
                "Serial Number" {
                    # Get Intune device by serial to get Azure AD Device ID
                    Write-AppLog -Message "Getting EntraID device ID by serial" -Level "DEBUG" -Details "Serial: $DeviceID"
                    $intuneDevice = Resolve-DeviceIdentifier -DeviceIdentifier $DeviceID -IDType $IDType -SelectProperties @("AzureAdDeviceId", "DeviceName")
                    
                    if ($null -eq $intuneDevice -or [string]::IsNullOrEmpty($intuneDevice.AzureAdDeviceId)) {
                        Write-Warning "Device not found in Intune: $DeviceID"
                        return @{ DeviceID = $DeviceID; DeviceName = "Serial: $DeviceID"; Status = "Not Found"; Message = "Device not found in Intune" }
                    }
                    
                    $azureADDeviceId = $intuneDevice.AzureAdDeviceId
                    Write-AppLog -Message "Resolved EntraID ID" -Level "DEBUG" -Details "ID: $azureADDeviceId"
                    $safeAzureADDeviceId = ConvertTo-SafeFilterString -InputString $azureADDeviceId
                    $entraDevice = Get-MgDevice -Filter "deviceId eq '$safeAzureADDeviceId'" -ErrorAction Stop | Select-Object Id, DisplayName
                }
                default {
                    return @{ DeviceID = $DeviceID; DeviceName = "Unknown"; Status = "Error"; Message = "Unsupported ID Type: $IDType" }
                }
            }

            if ($null -eq $entraDevice) {
                Write-Warning "Device not found in Entra ID: $DeviceID"
                return @{ DeviceID = $DeviceID; DeviceName = "Not Found"; Status = "Not Found"; Message = "Device not found in Entra ID" }
            }

            $DeviceObjectID = $entraDevice.Id
            $DeviceName = $entraDevice.DisplayName
            Write-AppLog -Message "Found device" -Level "DEBUG" -Details "$DeviceName (Object ID: $DeviceObjectID)"

            # Add device to group
            Write-AppLog -Message "Adding device to group" -Level "DEBUG" -Details "Device: $DeviceName"
            New-MgGroupMember -GroupId $resolvedGroupId -DirectoryObjectId $DeviceObjectID -ErrorAction Stop
            
            Write-Host "  $DeviceName added to group: $($groupResult.DisplayName)" -ForegroundColor Green
            Write-Host "Device added successfully" -ForegroundColor Green
            Write-AuditLog -Operation "GroupImport" -Target $DeviceName -TargetType "Device" `
                -BeforeState "Not a member" -AfterState "Member of group [$($groupResult.DisplayName)]" `
                -Result "Success" -Details "Group ID: $resolvedGroupId, Device Object ID: $DeviceObjectID"
            return @{ DeviceID = $DeviceID; DeviceName = $DeviceName; Status = "Added"; Message = "Successfully added to group" }
        }
        catch {
            if ($_.Exception.Message -match "One or more added object references already exist") {
                Write-AppLog -Message "Device already in group" -Level "DEBUG" -Details "Device: $DeviceID"
                Write-Host "  Already a member: $(if ($DeviceName) { $DeviceName } else { $DeviceID })" -ForegroundColor Yellow
                Write-AuditLog -Operation "GroupImport" -Target $(if ($DeviceName) { $DeviceName } else { $DeviceID }) -TargetType "Device" `
                    -Result "Skipped" -Details "Device is already a member of the group"
                return @{ DeviceID = $DeviceID; DeviceName = if ($DeviceName) { $DeviceName } else { "Unknown" }; Status = "Already Member"; Message = "Device is already a member of this group" }
            }
            else {
                $errorMsg = $_.Exception.Message
                Write-Host "  Error adding '$(if ($DeviceName) { $DeviceName } else { $DeviceID })': $errorMsg" -ForegroundColor Red
                Write-AuditLog -Operation "GroupImport" -Target $(if ($DeviceName) { $DeviceName } else { $DeviceID }) -TargetType "Device" `
                    -Result "Failed" -ErrorMessage $errorMsg
                Write-Error "Error adding device: $errorMsg"
                return @{ DeviceID = $DeviceID; DeviceName = if ($DeviceName) { $DeviceName } else { "Unknown" }; Status = "Error"; Message = $errorMsg }
            }
        }
    }

    # Import devices
    if ($IsSingleDevice) {
        return (& $processDevice $IDorFilePath $DesiredID)
    } else {
        return Invoke-ForEachDevice -FilePath $IDorFilePath -IDType $DesiredID -ResultKeys $resultKeys -ProcessDevice $processDevice
    }
}

function Test-IntuneDeviceGroupMembership {
    param (
        [bool]$IsSingleDevice,
        [string]$IDorFilePath,
        [string]$DesiredID,
        [string]$GroupNameOrID
    )

    # Define the result keys for this function
    $resultKeys = @("DeviceID", "DeviceName", "DeviceAzureADID", "GroupName", "State")

    # Scriptblock to process a single device
    $processDevice = {
        param([string]$DeviceID, [string]$IDType)
        
        Write-AppLog -Message "Checking device membership" -Level "DEBUG" -Details "Device: $DeviceID, Type: $IDType"
        
        try {
            # Use the helper function to resolve the device
            $IntuneInfo = Resolve-DeviceIdentifier -DeviceIdentifier $DeviceID -IDType $IDType -SelectProperties @("Id", "DeviceName", "AzureAdDeviceId", "SerialNumber")
            
            if ($null -eq $IntuneInfo -or [string]::IsNullOrEmpty($IntuneInfo.AzureAdDeviceId)) {
                Write-Warning "Device '$DeviceID' not found in Intune"
                return @{
                    DeviceID = $DeviceID
                    DeviceName = "Not Found"
                    DeviceAzureADID = "N/A"
                    GroupName = $GroupNameOrID
                    State = "Device Not Found"
                }
            }

            $AzureADDeviceID = $IntuneInfo.AzureAdDeviceId

            # Convert Azure AD Device ID to Object ID (sanitize for OData filter)
            $safeAzureADDeviceID = ConvertTo-SafeFilterString -InputString $AzureADDeviceID
            $objectId = (Get-MgDevice -Filter "deviceId eq '$safeAzureADDeviceID'" -ErrorAction Stop).Id
            
            if ($null -eq $objectId) {
                Write-Warning "Could not find Entra device object for device: $($IntuneInfo.DeviceName)"
                return @{
                    DeviceID = $DeviceID
                    DeviceName = $IntuneInfo.DeviceName
                    DeviceAzureADID = $AzureADDeviceID
                    GroupName = $GroupNameOrID
                    State = "Entra Device Not Found"
                }
            }

            # Get device group memberships using pagination helper
            $url = "https://graph.microsoft.com/beta/devices/$objectId/memberOf"
            $assignments = Get-AllGraphPages -Uri $url
            
            [System.Collections.ArrayList]$grouplist = @()
            foreach ($assignment in $assignments) {
                $grouplist.Add($assignment.displayName) | Out-Null
            }

            # Check if device is in desired group
            if ($GroupNameOrID -in $grouplist) {
                $state = "Device IS IN desired group"
                Write-Host $state -ForegroundColor Green
            } else {
                $state = "Device IS NOT IN desired group"
                Write-Host $state -ForegroundColor Yellow
            }

            return @{
                DeviceID = $DeviceID
                DeviceName = $IntuneInfo.DeviceName
                DeviceAzureADID = $AzureADDeviceID
                GroupName = $GroupNameOrID
                State = $state
            }
        }
        catch {
            Write-Error "Error checking device membership: $($_.Exception.Message)"
            return @{
                DeviceID = $DeviceID
                DeviceName = "Error"
                DeviceAzureADID = "N/A"
                GroupName = $GroupNameOrID
                State = "Error: $($_.Exception.Message)"
            }
        }
    }

    # Execute based on single or multiple devices
    if ($IsSingleDevice) {
        return (& $processDevice $IDorFilePath $DesiredID)
    } else {
        return Invoke-ForEachDevice -FilePath $IDorFilePath -IDType $DesiredID -ResultKeys $resultKeys -ProcessDevice $processDevice
    }
}

function Remove-DevicesFromGroup {
    param (
        [string]$FilePath,
        [string]$DesiredID,
        [string]$GroupID,
        [string]$GroupIDType
    )

    Write-Host "=== Remove Devices from Group Starting ===" -ForegroundColor Cyan
    Write-AppLog -Message "Remove Devices from Group starting" -Level "DEBUG" -Details "File: $FilePath, IDType: $DesiredID, Group: $GroupID ($GroupIDType)"
    
    # Resolve the group ID using the helper function
    $groupResult = Resolve-GroupIdentifier -GroupIdentifier $GroupID -IDType $GroupIDType
    
    if (-not $groupResult.Success) {
        Write-Error "Could not resolve group: $($groupResult.Error)"
        return $null
    }
    
    $resolvedGroupId = $groupResult.GroupId
    Write-Host "Found group: $($groupResult.DisplayName)" -ForegroundColor Green

    # Define the result keys for this function
    $resultKeys = @("DeviceID", "DeviceName", "Status", "Message")

    # Scriptblock to process a single device for removal
    $processDevice = {
        param([string]$DeviceID, [string]$IDType)
        
        Write-AppLog -Message "Processing device for removal" -Level "DEBUG" -Details "Device: $DeviceID, Type: $IDType"
        $deviceName = $DeviceID
        
        try {
            # Use the helper function to resolve the device
            $mgDevice = Resolve-DeviceIdentifier -DeviceIdentifier $DeviceID -IDType $IDType -SelectProperties @("AzureAdDeviceId", "DeviceName")
            
            if ($null -eq $mgDevice -or [string]::IsNullOrEmpty($mgDevice.AzureAdDeviceId)) {
                Write-Warning "Device not found in Intune: $DeviceID"
                return @{ DeviceID = $DeviceID; DeviceName = $deviceName; Status = "Not Found"; Message = "Device not found in Intune" }
            }
            
            $entraDeviceId = $mgDevice.AzureAdDeviceId
            $deviceName = $mgDevice.DeviceName
            Write-AppLog -Message "Found Entra ID Device ID" -Level "DEBUG" -Details "ID: $entraDeviceId"

            # Get the Entra ID device object ID (sanitize for OData filter)
            Write-AppLog -Message "Looking up Entra ID device object" -Level "DEBUG"
            $safeEntraDeviceId = ConvertTo-SafeFilterString -InputString $entraDeviceId
            $aadDevice = Get-MgDevice -Filter "deviceId eq '$safeEntraDeviceId'" -ErrorAction Stop | Select-Object Id, DisplayName
            
            if ($null -eq $aadDevice) {
                Write-Warning "Device not found in Entra ID: $entraDeviceId"
                return @{ DeviceID = $DeviceID; DeviceName = $deviceName; Status = "Not Found"; Message = "Device not found in Entra ID" }
            }

            $deviceObjectId = $aadDevice.Id
            if ($aadDevice.DisplayName) { $deviceName = $aadDevice.DisplayName }
            Write-AppLog -Message "Found Directory Object ID" -Level "DEBUG" -Details "ID: $deviceObjectId"

            # Remove device from group
            Write-AppLog -Message "Removing device from group" -Level "DEBUG" -Details "Device: $deviceName"
            Remove-MgGroupMemberByRef -GroupId $resolvedGroupId -DirectoryObjectId $deviceObjectId -ErrorAction Stop
            
            Write-Host "Successfully removed device: $deviceName" -ForegroundColor Green
            Write-AuditLog -Operation "GroupRemove" -Target $deviceName -TargetType "Device" `
                -BeforeState "Member of group [$($groupResult.DisplayName)]" -AfterState "Removed from group" `
                -Result "Success" -Details "Group ID: $resolvedGroupId, Device Object ID: $deviceObjectId"
            return @{ DeviceID = $DeviceID; DeviceName = $deviceName; Status = "Removed"; Message = "Successfully removed from group" }
        }
        catch {
            $errorMessage = $_.Exception.Message
            
            if ($errorMessage -match "does not exist" -or $errorMessage -match "not found") {
                Write-Warning "Device is not a member of the group"
                Write-AuditLog -Operation "GroupRemove" -Target $deviceName -TargetType "Device" `
                    -Result "Skipped" -Details "Device is not a member of the group"
                return @{ DeviceID = $DeviceID; DeviceName = $deviceName; Status = "Not a Member"; Message = "Device is not a member of this group" }
            }
            else {
                Write-Host "Error removing device '$DeviceID' from group: $errorMessage" -ForegroundColor Red
                Write-AuditLog -Operation "GroupRemove" -Target $deviceName -TargetType "Device" `
                    -Result "Failed" -ErrorMessage $errorMessage
                return @{ DeviceID = $DeviceID; DeviceName = $deviceName; Status = "Error"; Message = $errorMessage }
            }
        }
    }

    # Process all devices from file
    $results = Invoke-ForEachDevice -FilePath $FilePath -IDType $DesiredID -ResultKeys $resultKeys -ProcessDevice $processDevice

    Write-Host "`n=== Remove from Group Complete ===" -ForegroundColor Cyan
    if ($null -ne $results) {
        $removedCount = ($results["Status"] | Where-Object { $_ -eq "Removed" }).Count
        $notMemberCount = ($results["Status"] | Where-Object { $_ -eq "Not a Member" }).Count
        $errorCount = ($results["Status"] | Where-Object { $_ -eq "Error" -or $_ -eq "Not Found" }).Count
        Write-Host "Summary: Removed=$removedCount, Not a Member=$notMemberCount, Errors=$errorCount" -ForegroundColor Cyan
    }
    
    return $results
}

function Clear-GroupMembers {
    param (
        [string]$GroupID,
        [string]$GroupIDType
    )

    Write-Host "=== Empty Group Members Starting ===" -ForegroundColor Cyan
    Write-AppLog -Message "Empty Group Members starting" -Level "DEBUG" -Details "Group: $GroupID ($GroupIDType)"
    
    # Resolve the group ID using the helper function
    $groupResult = Resolve-GroupIdentifier -GroupIdentifier $GroupID -IDType $GroupIDType
    
    if (-not $groupResult.Success) {
        Write-Error "Could not resolve group: $($groupResult.Error)"
        return $null
    }
    
    $resolvedGroupId = $groupResult.GroupId
    Write-Host "Found group: $($groupResult.DisplayName)" -ForegroundColor Green

    # Create results hashtable using helper
    $results = New-ResultsHashtable -Keys @("MemberID", "DisplayName", "Type", "Status", "Message")
    
    try {
        Write-Host "Fetching group members..." -ForegroundColor Cyan
        $members = Get-MgGroupMember -GroupId $resolvedGroupId -All -ErrorAction Stop
        
        if ($null -eq $members -or $members.Count -eq 0) {
            Write-Host "Group is already empty." -ForegroundColor Green
            return $results
        }
        
        $totalMembers = $members.Count
        Write-Host "Found $totalMembers members to remove." -ForegroundColor Yellow
        
        $counter = 0
        foreach ($member in $members) {
            $counter++
            $memberId = $member.Id
            # Try to get display name and type if available, otherwise default
            $displayName = if ($member.AdditionalProperties.ContainsKey("displayName")) { $member.AdditionalProperties["displayName"] } else { $memberId }
            $type = if ($member.AdditionalProperties.ContainsKey("@odata.type")) { $member.AdditionalProperties["@odata.type"] } else { "Unknown" }
            
            Write-Host "[$counter/$totalMembers] Removing member: $displayName ($type)..." -NoNewline
            
            try {
                Remove-MgGroupMemberByRef -GroupId $resolvedGroupId -DirectoryObjectId $memberId -ErrorAction Stop
                Write-Host " [OK]" -ForegroundColor Green
                
                Add-ResultToHashtable -Results $results -SingleResult @{
                    MemberID = $memberId
                    DisplayName = $displayName
                    Type = $type
                    Status = "Removed"
                    Message = "Successfully removed from group"
                }
            }
            catch {
                Write-Host " [FAILED]" -ForegroundColor Red
                Add-ResultToHashtable -Results $results -SingleResult @{
                    MemberID = $memberId
                    DisplayName = $displayName
                    Type = $type
                    Status = "Error"
                    Message = $_.Exception.Message
                }
            }
        }
        
        Write-Host "Empty group operation completed." -ForegroundColor Cyan
    }
    catch {
        Write-Error "Error retrieving group members: $($_.Exception.Message)"
        return $null
    }
    
    return $results
}

function Invoke-IntuneDeviceRetire {
    param (
        [string]$FilePath,
        [string]$DesiredID
    )

    Write-Host "Starting Retire Devices operation..." -ForegroundColor Cyan
    Write-AppLog -Message "Retire Devices operation starting" -Level "DEBUG" -Details "File: $FilePath, IDType: $DesiredID"
    
    # Validate file exists
    if (-not (Test-Path $FilePath)) {
        Write-Error "File not found: $FilePath"
        return $null
    }
    
    # Read device IDs from file
    $deviceIDs = Get-Content -Path $FilePath -Encoding UTF8 | Where-Object { $_ -match '\S' }
    $totalDevices = $deviceIDs.Count
    Write-Host "Total devices to process: $totalDevices" -ForegroundColor Yellow
    
    # Create results hashtable using helper
    $results = New-ResultsHashtable -Keys @("DeviceID", "DeviceName", "LastSync", "Ownership", "Status", "Message")

    $counter = 0

    foreach ($deviceID in $deviceIDs) {
        $deviceID = $deviceID.Trim()
        $counter++
        Write-Host "`n#$counter of $totalDevices" -ForegroundColor Yellow
        
        try {
            # Use the helper function to resolve the device
            $deviceInfo = Resolve-DeviceIdentifier -DeviceIdentifier $deviceID -IDType $DesiredID -SelectProperties @("Id", "DeviceName", "LastSyncDateTime", "ManagedDeviceOwnerType")

            if ($null -eq $deviceInfo) {
                Write-Warning "Device not found: $deviceID"
                Add-ResultToHashtable -Results $results -SingleResult @{
                    DeviceID = $deviceID; DeviceName = "Not Found"; LastSync = "N/A"
                    Ownership = "N/A"; Status = "Not Found"; Message = "Device not found in Intune"
                }
                continue
            }

            $intuneDeviceId = $deviceInfo.Id
            $deviceName = $deviceInfo.DeviceName
            $deviceLastSync = $deviceInfo.LastSyncDateTime
            $ownership = $deviceInfo.ManagedDeviceOwnerType

            Write-Host "Device: $deviceName | Last sync: $deviceLastSync | Ownership: $ownership" -ForegroundColor Green

            # Show confirmation dialog for this device
            $confirmResult = [System.Windows.MessageBox]::Show(
                "Do you want to RETIRE this device?`r`n`r`nDevice Name: $deviceName`r`nIntune ID: $intuneDeviceId`r`nLast Sync: $deviceLastSync`r`nOwnership: $ownership`r`n`r`nThis will remove company data and unenroll from Intune.",
                "Confirm Retire - Device $counter of $totalDevices",
                [System.Windows.MessageBoxButton]::YesNoCancel,
                [System.Windows.MessageBoxImage]::Warning
            )

            if ($confirmResult -eq [System.Windows.MessageBoxResult]::Cancel) {
                Write-Host "Retire operation cancelled by user" -ForegroundColor Yellow
                Add-ResultToHashtable -Results $results -SingleResult @{
                    DeviceID = $deviceID; DeviceName = $deviceName; LastSync = $deviceLastSync
                    Ownership = $ownership; Status = "Cancelled"; Message = "Operation cancelled by user"
                }
                break
            }
            elseif ($confirmResult -eq [System.Windows.MessageBoxResult]::No) {
                Write-Host "Device skipped by user" -ForegroundColor Yellow
                Add-ResultToHashtable -Results $results -SingleResult @{
                    DeviceID = $deviceID; DeviceName = $deviceName; LastSync = $deviceLastSync
                    Ownership = $ownership; Status = "Skipped"; Message = "Skipped by user"
                }
                continue
            }

            # User confirmed - retire the device
            Write-Host "Retiring device: $deviceName ($intuneDeviceId)..." -ForegroundColor Cyan
            
            try {
                Invoke-MgRetireDeviceManagementManagedDevice -ManagedDeviceId $intuneDeviceId -ErrorAction Stop
                
                Write-Host "Device retired successfully: $deviceName" -ForegroundColor Green
                Write-AuditLog -Operation "DeviceRetire" -Target $deviceName -TargetType "Device" `
                    -BeforeState "Enrolled in Intune" -AfterState "Retire command sent" `
                    -Result "Success" -Details "Intune ID: $intuneDeviceId, Ownership: $ownership"
                Add-ResultToHashtable -Results $results -SingleResult @{
                    DeviceID = $deviceID; DeviceName = $deviceName; LastSync = $deviceLastSync
                    Ownership = $ownership; Status = "Retired"; Message = "Successfully retired"
                }
            }
            catch {
                $errorMsg = $_.Exception.Message
                Write-Error "Failed to retire device: $errorMsg"
                Write-AuditLog -Operation "DeviceRetire" -Target $deviceName -TargetType "Device" `
                    -Result "Failed" -ErrorMessage $errorMsg -Details "Intune ID: $intuneDeviceId"
                Add-ResultToHashtable -Results $results -SingleResult @{
                    DeviceID = $deviceID; DeviceName = $deviceName; LastSync = $deviceLastSync
                    Ownership = $ownership; Status = "Error"; Message = "Retire failed: $errorMsg"
                }
            }
        }
        catch {
            Write-Error "Error processing device '$deviceID': $($_.Exception.Message)"
            Add-ResultToHashtable -Results $results -SingleResult @{
                DeviceID = $deviceID; DeviceName = "Error"; LastSync = "N/A"
                Ownership = "N/A"; Status = "Error"; Message = $_.Exception.Message
            }
        }

        Start-Sleep -Milliseconds 500  # Throttling protection
    }

    Write-Host "`nRetire operation completed." -ForegroundColor Cyan
    $retiredCount = ($results["Status"] | Where-Object { $_ -eq "Retired" }).Count
    $skippedCount = ($results["Status"] | Where-Object { $_ -eq "Skipped" }).Count
    $errorCount = ($results["Status"] | Where-Object { $_ -eq "Error" -or $_ -eq "Not Found" }).Count
    Write-Host "Summary: Retired=$retiredCount, Skipped=$skippedCount, Errors=$errorCount" -ForegroundColor Cyan
    
    return $results
}

function Get-IntuneAutopilotInfo {
    param (
        [string]$FilePath
    )

    Write-AppLog -Message "Getting Autopilot information" -Level "DEBUG" -Details "File: $FilePath"
    Write-Host "Getting Autopilot information for devices in: $FilePath" -ForegroundColor Cyan

    # Define the result keys for this function
    $resultKeys = @("DeviceName", "LastSyncDateTime", "Ownership", "EntraID", "IntuneID", "AutopilotInfo")

    # Scriptblock to process a single device - note: this function only accepts EntraID IDs
    $processDevice = {
        param([string]$DeviceID, [string]$IDType)
        
        try {
            # Get device info from Intune using EntraID ID
            $info = Resolve-DeviceIdentifier -DeviceIdentifier $DeviceID -IDType "EntraID ID" -SelectProperties @("DeviceName", "LastSyncDateTime", "ManagedDeviceOwnerType", "AzureAdDeviceId", "Id")
            
            if ($null -eq $info) {
                Write-Warning "Device with Entra ID '$DeviceID' not found in Intune"
                return @{
                    DeviceName = "Not Found"; LastSyncDateTime = "N/A"; Ownership = "N/A"
                    EntraID = $DeviceID; IntuneID = "N/A"; AutopilotInfo = "Device Not Found"
                }
            }

            # Check Autopilot data
            $url = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=azureActiveDirectoryDeviceId%20eq%20%27$DeviceID%27"
            $apiResponse = Invoke-GraphRequestWithRetry -Uri $url -Method GET
            
            if (-not $apiResponse.Success) {
                Write-Warning "Failed to retrieve Autopilot info for device '$DeviceID': $($apiResponse.Error.Message)"
                return @{
                    DeviceName = $info.DeviceName
                    LastSyncDateTime = $info.LastSyncDateTime
                    Ownership = $info.ManagedDeviceOwnerType
                    EntraID = $info.AzureAdDeviceId
                    IntuneID = $info.Id
                    AutopilotInfo = "API Error: $($apiResponse.Error.Message)"
                }
            }
            
            $autopilotDeviceInfo = $apiResponse.Data.value

            $hasAutopilotData = if (($null -ne $autopilotDeviceInfo) -and ($autopilotDeviceInfo.Count -gt 0)) {
                "Has data in Autopilot"
            } else {
                "Does not have Autopilot data"
            }

            Write-Host "Device: $($info.DeviceName) - $hasAutopilotData" -ForegroundColor $(if ($hasAutopilotData -eq "Has data in Autopilot") { "Green" } else { "Yellow" })

            return @{
                DeviceName = $info.DeviceName
                LastSyncDateTime = $info.LastSyncDateTime
                Ownership = $info.ManagedDeviceOwnerType
                EntraID = $info.AzureAdDeviceId
                IntuneID = $info.Id
                AutopilotInfo = $hasAutopilotData
            }
        }
        catch {
            Write-Error "Error processing device '$DeviceID': $($_.Exception.Message)"
            return @{
                DeviceName = "Error"; LastSyncDateTime = "N/A"; Ownership = "N/A"
                EntraID = $DeviceID; IntuneID = "N/A"; AutopilotInfo = "Error: $($_.Exception.Message)"
            }
        }
    }

    # Process all devices from file - force IDType to EntraID ID since this function only accepts that
    $results = Invoke-ForEachDevice -FilePath $FilePath -IDType "EntraID ID" -ResultKeys $resultKeys -ProcessDevice $processDevice

    Write-Host "`nAutopilot info retrieval completed." -ForegroundColor Cyan
    return $results
}

function Get-EntraUserDetails {
    param (
        [bool]$IsSingleUser,
        [string]$UPNorFilePath
    )

    # Define the result keys for this function
    $resultKeys = @("UserPrincipalName", "DisplayName", "Mail", "JobTitle", "Department", "MobilePhone", "AccountEnabled", "Status")

    # Scriptblock to process a single user
    $processUser = {
        param([string]$UPN)
        
        try {
            Write-Host "Getting user details for: $UPN" -ForegroundColor Cyan
            $user = Get-MgUser -UserId $UPN -Property "DisplayName,UserPrincipalName,Mail,JobTitle,Department,MobilePhone,AccountEnabled" -ErrorAction Stop
            
            if ($null -eq $user) {
                Write-Warning "User '$UPN' not found in Entra ID"
                return @{
                    UserPrincipalName = $UPN; DisplayName = "Not Found"; Mail = "N/A"
                    JobTitle = "N/A"; Department = "N/A"; MobilePhone = "N/A"
                    AccountEnabled = "N/A"; Status = "User Not Found"
                }
            }
            
            return @{
                UserPrincipalName = $user.UserPrincipalName
                DisplayName = $user.DisplayName
                Mail = if ($null -ne $user.Mail) { $user.Mail } else { "N/A" }
                JobTitle = if ($null -ne $user.JobTitle) { $user.JobTitle } else { "N/A" }
                Department = if ($null -ne $user.Department) { $user.Department } else { "N/A" }
                MobilePhone = if ($null -ne $user.MobilePhone) { $user.MobilePhone } else { "N/A" }
                AccountEnabled = $user.AccountEnabled
                Status = "Success"
            }
        }
        catch {
            Write-Error "Error getting user '$UPN': $($_.Exception.Message)"
            return @{
                UserPrincipalName = $UPN; DisplayName = "Error"; Mail = "N/A"
                JobTitle = "N/A"; Department = "N/A"; MobilePhone = "N/A"
                AccountEnabled = "N/A"; Status = "Error: $($_.Exception.Message)"
            }
        }
    }

    if ($IsSingleUser) {
        # Single user lookup
        return (& $processUser $UPNorFilePath)
    }
    else {
        # Multiple users from file
        if (-not (Test-Path $UPNorFilePath)) {
            Write-Error "File not found: $UPNorFilePath"
            return $null
        }

        $upnList = Get-Content -Path $UPNorFilePath -Encoding UTF8 | Where-Object { $_ -match '\S' }
        
        if ($null -eq $upnList -or $upnList.Count -eq 0) {
            Write-Warning "No UPNs found in file: $UPNorFilePath"
            return $null
        }

        # Initialize results using helper
        $results = New-ResultsHashtable -Keys $resultKeys

        $counter = 1
        $totalUsers = $upnList.Count
        Write-Host "Processing $totalUsers users..." -ForegroundColor Yellow

        foreach ($upn in $upnList) {
            Write-Host "`nProcessing user $counter of $totalUsers : $upn" -ForegroundColor Cyan
            $counter++
            
            $userInfo = & $processUser $upn.Trim()
            Add-ResultToHashtable -Results $results -SingleResult $userInfo
            
            Start-Sleep -Milliseconds 300  # Throttling protection
        }

        Write-Host "`nUser details retrieval completed. Processed $totalUsers users." -ForegroundColor Green
        return $results
    }
}

function Get-PolicyNonComplianceSettings {
    param (
        [string]$FilePath,
        [string]$DesiredID,
        [string]$PolicyID
    )

    $resultKeys = @("DeviceID", "DeviceName", "SettingName", "SettingStatus", "ErrorCode", "ErrorType", "ErrorMessage")

    # Define processing logic for each device - returns array of results (one per non-compliant setting)
    $processDevice = {
        param([string]$DeviceID, [string]$IDType)
        
        $deviceResults = @()
        
        # Use helper to resolve device - this replaces the internal Get-IntuneDeviceId function
        $deviceInfo = Resolve-DeviceIdentifier -DeviceIdentifier $DeviceID -IDType $IDType
        
        if ($null -eq $deviceInfo) {
            Write-Warning "Could not find device: $DeviceID"
            return @{
                DeviceID = $DeviceID
                DeviceName = "Not Found"
                SettingName = "N/A"
                SettingStatus = "Device Not Found"
                ErrorCode = "N/A"
                ErrorType = "N/A"
                ErrorMessage = "Could not resolve device identifier"
            }
        }
        
        $intuneDeviceId = $deviceInfo.Id
        $deviceName = $deviceInfo.DeviceName
        Write-Host "  Intune ID: $intuneDeviceId, Device Name: $deviceName" -ForegroundColor Gray

        try {
            # Define the request body
            $safePolicyID = ConvertTo-SafeFilterString -InputString $PolicyID
            $bodyObject = @{
                select   = @()
                filter   = "(PolicyId eq '$safePolicyID') and (DeviceId eq '$intuneDeviceId') and (UserId eq '00000000-0000-0000-0000-000000000000')"
                top      = 50
                orderBy  = @("SettingName")
            }

            # Convert to JSON
            $bodyJson = $bodyObject | ConvertTo-Json -Depth 3 -Compress

            # Make the POST request with retry logic
            $uri = "https://graph.microsoft.com/beta/deviceManagement/reports/getConfigurationSettingNonComplianceReport"
            $apiResponse = Invoke-GraphRequestWithRetry -Uri $uri -Method POST -Body $bodyJson
            
            if (-not $apiResponse.Success) {
                Write-Error "API request failed for device '$DeviceID': $($apiResponse.Error.Message)"
                $deviceResults += @{
                    DeviceID = $DeviceID
                    DeviceName = $deviceName
                    SettingName = "N/A"
                    SettingStatus = "API Error"
                    ErrorCode = "N/A"
                    ErrorType = "API Error"
                    ErrorMessage = $apiResponse.Error.Message
                }
                return $deviceResults
            }
            
            $response = $apiResponse.Data

            # Process the response - may have multiple non-compliant settings
            if ($null -ne $response.values -and $response.values.Count -gt 0) {
                foreach ($item in $response.values) {
                    Write-Host "  Found non-compliant setting: $($item[12])" -ForegroundColor Yellow
                    
                    $deviceResults += @{
                        DeviceID = $DeviceID
                        DeviceName = $deviceName
                        SettingName = if ($null -ne $item[12]) { $item[12] } else { "N/A" }
                        SettingStatus = if ($null -ne $item[8]) { $item[8] } else { "N/A" }
                        ErrorCode = if ($null -ne $item[10]) { $item[10] } else { "N/A" }
                        ErrorType = if ($null -ne $item[9]) { $item[9] } else { "N/A" }
                        ErrorMessage = if ($null -ne $item[11]) { $item[11] } else { "N/A" }
                    }
                }
            } else {
                Write-Host "  No non-compliant settings found for this device" -ForegroundColor Green
                $deviceResults += @{
                    DeviceID = $DeviceID
                    DeviceName = $deviceName
                    SettingName = "N/A"
                    SettingStatus = "Compliant"
                    ErrorCode = "N/A"
                    ErrorType = "N/A"
                    ErrorMessage = "No non-compliant settings found for this policy"
                }
            }
        }
        catch {
            Write-Error "Error fetching non-compliance report for device '$DeviceID': $($_.Exception.Message)"
            $deviceResults += @{
                DeviceID = $DeviceID
                DeviceName = $deviceName
                SettingName = "N/A"
                SettingStatus = "Error"
                ErrorCode = "N/A"
                ErrorType = "API Error"
                ErrorMessage = $_.Exception.Message
            }
        }

        return $deviceResults
    }

    # Validate file exists using helper
    $fileValidation = Test-FilePath -FilePath $FilePath -ParameterName "FilePath"
    if (-not $fileValidation.IsValid) {
        Write-Error $fileValidation.ErrorMessage
        return $null
    }

    # Read device IDs from file
    $deviceIdentifiers = Get-Content $FilePath -ErrorAction Stop | Where-Object { $_ -match '\S' }

    # Initialize results using helper
    $results = New-ResultsHashtable -Keys $resultKeys

    $counter = 1
    $totalDevices = $deviceIdentifiers.Count

    Write-Host "Processing $totalDevices devices for policy non-compliance settings..." -ForegroundColor Cyan
    Write-Host "Policy ID: $PolicyID" -ForegroundColor Yellow

    foreach ($deviceIdentifier in $deviceIdentifiers) {
        $deviceIdentifier = $deviceIdentifier.Trim()
        Write-Host "`nProcessing device $counter of $totalDevices : $deviceIdentifier" -ForegroundColor Cyan
        $counter++

        # Process device - may return multiple results (one per non-compliant setting)
        $deviceResults = & $processDevice $deviceIdentifier $DesiredID
        
        # Handle single or multiple results
        if ($deviceResults -is [array] -and $deviceResults.Count -gt 0 -and $deviceResults[0] -is [hashtable]) {
            foreach ($result in $deviceResults) {
                Add-ResultToHashtable -Results $results -SingleResult $result
            }
        } elseif ($deviceResults -is [hashtable]) {
            Add-ResultToHashtable -Results $results -SingleResult $deviceResults
        }

        Start-Sleep -Milliseconds 500  # Throttling protection
    }

    Write-Host "`nPolicy non-compliance report completed. Processed $totalDevices devices." -ForegroundColor Cyan
    return $results
}

function Update-AutopilotGroupTag {
    param (
        [string]$FilePath,
        [string]$GroupTag
    )

    $resultKeys = @("SerialNumber", "DeviceId", "Status", "Message")

    # Define processing logic for each serial number
    $processDevice = {
        param([string]$Serial)
        
        $deviceId = $null
        
        # Get the Autopilot device by serial number with retry logic
        $safeSerial = ConvertTo-SafeFilterString -InputString $Serial
        $uri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities?`$filter=contains(serialNumber,'$safeSerial')"
        $apiResponse = Invoke-GraphRequestWithRetry -Uri $uri -Method GET
        
        if (-not $apiResponse.Success) {
            Write-Error "API request failed for serial '$Serial': $($apiResponse.Error.Message)"
            return @{
                SerialNumber = $Serial
                DeviceId = "N/A"
                Status = "API Error"
                Message = $apiResponse.Error.Message
            }
        }
        
        $autopilotDevice = $apiResponse.Data.value | Where-Object { $_.serialNumber -eq $Serial } | Select-Object -First 1

        if ($null -eq $autopilotDevice) {
            Write-Warning "Autopilot device not found for serial: $Serial"
            return @{
                SerialNumber = $Serial
                DeviceId = "N/A"
                Status = "Not Found"
                Message = "Device not found in Autopilot"
            }
        }

        $deviceId = $autopilotDevice.id
        Write-Host "  Found Autopilot device ID: $deviceId" -ForegroundColor Gray

        # Update the group tag using POST request with retry logic
        $updateUri = "https://graph.microsoft.com/beta/deviceManagement/windowsAutopilotDeviceIdentities/$deviceId/updateDeviceProperties"
        $body = @{
            groupTag = $GroupTag
        } | ConvertTo-Json

        $updateResponse = Invoke-GraphRequestWithRetry -Uri $updateUri -Method POST -Body $body
        
        if (-not $updateResponse.Success) {
            Write-Error "Failed to update group tag for '$Serial': $($updateResponse.Error.Message)"
            return @{
                SerialNumber = $Serial
                DeviceId = $deviceId
                Status = "Update Failed"
                Message = $updateResponse.Error.Message
            }
        }

        Write-Host "  Successfully updated group tag for: $Serial" -ForegroundColor Green
        return @{
            SerialNumber = $Serial
            DeviceId = $deviceId
            Status = "Updated"
            Message = "Group tag updated to: $GroupTag"
        }
    }

    # Validate file exists using helper
    $fileValidation = Test-FilePath -FilePath $FilePath -ParameterName "FilePath"
    if (-not $fileValidation.IsValid) {
        Write-Error $fileValidation.ErrorMessage
        return $null
    }

    # Read serial numbers from file
    $serialNumbers = Get-Content $FilePath -ErrorAction Stop | Where-Object { $_ -match '\S' }

    # Initialize results using helper
    $results = New-ResultsHashtable -Keys $resultKeys

    $counter = 1
    $totalDevices = $serialNumbers.Count

    Write-Host "Updating Autopilot Group Tag for $totalDevices devices..." -ForegroundColor Cyan
    Write-Host "New Group Tag: $GroupTag" -ForegroundColor Yellow

    foreach ($serial in $serialNumbers) {
        $serial = $serial.Trim()
        Write-Host "`nProcessing device $counter of $totalDevices : $serial" -ForegroundColor Cyan
        $counter++

        $deviceResult = & $processDevice $serial
        Add-ResultToHashtable -Results $results -SingleResult $deviceResult

        Start-Sleep -Milliseconds 500  # Throttling protection
    }

    Write-Host "`nAutopilot Group Tag update completed. Processed $totalDevices devices." -ForegroundColor Cyan
    return $results
}

<#
.SYNOPSIS
    Retrieves TPM and BIOS information from all Intune-managed Windows devices.

.DESCRIPTION
    Connects to Microsoft Graph API to fetch hardware information (TPM version, BIOS version, 
    storage, memory, etc.) from corporate-managed Windows devices. Supports both PowerShell 5.1 
    (sequential processing) and PowerShell 7+ (parallel processing with throttling).

.PARAMETER BatchSize
    Number of devices to process per batch. Default is 20. Valid range: 1-100.

.PARAMETER ThrottleLimit
    Throttle limit for parallel processing in PowerShell 7+. Default is 10. Valid range: 1-20.

.OUTPUTS
    Hashtable with arrays for each property, compatible with FillDataListView.

.NOTES
    Requires: DeviceManagementManagedDevices.Read.All permission
    Filter: Windows corporate-managed MDM devices only

.EXAMPLE
    $results = Get-TPMAndBIOSInfo
    Returns TPM/BIOS info for all corporate Windows devices with default settings.

.EXAMPLE
    $results = Get-TPMAndBIOSInfo -BatchSize 50 -ThrottleLimit 15
    Returns TPM/BIOS info with custom batch size and throttle limit.
#>
function Get-TPMAndBIOSInfo {
    [CmdletBinding()]
    param(
        [Parameter(HelpMessage = "Number of devices to process per batch")]
        [ValidateRange(1, 100)]
        [int]$BatchSize = 20,

        [Parameter(HelpMessage = "Throttle limit for parallel processing (PS7+)")]
        [ValidateRange(1, 20)]
        [int]$ThrottleLimit = 10
    )

    # Configuration
    $graphBaseUri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices"
    $deviceFilter = "OperatingSystem eq 'Windows' and ManagedDeviceOwnerType eq 'company' and ManagementAgent eq 'mdm'"
    $deviceProperties = "Id,DeviceName,SerialNumber,UserPrincipalName,UserDisplayName,Model,Manufacturer,ComplianceState,IsEncrypted,LastSyncDateTime,EnrolledDateTime,OsVersion"

    # Statistics tracking
    $stats = @{
        TotalDevices   = 0
        ProcessedCount = 0
        SuccessCount   = 0
        FailedCount    = 0
        StartTime      = Get-Date
    }

    Write-AppLog -Message "Starting TPM and BIOS Information Collection" -Level "REPORT"
    Write-AppLog -Message "PowerShell Version: $($PSVersionTable.PSVersion)" -Level "DEBUG"
    Write-AppLog -Message "Batch Size: $BatchSize | Throttle Limit: $ThrottleLimit" -Level "DEBUG"

    try {
        # Step 1: Fetch all managed devices
        Write-Host "Fetching managed devices from Intune..." -ForegroundColor Cyan
        Write-AppLog -Message "Fetching managed devices" -Level "INFO" -Details "Filter: $deviceFilter"

        $devices = Get-MgDeviceManagementManagedDevice -All -Filter $deviceFilter -Property $deviceProperties -ErrorAction Stop

        if (-not $devices -or $devices.Count -eq 0) {
            Write-AppLog -Message "No devices found matching filter criteria" -Level "WARNING"
            return $null
        }

        $stats.TotalDevices = $devices.Count
        Write-Host "Found $($devices.Count) managed device(s)" -ForegroundColor Green
        Write-AppLog -Message "Devices found" -Level "INFO" -Details "Count: $($devices.Count)"

        # Initialize results collection
        $allResults = [System.Collections.ArrayList]::new()
        $isPowerShell7 = $PSVersionTable.PSVersion.Major -ge 7

        if ($isPowerShell7) {
            Write-Host "PowerShell 7+ detected - using parallel processing (ThrottleLimit: $ThrottleLimit)" -ForegroundColor Yellow
            Write-AppLog -Message "Using parallel processing" -Level "INFO" -Details "ThrottleLimit: $ThrottleLimit"
        } else {
            Write-Host "PowerShell 5.1 detected - using sequential processing" -ForegroundColor Yellow
            Write-AppLog -Message "Using sequential processing (PowerShell 5.1)" -Level "INFO"
        }

        # Step 2: Process devices in batches
        $totalBatches = [Math]::Ceiling($devices.Count / $BatchSize)
        Write-Host "Processing $($devices.Count) device(s) in $totalBatches batch(es)..." -ForegroundColor Cyan

        for ($i = 0; $i -lt $devices.Count; $i += $BatchSize) {
            $batchNumber = [Math]::Floor($i / $BatchSize) + 1
            $batchEnd = [Math]::Min($i + $BatchSize - 1, $devices.Count - 1)
            $batch = $devices[$i..$batchEnd]

            # Handle single device case (array slicing returns single object)
            if ($batch -isnot [array]) {
                $batch = @($batch)
            }

            Write-Host "Processing batch $batchNumber of $totalBatches ($($batch.Count) device(s))..." -ForegroundColor Yellow

            if ($isPowerShell7) {
                # PowerShell 7+ with parallel processing
                $batchResults = $batch | ForEach-Object -ThrottleLimit $ThrottleLimit -Parallel {
                    $graphUri = $using:graphBaseUri
                    $device = $_
                    
                    try {
                        $deviceId = $device.Id
                        $uri = "$graphUri('$deviceId')?`$select=hardwareInformation"
                        
                        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
                        $hw = $response.hardwareInformation

                        [PSCustomObject]@{
                            DeviceName              = $device.DeviceName
                            SerialNumber            = $device.SerialNumber
                            UserPrincipalName       = $device.UserPrincipalName
                            UserDisplayName         = $device.UserDisplayName
                            Model                   = $device.Model
                            Manufacturer            = $device.Manufacturer
                            ComplianceState         = $device.ComplianceState
                            IsEncrypted             = $device.IsEncrypted
                            LastSyncDateTime        = $device.LastSyncDateTime
                            EnrolledDateTime        = $device.EnrolledDateTime
                            OsVersion               = $device.OsVersion
                            OSBuildNumber           = $hw.osBuildNumber
                            TPMVersion              = $hw.tpmVersion
                            TPMSpecificationVersion = $hw.tpmSpecificationVersion
                            TPMManufacturer         = $hw.tpmManufacturer
                            BIOSVersion             = $hw.systemManagementBIOSVersion
                            TotalStorageSpaceGB     = if ($hw.totalStorageSpace) { [Math]::Round($hw.totalStorageSpace / 1GB, 2) } else { $null }
                            FreeStorageSpaceGB      = if ($hw.freeStorageSpace) { [Math]::Round($hw.freeStorageSpace / 1GB, 2) } else { $null }
                            PhysicalMemoryGB        = if ($hw.physicalMemoryInBytes) { [Math]::Round($hw.physicalMemoryInBytes / 1GB, 2) } else { $null }
                            Status                  = "Success"
                            ErrorMessage            = $null
                        }
                    }
                    catch {
                        [PSCustomObject]@{
                            DeviceName              = $device.DeviceName
                            SerialNumber            = $device.SerialNumber
                            UserPrincipalName       = $device.UserPrincipalName
                            UserDisplayName         = $null
                            Model                   = $device.Model
                            Manufacturer            = $device.Manufacturer
                            ComplianceState         = $null
                            IsEncrypted             = $null
                            LastSyncDateTime        = $null
                            EnrolledDateTime        = $null
                            OsVersion               = $null
                            OSBuildNumber           = $null
                            TPMVersion              = $null
                            TPMSpecificationVersion = $null
                            TPMManufacturer         = $null
                            BIOSVersion             = $null
                            TotalStorageSpaceGB     = $null
                            FreeStorageSpaceGB      = $null
                            PhysicalMemoryGB        = $null
                            Status                  = "Failed"
                            ErrorMessage            = $_.Exception.Message
                        }
                    }
                }
            }
            else {
                # PowerShell 5.1 with sequential processing
                $batchResults = foreach ($device in $batch) {
                    try {
                        $deviceId = $device.Id
                        $uri = "$graphBaseUri('$deviceId')?`$select=hardwareInformation"
                        
                        $response = Invoke-MgGraphRequest -Method GET -Uri $uri -ErrorAction Stop
                        $hw = $response.hardwareInformation

                        [PSCustomObject]@{
                            DeviceName              = $device.DeviceName
                            SerialNumber            = $device.SerialNumber
                            UserPrincipalName       = $device.UserPrincipalName
                            UserDisplayName         = $device.UserDisplayName
                            Model                   = $device.Model
                            Manufacturer            = $device.Manufacturer
                            ComplianceState         = $device.ComplianceState
                            IsEncrypted             = $device.IsEncrypted
                            LastSyncDateTime        = $device.LastSyncDateTime
                            EnrolledDateTime        = $device.EnrolledDateTime
                            OsVersion               = $device.OsVersion
                            OSBuildNumber           = $hw.osBuildNumber
                            TPMVersion              = $hw.tpmVersion
                            TPMSpecificationVersion = $hw.tpmSpecificationVersion
                            TPMManufacturer         = $hw.tpmManufacturer
                            BIOSVersion             = $hw.systemManagementBIOSVersion
                            TotalStorageSpaceGB     = if ($hw.totalStorageSpace) { [Math]::Round($hw.totalStorageSpace / 1GB, 2) } else { $null }
                            FreeStorageSpaceGB      = if ($hw.freeStorageSpace) { [Math]::Round($hw.freeStorageSpace / 1GB, 2) } else { $null }
                            PhysicalMemoryGB        = if ($hw.physicalMemoryInBytes) { [Math]::Round($hw.physicalMemoryInBytes / 1GB, 2) } else { $null }
                            Status                  = "Success"
                            ErrorMessage            = $null
                        }
                    }
                    catch {
                        Write-AppLog -Message "Failed to process device" -Level "WARNING" -Details "Device: $($device.DeviceName), Error: $($_.Exception.Message)"
                        
                        [PSCustomObject]@{
                            DeviceName              = $device.DeviceName
                            SerialNumber            = $device.SerialNumber
                            UserPrincipalName       = $device.UserPrincipalName
                            UserDisplayName         = $null
                            Model                   = $device.Model
                            Manufacturer            = $device.Manufacturer
                            ComplianceState         = $null
                            IsEncrypted             = $null
                            LastSyncDateTime        = $null
                            EnrolledDateTime        = $null
                            OsVersion               = $null
                            OSBuildNumber           = $null
                            TPMVersion              = $null
                            TPMSpecificationVersion = $null
                            TPMManufacturer         = $null
                            BIOSVersion             = $null
                            TotalStorageSpaceGB     = $null
                            FreeStorageSpaceGB      = $null
                            PhysicalMemoryGB        = $null
                            Status                  = "Failed"
                            ErrorMessage            = $_.Exception.Message
                        }
                    }
                }
            }

            # Add results to collection
            $batchResults | Where-Object { $_ -ne $null } | ForEach-Object {
                [void]$allResults.Add($_)
            }

            $stats.ProcessedCount += $batch.Count

            # Update progress
            $percentComplete = [Math]::Round(($stats.ProcessedCount / $devices.Count) * 100, 1)
            Write-Progress -Activity "Processing Devices" `
                -Status "Batch $batchNumber of $totalBatches - $($stats.ProcessedCount) of $($devices.Count) devices" `
                -PercentComplete $percentComplete
        }

        Write-Progress -Activity "Processing Devices" -Completed

        # Step 3: Calculate statistics
        $stats.SuccessCount = ($allResults | Where-Object { $_.Status -eq "Success" }).Count
        $stats.FailedCount = ($allResults | Where-Object { $_.Status -eq "Failed" }).Count
        $duration = (Get-Date) - $stats.StartTime

        Write-Host "`n========== EXECUTION SUMMARY ==========" -ForegroundColor Cyan
        Write-Host "  Total Devices Found:      $($stats.TotalDevices)" -ForegroundColor White
        Write-Host "  Successfully Processed:   $($stats.SuccessCount)" -ForegroundColor Green
        Write-Host "  Failed:                   $($stats.FailedCount)" -ForegroundColor $(if ($stats.FailedCount -gt 0) { "Red" } else { "Green" })
        Write-Host "  Execution Time:           $($duration.ToString('hh\:mm\:ss'))" -ForegroundColor White
        Write-Host "========================================`n" -ForegroundColor Cyan

        Write-AppLog -Message "TPM/BIOS info collection completed" -Level "REPORT" -Details "Total: $($stats.TotalDevices), Success: $($stats.SuccessCount), Failed: $($stats.FailedCount), Duration: $($duration.ToString('hh\:mm\:ss'))"

        # Step 4: Convert to hashtable format for FillDataListView
        $Headers = @(
            "DeviceName", "SerialNumber", "UserPrincipalName", "UserDisplayName",
            "Model", "Manufacturer", "ComplianceState", "IsEncrypted",
            "LastSyncDateTime", "EnrolledDateTime", "OsVersion", "OSBuildNumber",
            "TPMVersion", "TPMSpecificationVersion", "TPMManufacturer", "BIOSVersion",
            "TotalStorageSpaceGB", "FreeStorageSpaceGB", "PhysicalMemoryGB", "Status", "ErrorMessage"
        )

        $results = @{}
        foreach ($header in $Headers) {
            $results[$header] = @()
        }

        foreach ($item in $allResults) {
            foreach ($header in $Headers) {
                $results[$header] += $item.$header
            }
        }

        # Also return the raw results for CSV export
        $results["_RawResults"] = $allResults

        return $results
    }
    catch {
        Write-AppLog -Message "TPM/BIOS info collection failed" -Level "ERROR" -Details $_.Exception.Message
        Write-Host "Failed to retrieve TPM/BIOS info: $($_.Exception.Message)" -ForegroundColor Red
        throw
    }
    finally {
        Write-Progress -Activity "Processing Devices" -Completed -ErrorAction SilentlyContinue
    }
}

#region ==================== DETECTED APPS ====================
function Get-IntuneDetectedApps {
    <#
    .SYNOPSIS
        Retrieves detected/discovered apps for Intune managed devices.
    
    .DESCRIPTION
        Queries the Microsoft Graph API to get all detected applications installed on 
        the specified device(s). Supports single device lookup or batch processing 
        from a file. Handles API paging automatically.
    
    .PARAMETER IsSingleDevice
        Boolean indicating whether this is a single device lookup or batch processing.
    
    .PARAMETER IDorFilePath
        For single device: the device identifier (name, serial, ID).
        For multiple devices: path to a text file containing device identifiers.
    
    .PARAMETER DesiredID
        The type of identifier being provided: "Device Name", "Serial Number", 
        "Intune ID", or "EntraID ID".
    
    .EXAMPLE
        Get-IntuneDetectedApps -IsSingleDevice $true -IDorFilePath "LAPTOP-001" -DesiredID "Device Name"
    
    .EXAMPLE
        Get-IntuneDetectedApps -IsSingleDevice $false -IDorFilePath "C:\devices.txt" -DesiredID "Serial Number"
    #>
    param (
        [Parameter(Mandatory=$true)]
        [bool]$IsSingleDevice,
        
        [Parameter(Mandatory=$true)]
        [string]$IDorFilePath,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("EntraID ID", "Intune ID", "Device Name", "Serial Number")]
        [string]$DesiredID
    )

    Write-AppLog -Message "Get-IntuneDetectedApps starting" -Level "DEBUG" -Details "IsSingle: $IsSingleDevice, ID/Path: $IDorFilePath, IDType: $DesiredID"

    # Result keys for the output hashtable
    $resultKeys = @("DeviceName", "IntuneDeviceId", "AppDisplayName", "AppVersion", "SizeInByte", "DeviceCount")

    # Scriptblock to process a single device and retrieve its detected apps
    $processDevice = {
        param([string]$DeviceID, [string]$IDType)
        
        Write-AppLog -Message "Processing device for detected apps" -Level "DEBUG" -Details "Device: $DeviceID, Type: $IDType"
        
        try {
            # Resolve the device identifier to get the Intune managed device ID
            $deviceInfo = Resolve-DeviceIdentifier -DeviceIdentifier $DeviceID -IDType $IDType
            
            if ($null -eq $deviceInfo) {
                Write-Warning "Device not found: $DeviceID"
                return @{
                    DeviceName = $DeviceID
                    IntuneDeviceId = "Not Found"
                    AppDisplayName = "N/A"
                    AppVersion = "N/A"
                    SizeInByte = "N/A"
                    DeviceCount = "N/A"
                    _Status = "Device Not Found"
                }
            }

            $intuneDeviceId = $deviceInfo.Id
            $deviceName = $deviceInfo.DeviceName
            Write-Host "Fetching detected apps for device: $deviceName ($intuneDeviceId)" -ForegroundColor Cyan

            # Query the detected apps endpoint with paging support
            $detectedAppsUrl = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$intuneDeviceId')/detectedApps?`$top=50"
            
            $allApps = @()
            $currentUrl = $detectedAppsUrl
            $pageCount = 0

            while ($null -ne $currentUrl -and $currentUrl -ne "") {
                $pageCount++
                Write-AppLog -Message "Fetching detected apps page $pageCount" -Level "DEBUG" -Details "Device: $deviceName"
                
                try {
                    $response = Invoke-MgGraphRequest -Method GET -Uri $currentUrl -ErrorAction Stop
                    
                    if ($response.value) {
                        $allApps += $response.value
                    }
                    
                    # Get next page URL if exists
                    $currentUrl = $response.'@odata.nextLink'
                    
                    # Small delay between pages to avoid throttling
                    if ($null -ne $currentUrl) {
                        Start-Sleep -Milliseconds 100
                    }
                }
                catch {
                    $errorMsg = $_.Exception.Message
                    
                    # Check for specific error types
                    if ($errorMsg -match "403|Forbidden|Authorization") {
                        Write-Warning "Permission denied accessing detected apps for $deviceName"
                        return @{
                            DeviceName = $deviceName
                            IntuneDeviceId = $intuneDeviceId
                            AppDisplayName = "Permission Denied"
                            AppVersion = "N/A"
                            SizeInByte = "N/A"
                            DeviceCount = "N/A"
                            _Status = "Permission Error"
                        }
                    }
                    elseif ($errorMsg -match "429|Too Many Requests") {
                        Write-Warning "Rate limited while fetching apps for $deviceName. Waiting and retrying..."
                        Start-Sleep -Seconds 5
                        # Don't update $currentUrl, will retry same page
                    }
                    else {
                        Write-Error "Error fetching detected apps for $deviceName`: $errorMsg"
                        return @{
                            DeviceName = $deviceName
                            IntuneDeviceId = $intuneDeviceId
                            AppDisplayName = "Error"
                            AppVersion = "N/A"
                            SizeInByte = "N/A"
                            DeviceCount = "N/A"
                            _Status = "API Error: $errorMsg"
                        }
                    }
                }
            }

            Write-Host "  Found $($allApps.Count) detected apps for $deviceName" -ForegroundColor Green
            Write-AppLog -Message "Detected apps retrieved" -Level "DEBUG" -Details "Device: $deviceName, Apps Count: $($allApps.Count)"

            # If no apps found, return a single row indicating that
            if ($allApps.Count -eq 0) {
                return @{
                    DeviceName = $deviceName
                    IntuneDeviceId = $intuneDeviceId
                    AppDisplayName = "(No apps detected)"
                    AppVersion = "N/A"
                    SizeInByte = "N/A"
                    DeviceCount = "N/A"
                    _Status = "Success - No Apps"
                }
            }

            # Return array of app results for this device
            # Each app becomes a separate result row
            $appResults = @()
            foreach ($app in $allApps) {
                $appResults += @{
                    DeviceName = $deviceName
                    IntuneDeviceId = $intuneDeviceId
                    AppDisplayName = if ($app.displayName) { $app.displayName } else { "Unknown" }
                    AppVersion = if ($app.version) { $app.version } else { "N/A" }
                    SizeInByte = if ($app.sizeInByte) { $app.sizeInByte } else { "N/A" }
                    DeviceCount = if ($app.deviceCount) { $app.deviceCount } else { "N/A" }
                    _Status = "Success"
                }
            }
            
            return $appResults
        }
        catch {
            Write-Error "Unexpected error processing device '$DeviceID': $($_.Exception.Message)"
            return @{
                DeviceName = $DeviceID
                IntuneDeviceId = "Error"
                AppDisplayName = "Error"
                AppVersion = "N/A"
                SizeInByte = "N/A"
                DeviceCount = "N/A"
                _Status = "Error: $($_.Exception.Message)"
            }
        }
    }

    if ($IsSingleDevice) {
        # Process single device
        $result = & $processDevice $IDorFilePath $DesiredID
        
        # Convert result(s) to hashtable format for UI
        $output = New-ResultsHashtable -Keys $resultKeys
        
        if ($result -is [array]) {
            # Multiple apps returned
            foreach ($appResult in $result) {
                Add-ResultToHashtable -Results $output -SingleResult $appResult
            }
        } else {
            # Single result (error or no apps)
            Add-ResultToHashtable -Results $output -SingleResult $result
        }
        
        return $output
    }
    else {
        # Process multiple devices from file
        # Validate file exists
        if (-not (Test-Path $IDorFilePath)) {
            Write-Error "File not found: $IDorFilePath"
            return $null
        }
        
        # Read device identifiers from file
        $deviceIDs = Get-Content -Path $IDorFilePath -Encoding UTF8 | 
            Where-Object { $_ -match '\S' } | 
            ForEach-Object { $_.Trim() }
        
        if ($deviceIDs.Count -eq 0) {
            Write-Error "No device identifiers found in file: $IDorFilePath"
            return $null
        }
        
        Write-Host "Processing $($deviceIDs.Count) devices for detected apps..." -ForegroundColor Yellow
        
        # Initialize results hashtable
        $results = New-ResultsHashtable -Keys $resultKeys
        $counter = 0
        $totalDevices = $deviceIDs.Count
        
        foreach ($deviceID in $deviceIDs) {
            $counter++
            Write-Host "`nDevice $counter of $totalDevices`: $deviceID" -ForegroundColor Cyan
            
            # Process this device
            $deviceResult = & $processDevice $deviceID $DesiredID
            
            # Add results to collection
            if ($null -ne $deviceResult) {
                if ($deviceResult -is [array]) {
                    foreach ($appResult in $deviceResult) {
                        Add-ResultToHashtable -Results $results -SingleResult $appResult
                    }
                } else {
                    Add-ResultToHashtable -Results $results -SingleResult $deviceResult
                }
            }
            
            # Throttle between devices
            if ($counter -lt $totalDevices) {
                Start-Sleep -Milliseconds 300
            }
        }
        
        Write-Host "`n=== Detected Apps Retrieval Complete ===" -ForegroundColor Cyan
        Write-Host "Devices processed: $totalDevices" -ForegroundColor White
        Write-Host "Total app entries: $($results['AppDisplayName'].Count)" -ForegroundColor White
        
        return $results
    }
}
#endregion ==================== DETECTED APPS ====================

#region ==================== DEVICE CLEANUP / DELETE RECORDS ====================
function Remove-IntuneDeviceRecords {
    <#
    .SYNOPSIS
        Deletes device records from Intune, Autopilot, and Entra ID.
    
    .DESCRIPTION
        Performs a complete device cleanup by deleting records from:
        1. Intune Managed Devices
        2. Windows Autopilot device identities
        3. Entra ID (Azure AD) device objects
        
        Each step is isolated so failures don't stop subsequent steps.
        Supports WhatIf mode for dry runs.
    
    .PARAMETER FilePath
        Path to a text file containing device identifiers (one per line).
    
    .PARAMETER DesiredID
        The type of identifier in the file: "Serial Number", "Device Name", or "Intune ID".
    
    .PARAMETER DeleteIntune
        Whether to delete the Intune managed device record. Default: $true
    
    .PARAMETER DeleteAutopilot
        Whether to delete the Autopilot device identity. Default: $true
    
    .PARAMETER DeleteEntraId
        Whether to delete the Entra ID device object. Default: $true
    
    .PARAMETER WhatIf
        If $true, performs a dry run without actually deleting anything. Default: $true
    
    .EXAMPLE
        Remove-IntuneDeviceRecords -FilePath "C:\devices.txt" -DesiredID "Serial Number" -WhatIf $true
    
    .EXAMPLE
        Remove-IntuneDeviceRecords -FilePath "C:\devices.txt" -DesiredID "Device Name" -WhatIf $false
    #>
    param (
        [Parameter(Mandatory=$true)]
        [string]$FilePath,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("Serial Number", "Device Name", "Intune ID")]
        [string]$DesiredID,
        
        [Parameter(Mandatory=$false)]
        [bool]$DeleteIntune = $true,
        
        [Parameter(Mandatory=$false)]
        [bool]$DeleteAutopilot = $true,
        
        [Parameter(Mandatory=$false)]
        [bool]$DeleteEntraId = $true,
        
        [Parameter(Mandatory=$false)]
        [bool]$WhatIf = $true
    )

    $modeText = if ($WhatIf) { "DRY RUN (WhatIf)" } else { "LIVE DELETION" }
    Write-Host "=== Remove-IntuneDeviceRecords Starting ===" -ForegroundColor $(if ($WhatIf) { "Yellow" } else { "Red" })
    Write-Host "Mode: $modeText" -ForegroundColor $(if ($WhatIf) { "Yellow" } else { "Red" })
    Write-AppLog -Message "Remove-IntuneDeviceRecords starting" -Level "ACTION" -Details "Mode: $modeText, IDType: $DesiredID, DeleteIntune: $DeleteIntune, DeleteAutopilot: $DeleteAutopilot, DeleteEntraId: $DeleteEntraId"

    # Validate file exists
    if (-not (Test-Path $FilePath)) {
        Write-Error "File not found: $FilePath"
        Write-AppLog -Message "File not found" -Level "ERROR" -Details "Path: $FilePath"
        return $null
    }

    # Read device identifiers from file
    $deviceIdentifiers = Get-Content -Path $FilePath -Encoding UTF8 | 
        Where-Object { $_ -match '\S' } | 
        ForEach-Object { $_.Trim() }

    if ($deviceIdentifiers.Count -eq 0) {
        Write-Error "No device identifiers found in file: $FilePath"
        Write-AppLog -Message "No device identifiers in file" -Level "ERROR" -Details "Path: $FilePath"
        return $null
    }

    Write-Host "Processing $($deviceIdentifiers.Count) devices..." -ForegroundColor Yellow
    Write-AppLog -Message "Processing devices" -Level "INFO" -Details "Count: $($deviceIdentifiers.Count)"

    # Initialize results collection
    $results = New-ResultsHashtable -Keys @(
        "InputValue",
        "DeviceName", 
        "SerialNumber",
        "IntuneManagedDeviceId",
        "AutopilotIdentityId",
        "EntraDirectoryObjectId",
        "IntuneDeleteStatus",
        "AutopilotDeleteStatus",
        "EntraDeleteStatus",
        "ErrorIntune",
        "ErrorAutopilot",
        "ErrorEntra",
        "WhatIfMode"
    )

    $counter = 0
    $totalDevices = $deviceIdentifiers.Count

    foreach ($identifier in $deviceIdentifiers) {
        $counter++
        Write-Host "`n[$counter/$totalDevices] Processing: $identifier" -ForegroundColor Cyan
        
        # Initialize result for this device
        $deviceResult = @{
            InputValue = $identifier
            DeviceName = "N/A"
            SerialNumber = "N/A"
            IntuneManagedDeviceId = "N/A"
            AutopilotIdentityId = "N/A"
            EntraDirectoryObjectId = "N/A"
            IntuneDeleteStatus = "Skipped"
            AutopilotDeleteStatus = "Skipped"
            EntraDeleteStatus = "Skipped"
            ErrorIntune = ""
            ErrorAutopilot = ""
            ErrorEntra = ""
            WhatIfMode = $WhatIf
        }

        try {
            # ============================================================
            # STEP 0: Resolve device information from Intune
            # ============================================================
            Write-Host "  Resolving device information..." -ForegroundColor Gray
            
            $intuneDevice = $null
            # Sanitize input for OData filter queries
            $safeIdentifier = ConvertTo-SafeFilterString -InputString $identifier
            try {
                switch ($DesiredID) {
                    "Serial Number" {
                        $intuneDevice = Get-MgDeviceManagementManagedDevice -Filter "serialNumber eq '$safeIdentifier'" -ErrorAction Stop | Select-Object -First 1
                    }
                    "Device Name" {
                        $intuneDevice = Get-MgDeviceManagementManagedDevice -Filter "deviceName eq '$safeIdentifier'" -ErrorAction Stop | Select-Object -First 1
                    }
                    "Intune ID" {
                        $intuneDevice = Get-MgDeviceManagementManagedDevice -ManagedDeviceId $identifier -ErrorAction Stop
                    }
                }
            }
            catch {
                Write-Warning "  Could not resolve device '$identifier': $($_.Exception.Message)"
                $deviceResult.ErrorIntune = "Resolution failed: $($_.Exception.Message)"
            }

            if ($null -eq $intuneDevice) {
                Write-Warning "  Device not found in Intune: $identifier"
                $deviceResult.IntuneDeleteStatus = "Not Found"
                $deviceResult.AutopilotDeleteStatus = "Skipped (no device info)"
                $deviceResult.EntraDeleteStatus = "Skipped (no device info)"
                Add-ResultToHashtable -Results $results -SingleResult $deviceResult
                continue
            }

            # Populate device info
            $deviceResult.DeviceName = $intuneDevice.DeviceName
            $deviceResult.SerialNumber = $intuneDevice.SerialNumber
            $deviceResult.IntuneManagedDeviceId = $intuneDevice.Id
            $azureAdDeviceId = $intuneDevice.AzureAdDeviceId

            Write-Host "  Device: $($intuneDevice.DeviceName) | Serial: $($intuneDevice.SerialNumber) | IntuneID: $($intuneDevice.Id)" -ForegroundColor Green

            # ============================================================
            # STEP 1: Delete Intune Managed Device Record
            # ============================================================
            if ($DeleteIntune) {
                Write-Host "  [Step 1/3] Deleting Intune managed device record..." -ForegroundColor $(if ($WhatIf) { "Yellow" } else { "White" })
                try {
                    if ($WhatIf) {
                        Write-Host "    [WhatIf] Would delete Intune device: $($intuneDevice.Id)" -ForegroundColor Yellow
                        $deviceResult.IntuneDeleteStatus = "WhatIf - Would Delete"
                    }
                    else {
                        Remove-MgDeviceManagementManagedDevice -ManagedDeviceId $intuneDevice.Id -ErrorAction Stop
                        Write-Host "    Intune device deleted successfully" -ForegroundColor Green
                        $deviceResult.IntuneDeleteStatus = "Success"
                        Write-AuditLog -Operation "RecordDelete" -Target $intuneDevice.DeviceName -TargetType "Device" `
                            -BeforeState "Enrolled in Intune" -AfterState "Deleted from Intune" `
                            -Result "Success" -Details "Intune ID: $($intuneDevice.Id), Serial: $($intuneDevice.SerialNumber)"
                        Write-AppLog -Message "Intune device deleted" -Level "ACTION" -Details "DeviceName: $($intuneDevice.DeviceName), ID: $($intuneDevice.Id)"
                        
                        # Brief delay after Intune deletion
                        Start-Sleep -Milliseconds 500
                    }
                }
                catch {
                    $errorMsg = $_.Exception.Message
                    Write-Host "    Failed to delete Intune device: $errorMsg" -ForegroundColor Red
                    $deviceResult.IntuneDeleteStatus = "Failed"
                    $deviceResult.ErrorIntune = $errorMsg
                    Write-AuditLog -Operation "RecordDelete" -Target $intuneDevice.DeviceName -TargetType "Device" `
                        -Result "Failed" -ErrorMessage $errorMsg -Details "Intune deletion failed"
                    Write-AppLog -Message "Failed to delete Intune device" -Level "ERROR" -Details "Device: $($intuneDevice.DeviceName), Error: $errorMsg"
                }
            }

            # ============================================================
            # STEP 2: Delete Autopilot Device Identity
            # ============================================================
            if ($DeleteAutopilot -and -not [string]::IsNullOrEmpty($deviceResult.SerialNumber) -and $deviceResult.SerialNumber -ne "N/A") {
                Write-Host "  [Step 2/3] Deleting Autopilot device identity..." -ForegroundColor $(if ($WhatIf) { "Yellow" } else { "White" })
                try {
                    # Find Autopilot device by serial number (sanitize for OData filter)
                    $serial = $deviceResult.SerialNumber
                    $safeSerial = ConvertTo-SafeFilterString -InputString $serial
                    $autopilotDevice = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -Filter "contains(serialNumber,'$safeSerial')" -ErrorAction Stop | 
                        Where-Object { $_.SerialNumber -eq $serial } | 
                        Select-Object -First 1

                    if ($null -eq $autopilotDevice) {
                        Write-Host "    No Autopilot record found for serial: $serial" -ForegroundColor Gray
                        $deviceResult.AutopilotDeleteStatus = "Not Found"
                    }
                    else {
                        $deviceResult.AutopilotIdentityId = $autopilotDevice.Id
                        
                        if ($WhatIf) {
                            Write-Host "    [WhatIf] Would delete Autopilot device: $($autopilotDevice.Id)" -ForegroundColor Yellow
                            $deviceResult.AutopilotDeleteStatus = "WhatIf - Would Delete"
                        }
                        else {
                            Remove-MgDeviceManagementWindowsAutopilotDeviceIdentity -WindowsAutopilotDeviceIdentityId $autopilotDevice.Id -ErrorAction Stop
                            Write-Host "    Autopilot device deleted successfully" -ForegroundColor Green
                            $deviceResult.AutopilotDeleteStatus = "Success"
                            Write-AuditLog -Operation "RecordDelete" -Target "Serial: $serial" -TargetType "Device" `
                                -BeforeState "Registered in Autopilot" -AfterState "Deleted from Autopilot" `
                                -Result "Success" -Details "Autopilot ID: $($autopilotDevice.Id)"
                            Write-AppLog -Message "Autopilot device deleted" -Level "ACTION" -Details "Serial: $serial, ID: $($autopilotDevice.Id)"
                            
                            # Brief delay after Autopilot deletion
                            Start-Sleep -Milliseconds 500
                        }
                    }
                }
                catch {
                    $errorMsg = $_.Exception.Message
                    Write-Host "    Failed to delete Autopilot device: $errorMsg" -ForegroundColor Red
                    $deviceResult.AutopilotDeleteStatus = "Failed"
                    $deviceResult.ErrorAutopilot = $errorMsg
                    Write-AuditLog -Operation "RecordDelete" -Target "Serial: $($deviceResult.SerialNumber)" -TargetType "Device" `
                        -Result "Failed" -ErrorMessage $errorMsg -Details "Autopilot deletion failed"
                    Write-AppLog -Message "Failed to delete Autopilot device" -Level "ERROR" -Details "Serial: $($deviceResult.SerialNumber), Error: $errorMsg"
                }
            }
            elseif ($DeleteAutopilot) {
                $deviceResult.AutopilotDeleteStatus = "Skipped (no serial)"
            }

            # ============================================================
            # STEP 3: Delete Entra ID Device Object
            # ============================================================
            if ($DeleteEntraId -and -not [string]::IsNullOrEmpty($azureAdDeviceId)) {
                Write-Host "  [Step 3/3] Deleting Entra ID device object..." -ForegroundColor $(if ($WhatIf) { "Yellow" } else { "White" })
                try {
                    # IMPORTANT: Resolve the directory object ID from the AzureAdDeviceId (GUID)
                    # The AzureAdDeviceId is NOT the same as the directory object ID used for deletion
                    $safeAzureAdDeviceId = ConvertTo-SafeFilterString -InputString $azureAdDeviceId
                    $entraDevice = Get-MgDevice -Filter "deviceId eq '$safeAzureAdDeviceId'" -ErrorAction Stop | Select-Object -First 1

                    if ($null -eq $entraDevice) {
                        Write-Host "    No Entra ID device found for AzureAdDeviceId: $azureAdDeviceId" -ForegroundColor Gray
                        $deviceResult.EntraDeleteStatus = "Not Found"
                    }
                    else {
                        $deviceResult.EntraDirectoryObjectId = $entraDevice.Id
                        
                        if ($WhatIf) {
                            Write-Host "    [WhatIf] Would delete Entra device: $($entraDevice.Id) (DisplayName: $($entraDevice.DisplayName))" -ForegroundColor Yellow
                            $deviceResult.EntraDeleteStatus = "WhatIf - Would Delete"
                        }
                        else {
                            # Use the directory object ID (not AzureAdDeviceId) for deletion
                            Remove-MgDevice -DeviceId $entraDevice.Id -ErrorAction Stop
                            Write-Host "    Entra ID device deleted successfully" -ForegroundColor Green
                            $deviceResult.EntraDeleteStatus = "Success"
                            Write-AuditLog -Operation "RecordDelete" -Target $entraDevice.DisplayName -TargetType "Device" `
                                -BeforeState "Registered in Entra ID" -AfterState "Deleted from Entra ID" `
                                -Result "Success" -Details "Object ID: $($entraDevice.Id)"
                            Write-AppLog -Message "Entra ID device deleted" -Level "ACTION" -Details "DisplayName: $($entraDevice.DisplayName), ObjectId: $($entraDevice.Id)"
                            
                            # Brief delay after Entra deletion
                            Start-Sleep -Milliseconds 500
                        }
                    }
                }
                catch {
                    $errorMsg = $_.Exception.Message
                    Write-Host "    Failed to delete Entra ID device: $errorMsg" -ForegroundColor Red
                    $deviceResult.EntraDeleteStatus = "Failed"
                    $deviceResult.ErrorEntra = $errorMsg
                    Write-AuditLog -Operation "RecordDelete" -Target $deviceResult.DeviceName -TargetType "Device" `
                        -Result "Failed" -ErrorMessage $errorMsg -Details "Entra ID deletion failed"
                    Write-AppLog -Message "Failed to delete Entra ID device" -Level "ERROR" -Details "AzureAdDeviceId: $azureAdDeviceId, Error: $errorMsg"
                }
            }
            elseif ($DeleteEntraId) {
                $deviceResult.EntraDeleteStatus = "Skipped (no AzureAdDeviceId)"
            }
        }
        catch {
            Write-Error "  Unexpected error processing device '$identifier': $($_.Exception.Message)"
            $deviceResult.ErrorIntune = "Unexpected: $($_.Exception.Message)"
            Write-AppLog -Message "Unexpected error in device cleanup" -Level "ERROR" -Details "Device: $identifier, Error: $($_.Exception.Message)"
        }

        # Add result to collection
        Add-ResultToHashtable -Results $results -SingleResult $deviceResult

        # Throttle between devices
        if ($counter -lt $totalDevices) {
            Start-Sleep -Milliseconds 300
        }
    }

    # ============================================================
    # Summary
    # ============================================================
    Write-Host "`n=== Device Cleanup Complete ===" -ForegroundColor Cyan
    Write-Host "Mode: $modeText" -ForegroundColor $(if ($WhatIf) { "Yellow" } else { "Green" })
    
    $intuneSuccess = ($results["IntuneDeleteStatus"] | Where-Object { $_ -eq "Success" }).Count
    $intuneFailed = ($results["IntuneDeleteStatus"] | Where-Object { $_ -eq "Failed" }).Count
    $autopilotSuccess = ($results["AutopilotDeleteStatus"] | Where-Object { $_ -eq "Success" }).Count
    $autopilotFailed = ($results["AutopilotDeleteStatus"] | Where-Object { $_ -eq "Failed" }).Count
    $entraSuccess = ($results["EntraDeleteStatus"] | Where-Object { $_ -eq "Success" }).Count
    $entraFailed = ($results["EntraDeleteStatus"] | Where-Object { $_ -eq "Failed" }).Count

    Write-Host "Intune:    Success=$intuneSuccess, Failed=$intuneFailed" -ForegroundColor White
    Write-Host "Autopilot: Success=$autopilotSuccess, Failed=$autopilotFailed" -ForegroundColor White
    Write-Host "Entra ID:  Success=$entraSuccess, Failed=$entraFailed" -ForegroundColor White

    Write-AppLog -Message "Device cleanup completed" -Level "ACTION" -Details "Mode: $modeText, Total: $totalDevices, IntuneSuccess: $intuneSuccess, AutopilotSuccess: $autopilotSuccess, EntraSuccess: $entraSuccess"

    return $results
}
#endregion ==================== DEVICE CLEANUP / DELETE RECORDS ====================

#region ==================== ANDROID APP REINSTALL ====================

function Resolve-DeviceIdsFromInput {
    param(
        [Parameter(Mandatory=$true)] [bool]$IsSingle,
        [Parameter(Mandatory=$true)] [string]$IDorFilePath,
        [Parameter(Mandatory=$true)] [string]$IDType
    )

    $deviceIds = @()
    try {
        if ($IsSingle) {
            # Sanitize input to prevent OData injection
            $value = ConvertTo-SafeFilterString -InputString $IDorFilePath
            Write-Host "Resolving device by $IDType : $value"
            switch ($IDType) {
                'Serial Number'     { $dev = Get-MgDeviceManagementManagedDevice -All -Filter "serialNumber eq '$value'" }
                'Device Name'       { $dev = Get-MgDeviceManagementManagedDevice -All -Filter "deviceName eq '$value'" }
                'EntraID ID'        { $dev = Get-MgDeviceManagementManagedDevice -All -Filter "azureADDeviceId eq '$value'" }
                Default             { $dev = Get-MgDeviceManagementManagedDevice -All -Filter "id eq '$value'" }
            }
            if ($dev) {
                Write-Host "Device found: $($dev.Id)"
                $deviceIds += $dev.Id
            } else {
                Write-Warning "Device not found for value '$value'"
            }
        } else {
            $lines = Get-Content -Path $IDorFilePath -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '\S' }
            Write-Host "Resolving $($lines.Count) device(s) by $IDType"
            foreach ($line in $lines) {
                # Sanitize each line to prevent OData injection
                $value = ConvertTo-SafeFilterString -InputString $line.Trim()
                switch ($IDType) {
                    'Serial Number' { $dev = Get-MgDeviceManagementManagedDevice -All -Filter "serialNumber eq '$value'" }
                    'Device Name'   { $dev = Get-MgDeviceManagementManagedDevice -All -Filter "deviceName eq '$value'" }
                    'EntraID ID'    { $dev = Get-MgDeviceManagementManagedDevice -All -Filter "azureADDeviceId eq '$value'" }
                    Default         { $dev = Get-MgDeviceManagementManagedDevice -All -Filter "id eq '$value'" }
                }
                if ($dev) {
                    Write-Host "Device found: $value -> $($dev.Id)"
                    $deviceIds += $dev.Id
                } else {
                    Write-Warning "Device not found for value '$value'"
                }
            }
        }
    } catch {
        Write-Host "Error resolving device IDs: $($_.Exception.Message)"
    }
    return $deviceIds
}

function Invoke-AndroidAppChangeAssignments {
    param(
        [Parameter(Mandatory=$true)] [string[]]$DeviceIds,
        [Parameter(Mandatory=$true)] [string]$SelectedAppId
    )

    Write-Host "Starting Android app changeAssignments for $($DeviceIds.Count) device(s). AppId: $SelectedAppId"

    $results = @{
        DeviceID = @(); Status = @(); Message = @()
    }

    $counter = 0
    foreach ($did in $DeviceIds) {
        $counter++
        Write-Host "#$counter of $($DeviceIds.Count) - Sending changeAssignments to device: $did"
        try {
            $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$did')/changeAssignments"
            $body = @{ deviceAssignmentItems = @(@{ itemId = $SelectedAppId; itemType = "application" }) } | ConvertTo-Json -Depth 4
            $null = Invoke-MgGraphRequest -Method POST -Uri $uri -Body $body -ContentType "application/json" -ErrorAction Stop
            Write-Host "Device $did - changeAssignments request sent successfully"
            $results.DeviceID += $did
            $results.Status += "Requested"
            $results.Message += "OK"
        } catch {
            Write-Warning "Device $did - changeAssignments failed: $($_.Exception.Message)"
            $results.DeviceID += $did
            $results.Status += "Error"
            $results.Message += "$($_.Exception.Message)"
        }
    }

    Write-Host "Android app changeAssignments completed. Total: $($DeviceIds.Count)"
    return $results
}
#endregion ==================== ANDROID APP REINSTALL ====================

#region ==================== MODULE EXPORTS ====================
# Explicitly export public functions
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

    # User functions
    'Get-EntraUserDetails',
    
    # Policy functions
    'Get-PolicyNonComplianceSettings'
)
#endregion ==================== MODULE EXPORTS ====================
