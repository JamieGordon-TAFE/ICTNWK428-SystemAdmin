$Script:LogServerIP = "10.1.1.10"

# Function to output script operations to a dedicated log file
function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [string]$LogFile = "C:\myLogs\system_admin.log"
    )

    # Timestamp
    $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

    # Caller function name
    $CallerFunction = (Get-PSCallStack)[1].FunctionName

    # Build log entry
    $LogEntry = "$TimeStamp - [$CallerFunction] $Message"

    try {
        Invoke-Command -ComputerName $using:LogServerIP -ScriptBlock {
            param($LogFile, $LogEntry)

            # Ensure directory exists
            $LogDirectory = Split-Path $LogFile -Parent
            if (-not (Test-Path $LogDirectory)) {
                New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
            }

            Add-Content -Path $LogFile -Value $LogEntry -Encoding UTF8

        } -ArgumentList $LogFile, $LogEntry
    }
    catch {
        Write-Warning "Unable to write to server log. $($_.Exception.Message)"
    }        
}

# Function to Install AD DS Role to the server
function Install-ADDSRole {
    [CmdletBinding()]
    param ()

    Write-Log -Message "Installing the Active Directory Domain Services role."

    try {
        Invoke-Command -ComputerName $using:LogServerIP -ScriptBlock {
            Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools
        }
        

        Write-Log -Message "Successfully installed ADDS Role"
    }
    catch {
        Write-Log -Message "Failed to install the AD DS Role. $($_.Exception.Message)" throw
    }
}

# Promote Server to Domain Controller
function New-DomainController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$DomainName,

        [Parameter(Mandatory = $true)]
        [string]$SafeModePassword
    )

    Write-Log -Message "Starting promotion of domain controller for $DomainName"

    try {
        Invoke-Command -ComputerName $using:LogServerIP -ScriptBlock {
            Install-ADDSForest -DomainName $using:DomainName -SafeModeAdministratorPassword $using:SafeModePassword `
            -InstallDns -Force:$true -NoRebootOnComplete:$false
        }
        

        Write-Log -Message "The domain controller has successfully been promoted for $DomainName"
    }
    catch {
        Write-Log -Message "Domain Controller promotion has failed. $($_.Exception.Message)" throw
    }
}

# Connect to Windows Server 2022 or other computers within domain
function Connect-RemoteComputer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [PSCredential]$Credential
    )

    try {
        Write-Log -Message "Attempting to connect to $ComputerName"

        Invoke-Command -ComputerName $using:LogServerIP -ScriptBlock {
            # Verify if computer is in Active Directory
            $ADComputer = Get-ADComputer -Identity $using:ComputerName -ErrorAction Stop
            Write-Log -Message "Verified computer $using:ComputerName exists in Active Directory"

            #Test Network Connectivity
            if (-Not(Test-Connection -ComputerName $using:ComputerName -Count 2 -Quiet)) {
                throw "Computer is unreachable"
            }
            Write-Log -Message "$using:ComputerName responded to network connectivity test"

            # Create Powershell Session
            if($using:Credential) {
                $Session = New-PSSession -ComputerName $using:ComputerName -Credential $using:Credential -ErrorAction Stop
            } else {
                $Session = New-PSSession -ComputerName $using:ComputerName -ErrorAction Stop
            }
        }
        
        Write-Log -Message "PowerShell session successfully established with $ComputerName"
        
    } catch {
        Write-Log -Message "Failed to connect to $ComputerName. $($_.Exception.Message)" throw
    }
}

# Function to add new Organisation Units to active directory
function Add-ADOrganistationalUnit {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$OuName,

        [Parameter(Mandatory = $true)]
        [string]$ParentDN
    )

    # Create the full DN
    $OuDN = "OU=$OuName, $ParentDN"
    Write-Log -Message "Checking the if the OU '$OuName' already exists..."

    Invoke-Command -ComputerName $using:LogServerIP -ScriptBlock {
        # Sanity check for already existing OU
        if(Get-ADOrganisationalUnit -LDAPFilter "(distinguishedName=$using:ouName)" -ErrorAction SilentlyContinue) {
            Write-Log -Message "The OU '$using:OuName' already exists under '$using:ParentDN'."
            return
        }

        try {
            New-ADOrganistationalUnit -Name $using:OuName -Path $using:ParentDN
            Write-Log -Message "The OU '$using:OuName' has been successfully created in '$using:ParentDN'"
        }
        catch {
            Write-Log -Message "There was an issue creating the OU: $($_.Exception.Message)"
        }    
    }

}

# Function to add new users from CSV file
function New-ADUserFromFile {
    [CmdletBinding()]
    
    param (
        [Parameter(Mandatory = $true)]
        [string]$CsvPath,

        [Parameter(Mandatory = $true)]
        [string]$TargetOu
    )

    Invoke-Command -ComputerName $using:LogServerIP -ScriptBlock {
         # Sanity check for CSV file
        if(-not(Test-Path $using:CsvPath)) {
            Write-Log -Message "The '.csv' file at '$using:CsvPath' does not exist."
            return
        }

        # Import the user csv file
        $users = Import-Csv -Path $using:CsvPath

        foreach ($u in $users) {

            # Required fields check
            if (-not $u.SamAccountName -or -not $u.GivenName -or -not $u.Surname -or -not $u.Password) {
                Write-Log -Message "User has been skipped due to missing required data: $($u | Out-String)"
                continue
            }

            $userDN = "CN=$($u.GivenName) $($u.Surname),$using:TargetOu"

            # Check if the user already exists
            if (Get-ADUser -Filter "SamAccountName -eq '$($u.SamAccountName)'" -ErrorAction SilentlyContinue) {
                Write-Log -Message "The user '$($u.SamAccountName)' already exists."
                continue
            }

            try {
                # Create the user
                New-ADUser `
                    -SamAccountName $u.SamAccountName `
                    -UserPrincipalName "$($u.SamAccountName)@JGmicksandmacks.local" `
                    -Name "$($u.GivenName) $($u.Surname)" `
                    -GivenName $u.GivenName `
                    -Surname $u.Surname `
                    -DisplayName "$($u.GivenName) $($u.Surname)" `
                    -AccountPassword (ConvertTo-SecureString $u.Password -AsPlainText -Force) `
                    -Enabled $true `
                    -Path $using:TargetOU

                Write-Log -Message "Succesfully created the user: $($u.SamAccountName)"

            }
            catch {
                Write-Log -Message "Failed to create the user '$($u.SamAccountName)': $($_.Exception.Message)"
            }
        }
    }
    
}

