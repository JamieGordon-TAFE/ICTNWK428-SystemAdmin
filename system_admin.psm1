# Function to output script operations to a dedicated log file
function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [string]$LogFile = "C:\Logs\Application.log"
    )

    try {
        # Create the log file if it doesn't exist
        $LogDirectory = Split-Path $LogFile -Parent

        if (-not (Test-Path $LogDirectory)) {
            New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
        }

        # Timestamp
        $TimeStamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        # The caller function
        $CallerFunction = (Get-PSCallStack)[1].FunctionName

        # Build log entry
        $LogEntry = "$Timestamp - [$CallerFunction] $Message"

        # Write to log file
        Add-Content -Path $LogFile -Value $LogEntry -Encoding UTF8

        }
        catch {
            Write-Warning "Unable to write to the log file. $($_.Exception.Message)"
        }        
}

# Function to Install AD DS Role to the server
function Install-ADDSRole {
    [CmdletBinding()]
    param ()

    Write-Log -Message "Installing the Active Directory Domain Services role."

    try {
        Install-WindowsFeature -Name AD-Domain-Services -IncludeManagementTools

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
        Install-ADDSForest -DomainName $DomainName -SafeModeAdministratorPassword $SafeModePassword `
        -InstallDns -Force:$true -NoRebootOnComplete:$false

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

        # Verify if computer is in Active Directory
        $ADComputer = Get-ADComputer -Identity $ComputerName -ErrorAction Stop
        Write-Log -Message "Verified computer $ComputerName exists in Active Directory"

        #Test Network Connectivity
        if (-Not(Test-Connection -ComputerName $ComputerName -Count 2 -Quiet)) {
            throw "Computer is unreachable"
        }
        Write-Log -Message "$ComputerName responded to network connectivity test"

        # Create Powershell Session
        if($Credential) {
            $Session = New-PSSession -ComputerName $ComputerName -Credential $Credential -ErrorAction Stop
        } else {
            $Session = New-PSSession -ComputerName $ComputerName -ErrorAction Stop
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

    # Sanity check for already existing OU
    if(Get-ADOrganisationalUnit -LDAPFilter "(distinguishedName=$ouName)" -ErrorAction SilentlyContinue) {
        Write-Log -Message "The OU '$OuName' already exists under '$ParentDN'."
        return
    }

    try {
        New-ADOrganistationalUnit -Name $OuName -Path $ParentDN
        Write-Log -Message "The OU '$OuName' has been successfully created in '$ParentDN'"
    }
    catch {
        Write-Log -Message "There was an issue creating the OU: $($_.Exception.Message)"
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

    # Sanity check for CSV file
    if(-not(Test-Path $CsvPath) {
        Write-Log -Message "The '.csv' file at '$CsvPath' does not exist."
        return
    }

    # Import the user csv file
    $users = Import-Csv -Path $CsvPath

    foreach ($u in $users) {

        # Required fields check
        if (-not $u.SamAccountName -or -not $u.GivenName -or -not $u.Surname -or -not $u.Password) {
            Write-Log -Message "User has been skipped due to missing required data: $($u | Out-String)"
            continue
        }

        $userDN = "CN=$($u.GivenName) $($u.Surname),$TargetOU"

        # Check if the user already exists
        if (Get-ADUser -Filter "SamAccountName -eq '$($u.SamAccountName)'" -ErrorAction SilentlyContinue) {
            Write-Log -Message "The user '$($u.SamAccountName)' already exists."
            continue
        }

        try {
            # Create the user
            New-ADUser `
                -SamAccountName $u.SamAccountName `
                -UserPrincipalName "$($u.SamAccountName)@domain.local" `
                -Name "$($u.GivenName) $($u.Surname)" `
                -GivenName $u.GivenName `
                -Surname $u.Surname `
                -DisplayName "$($u.GivenName) $($u.Surname)" `
                -AccountPassword (ConvertTo-SecureString $u.Password -AsPlainText -Force) `
                -Enabled $true `
                -Path $TargetOU

            Write-Log -Message "Succesfully created the user: $($u.SamAccountName)"

        }
        catch {
            Write-Log -Message "Failed to create the user '$($u.SamAccountName)': $($_.Exception.Message)"
        }
    }
    
}
