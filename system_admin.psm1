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