# Function to join computers to the domain
function Add-ComputerToDomain {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [string]$ComputerName,

        [Parameter(Mandatory = $true)]
        [string]$DomainName
    )

    Invoke-Command -ComputerName $using:LogServerIP -ScriptBlock {
        # Prompt the user for admin creds
        $creds = Get-Credential -Message "Enter the credentials for domain administator"
        Write-Log -Message "Prompted the user for domain credentials"

        # Testing connectivity to target
        Write-Log -Message "Testing the connectivity to '$using:ComputerName'..."
        if(-not (Test-Connection -ComputerName $using:ComputerName -Count 2 -Quiet)) {
            Write-Log -Message "The computer '$using:ComputerName' was not reachable."
            return
        }

        try {
            # Add the target computer to the domain
            Invoke-Command -ComputerName $using:ComputerName -ScriptBlock {
                param($DomainName, $creds)
                Add-Computer -DomainName $DomainName -Credential $creds -ErrorAction Stop
            } -ArgumentList $using:DomainName, $creds

            Write-Log -Message "The computer '$using:ComputerName' has successfully joined the domain '$using:DomainName'."

            # Restart the target computer
            Invoke-Command -ComputerName $using:ComputerName -ScriptBlock { Restart-Computer -Force }
        }
        catch {
            Write-Log -Message "Failed to join computer to domain: $($_.Exception.Message)"
        }
    }
    
}

# Function to configure the DHCP services
function Configure-DHCPServices {
    [CmdletBinding()]

    param (
        [Parameter(Mandatory = $true)]
        [string]$DhcpServer,

        [Parameter(Mandatory = $true)]
        [string]$ClientComputer
    )

    Invoke-Command -ComputerName $using:LogServerIP -ScriptBlock {
        # Sanity check for DHCP role on server, install if not found
        if (-not (Get-WindowsFeature -Name DHCP).Installed) {
            Write-Log -Message "The DHCP role was not installed. Installing it now..."
            Install-WindowsFeature -Name DHCP -IncludeManagementTools
        }

        # Configure the DHCP Service
        Write-Log -Message "Authorizing DHCP server in Active Directory..."
        Add-DhcpServerInDC -DnsName $using:DhcpServer -IpAddress (Resolve-DnsName $using:DhcpServer).IPAddress

        # Check existing scopes
        Write-Log -Message "Checking existing DHCP scopes..."
        $existingScopes = Get-DhcpServerv4Scope -ComputerName $using:DhcpServer -ErrorAction SilentlyContinue

        if ($existingScopes) {
            Write-Log -Message "Existing scopes found:"
            $existingScopes | Format-Table ScopeId, Name, State
        }
        else {
            Write-Log -Message "No existing scopes found."
        }

        # Define desired scope
        $scopeId = "10.1.1.0"
        $startRange = "10.1.1.50"
        $endRange   = "10.1.1.200"
        $subnetMask = "255.255.255.0"

        # Create scope only if missing
        if ($existingScopes.ScopeId -contains $scopeId) {
            Write-Log -Message "Scope $scopeId already exists."
        }
        else {
            Write-Log -Message "Creating new DHCP scope $scopeId..."
            Add-DhcpServerv4Scope `
                -ComputerName $using:DhcpServer `
                -Name "Main LAN Scope" `
                -ScopeId $scopeId `
                -StartRange $startRange `
                -EndRange $endRange `
                -SubnetMask $subnetMask `
                -State Active
        }

        # Add common options
        Write-Log -Message  "Configuring DHCP options..."
        Set-DhcpServerv4OptionValue -ComputerName $using:DhcpServer -ScopeId $scopeId -Router "10.1.1.1"
        Set-DhcpServerv4OptionValue -ComputerName $using:DhcpServer -ScopeId $scopeId -DnsServer "10.1.1.10"
        Set-DhcpServerv4OptionValue -ComputerName $using:DhcpServer -ScopeId $scopeId -DnsDomain "JGmicksandmacks.local"

        Write-Log -Message "DHCP configuration complete."

        # Test DHCP using client
        Write-Log -Message "Testing DHCP from client $using:ClientComputer..."

        if (-not (Test-Connection -ComputerName $using:ClientComputer -Count 2 -Quiet)) {
            Write-Log -Message "Client '$using:ClientComputer' is not reachable. Cannot test DHCP."
            return
        } 
        
        try {
            Invoke-Command -ComputerName $using:ClientComputer -ScriptBlock {
            Write-Log -Message "Releasing IP..."
            ipconfig /release

            Start-Sleep -Seconds 3

            Write-Log -Message "Renewing IP..."
            ipconfig /renew
        }

            Write-Log -Message "DHCP test complete."
        }
        catch {
            Write-Log -Message "Failed DHCP test: $($_.Exception.Message)"
        }   
    }
}

# Function to check the top ten system errors
function Get-TopTenSystemErrors {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$TargetIP
    )

    Invoke-Command -ComputerName $using:LogServerIP -ScriptBlock {
        # Ensure target is reachable
        Write-Log -Message "Checking connectivity to $using:TargetIP..."
        if (-not (Test-Connection -ComputerName $using:TargetIP -Count 2 -Quiet)) {
            Write-Log -Message "Target computer '$using:TargetIP' is not reachable."
            return
        }

        # Ensure log directory exists
        $logPath = "C:\myLogs"
        if (-not (Test-Path $logPath)) {
            New-Item -Path $logPath -ItemType Directory | Out-Null
        }

        $outputFile = "$logPath\toptenerrors.txt"

        Write-Log -Message "Collecting System log errors from $using:TargetIP..."

        try {
            $errors = Invoke-Command -ComputerName $using:TargetIP -ScriptBlock {
                # Get only Error-level events from System log
                Get-WinEvent -LogName System | Where-Object { $_.LevelDisplayName -eq "Error" }
            }

            if (-not $errors) {
                Write-Log -Message "No error events found on $using:TargetIP."
                return
            }

            # Group by Event ID, count occurrences, sort by frequency
            $topTen = $errors |
            Group-Object Id |
            Sort-Object Count -Descending |
            Select-Object -First 10

            # Save to file
            $topTen | Out-File -FilePath $outputFile

            Write-Log -Message "Top ten errors saved to $outputFile"
        }
        catch {
            Write-Log -Message "Failed to retrieve or process event logs: $($_.Exception.Message)"
        }    
    }

}

# Function to set dailt disk cleanups
function Set-DailyDiskCleanup {
    [CmdletBinding()]
    param(
        [string]$TargetIP = "localhost"
    )

    # Check connectivity unless localhost
    if ($TargetIP -ne "localhost") {
        Write-Log -Message "Checking connectivity to $TargetIP..."
        if (-not (Test-Connection -ComputerName $TargetIP -Count 2 -Quiet)) {
            Write-Log -Message "Target computer '$TargetIP' is not reachable."
            return
        }
    }

    Write-Log -Message "Configuring scheduled task on $TargetIP..."

    try {
        Invoke-Command -ComputerName $using:TargetIP -ScriptBlock {

            # Define task components
            $action = New-ScheduledTaskAction -Execute "cleanmgr.exe"
            $trigger = New-ScheduledTaskTrigger -Daily -At 6:00AM
            $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

            # Register the task
            Register-ScheduledTask `
                -TaskName "DailyDiskCleanup" `
                -Action $action `
                -Trigger $trigger `
                -Settings $settings `
                -Description "Runs Disk Cleanup every day at 6 AM"

        }

        Write-Log -Message "Scheduled task 'DailyDiskCleanup' created successfully on $TargetIP."
    }
    catch {
        Write-Log -Message "Failed to create scheduled task: $($_.Exception.Message)"
    }
}

# Create network share drive
function Map-NetworkDrive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ServerName,

        [string]$ShareName = "mickandmacks_share",

        [string]$DriveLetter = "S"
    )

    $drive = "${DriveLetter}:"
    $path  = "\\$ServerName\$ShareName"

    Write-Log -Message "Mapping drive $drive to $path..."

    Invoke-Command -ComputerName $using:LogServerIP -ScriptBlock {
        # Remove existing mapping if present
        if (Get-PSDrive -Name $using:DriveLetter -ErrorAction SilentlyContinue) {
            Write-Log -Message "Existing mapping found. Removing..."
            Remove-PSDrive -Name $using:DriveLetter -Force
        }

        # Create new mapping
        try {
            New-PSDrive -Name $using:DriveLetter -PSProvider FileSystem -Root $using:path -Persist
            Write-Log -Message "Drive $using:drive successfully mapped to $using:path."
        }
        catch {
            Write-Log -Message "Failed to map drive: $($_.Exception.Message)"
        }    
    }

    
}
