# Downloads the Azure Dev Ops Pipeline Agent, installs on the new machine, 
# registers with Azure Dev Ops, and adds to the specified build agent pool
[CmdletBinding()]
param(
    [string] $vstsUrl,
    [string] $vstsAccount,
    [string] $vstsUserPassword,
    [string] $agentName,
    [string] $agentNameSuffix,
    [string] $poolName,
    [string] $windowsLogonAccount,
    [string] $windowsLogonPassword,
    [ValidatePattern("[c-zC-Z]")]
    [ValidateLength(1, 1)]
    [string] $driveLetter,
    [string] $workDirectory,
    [boolean] $runAsAutoLogon,
    [boolean] $replaceAgent = $false
)

###################################################################################################
#
# PowerShell configurations
#

# NOTE: Because the $ErrorActionPreference is "Stop", this script will stop on first failure.
#       This is necessary to ensure we capture errors inside the try-catch-finally block.
$ErrorActionPreference = "Stop"

# Suppress progress bar output.
$ProgressPreference = 'SilentlyContinue'

# Ensure we force use of TLS 1.2 for all downloads.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Configure strict debugging.
Set-PSDebug -Strict

# if the agentName is empty, use %COMPUTERNAME% as the value
if ([String]::IsNullOrWhiteSpace($agentName))
{
    $agentName = $env:COMPUTERNAME
}

# if the agentNameSuffix has a value, add this to the end of the agent name
if (![String]::IsNullOrWhiteSpace($agentNameSuffix))
{
    $agentName = $agentName + $agentNameSuffix
}

###################################################################################################
#
# Handle all errors in this script.
#

trap
{
    # NOTE: This trap will handle all errors. There should be no need to use a catch below in this
    #       script, unless you want to ignore a specific error.
    $message = $Error[0].Exception.Message
    if ($message)
    {
        Write-Host -Object "`nERROR: $message" -ForegroundColor Red
    }

    Write-Host "`nThe artifact failed to apply.`n"

    # IMPORTANT NOTE: Throwing a terminating error (using $ErrorActionPreference = "Stop") still
    # returns exit code zero from the PowerShell script when using -File. The workaround is to
    # NOT use -File when calling this script and leverage the try-catch-finally block and return
    # a non-zero exit code from the catch block.
    exit -1
}

###################################################################################################
#
# Functions used in this script.
#

function Test-Parameters
{
    [CmdletBinding()]
    param(
        [string] $VstsAccount,
        [string] $WorkDirectory
    )

    if ($VstsAccount -match "https*://" -or $VstsAccount -match "visualstudio.com")
    {
        throw "VSTS account '$VstsAccount' should not be the URL, just the account name."
    }

    if (![string]::IsNullOrWhiteSpace($WorkDirectory) -and !(Test-ValidPath -Path $WorkDirectory))
    {
        throw "Work directory '$WorkDirectory' is not a valid path."
    }
}

function Set-ServerUrl
{
    [CmdletBinding()]
    param(
        [string] $VstsUrl,
        [string] $VstsAccount        
    )

    if ($VstsUrl)
    {
        $serverUrl = "$VstsUrl/$VstsAccount"
    }
    else 
    {
        $serverUrl = "https://$VstsAccount.visualstudio.com"
    }

    return $serverUrl
}

function Test-ValidPath
{
    param(
        [string] $Path
    )

    $isValid = Test-Path -Path $Path -IsValid -PathType Container

    try
    {
        [IO.Path]::GetFullPath($Path) | Out-Null
    }
    catch
    {
        $isValid = $false
    }

    return $isValid
}

function Test-AgentExists
{
    [CmdletBinding()]
    param(
        [string] $InstallPath,
        [string] $AgentName
    )

    $agentConfigFile = Join-Path $InstallPath '.agent'

    if (Test-Path $agentConfigFile)
    {
        throw "Agent $AgentName is already configured in this machine"
    }
}

function Get-AgentPackage
{
    [CmdletBinding()]
    param(
        [string] $VstsUrl,
        [string] $VstsUserPassword
    )

    # Create a temporary directory where to download from VSTS the agent package (agent.zip).
    $agentTempFolderName = Join-Path $env:temp ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Force -Path $agentTempFolderName | Out-Null

    $agentPackagePath = "$agentTempFolderName\agent.zip"
    $vstsAgentUrl = "$VstsUrl/_apis/distributedtask/packages/agent/win7-x64?`$top=1&api-version=3.0"
    $vstsUser = "AzureDevTestLabs"

    $maxRetries = 3
    $retries = 0
    do
    {
        try
        {
            $basicAuth = ("{0}:{1}" -f $vstsUser, $vstsUserPassword)
            $basicAuth = [System.Text.Encoding]::UTF8.GetBytes($basicAuth)
            $basicAuth = [System.Convert]::ToBase64String($basicAuth)
            $headers = @{ Authorization = ("Basic {0}" -f $basicAuth) }

            $agentList = Invoke-RestMethod -Uri $vstsAgentUrl -Headers $headers -Method Get -ContentType application/json
            $agent = $agentList.value
            if ($agent -is [Array])
            {
                $agent = $agentList.value[0]
            }
            Invoke-WebRequest -Uri $agent.downloadUrl -Headers $headers -Method Get -OutFile "$agentPackagePath" | Out-Null
            break
        }
        catch
        {
            $exceptionText = ($_ | Out-String).Trim()
                
            if (++$retries -gt $maxRetries)
            {
                throw "Failed to download agent due to $exceptionText"
            }
            
            Start-Sleep -Seconds 1 
        }
    }
    while ($retries -le $maxRetries)

    return $agentPackagePath
}

function New-AgentInstallPath
{
    [CmdletBinding()]
    param(
        [string] $DriveLetter,
        [string] $AgentName
    )
    
    [string] $agentInstallPath = $null
    
    # Construct the agent folder under the specified drive.
    $agentInstallDir = $DriveLetter + ":"
    try
    {
        # Create the directory for this agent.
        $agentInstallPath = Join-Path -Path $agentInstallDir -ChildPath $AgentName
        New-Item -ItemType Directory -Force -Path $agentInstallPath | Out-Null
    }
    catch
    {
        $agentInstallPath = $null
        throw "Failed to create the agent directory at $installPathDir."
    }
    
    return $agentInstallPath
}

function Get-AgentInstaller
{
    param(
        [string] $InstallPath
    )

    $agentExePath = [System.IO.Path]::Combine($InstallPath, 'config.cmd')

    if (![System.IO.File]::Exists($agentExePath))
    {
        throw "Agent installer file not found: $agentExePath"
    }
    
    return $agentExePath
}

function Extract-AgentPackage
{
    [CmdletBinding()]
    param(
        [string] $PackagePath,
        [string] $Destination
    )
  
    Add-Type -AssemblyName System.IO.Compression.FileSystem 
    [System.IO.Compression.ZipFile]::ExtractToDirectory("$PackagePath", "$Destination")
}

function Prep-MachineForAutologon
{
    param(
        $Config
    )

    if ([string]::IsNullOrWhiteSpace($Config.WindowsLogonPassword))
    {
        throw "Windows logon password was not provided. Please retry by providing a valid windows logon password to enable autologon."
    }

    # Create a PS session for the user to trigger the creation of the registry entries required for autologon
    $computerName = "localhost"
    $password = ConvertTo-SecureString $Config.WindowsLogonPassword -AsPlainText -Force

    if ($Config.WindowsLogonAccount.Split("\").Count -eq 2)
    {
        $domain = $Config.WindowsLogonAccount.Split("\")[0]
        $userName = $Config.WindowsLogonAccount.Split('\')[1]
    }
    else
    {
      $domain = $Env:ComputerName
      $userName = $Config.WindowsLogonAccount
    }

    $credentials = New-Object System.Management.Automation.PSCredential("$domain\\$userName", $password)
    Enter-PSSession -ComputerName $computerName -Credential $credentials
    Exit-PSSession

    try
    {
        # Check if the HKU drive already exists
        Get-PSDrive -PSProvider Registry -Name HKU | Out-Null
        $canCheckRegistry = $true
    }
    catch [System.Management.Automation.DriveNotFoundException]
    {
        try 
        {
            # Create the HKU drive
            New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
            $canCheckRegistry = $true
        }
        catch 
        {
            # Ignore the failure to create the drive and go ahead with trying to set the agent up
            Write-Warning "Moving ahead with agent setup as the script failed to create HKU drive necessary for checking if the registry entry for the user's SId exists.\n$_"
        }
    }

    # 120 seconds timeout
    $timeout = 120

    # Check if the registry key required for enabling autologon is present on the machine, if not wait for 120 seconds in case the user profile is still getting created
    while ($timeout -ge 0 -and $canCheckRegistry)
    {
        $objUser = New-Object System.Security.Principal.NTAccount($Config.WindowsLogonAccount)
        $securityId = $objUser.Translate([System.Security.Principal.SecurityIdentifier])
        $securityId = $securityId.Value

        if (Test-Path "HKU:\\$securityId")
        {
            if (!(Test-Path "HKU:\\$securityId\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run"))
            {
                New-Item -Path "HKU:\\$securityId\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" -Force
                Write-Host "Created the registry entry path required to enable autologon."
            }
        
            break
        }
        else
        {
            $timeout -= 10
            Start-Sleep(10)
        }
    }

    if ($timeout -lt 0)
    {
        Write-Warning "Failed to find the registry entry for the SId of the user, this is required to enable autologon. Trying to start the agent anyway."
    }
}

function Install-Agent
{
    param(
        $Config
    )

    try
    {
        # Set the current directory to the agent dedicated one previously created.
        Push-Location -Path $Config.AgentInstallPath

        if ($Config.RunAsAutoLogon)
        {
            Prep-MachineForAutologon -Config $Config

            # Arguements to run agent with autologon enabled
            $agentConfigArgs = "--unattended", "--url", $Config.ServerUrl, "--auth", "PAT", "--token", $Config.VstsUserPassword, "--pool", $Config.PoolName, "--agent", $Config.AgentName, "--runAsAutoLogon", "--overwriteAutoLogon", "--windowslogonaccount", $Config.WindowsLogonAccount
        }
        else
        {
            # Arguements to run agent as a service
            $agentConfigArgs = "--unattended", "--url", $Config.ServerUrl, "--auth", "PAT", "--token", $Config.VstsUserPassword, "--pool", $Config.PoolName, "--agent", $Config.AgentName, "--runasservice", "--windowslogonaccount", $Config.WindowsLogonAccount
        }

        if (-not [string]::IsNullOrWhiteSpace($Config.WindowsLogonPassword))
        {
            $agentConfigArgs += "--windowslogonpassword", $Config.WindowsLogonPassword
        }
        if (-not [string]::IsNullOrWhiteSpace($Config.WorkDirectory))
        {
            $agentConfigArgs += "--work", $Config.WorkDirectory
        }
        if ($Config.ReplaceAgent)
        {
            $agentConfigArgs += "--replace"
        }
        & $Config.AgentExePath $agentConfigArgs
        if ($LASTEXITCODE -ne 0)
        {
            throw "Agent configuration failed with exit code: $LASTEXITCODE"
        }
    }
    finally
    {
        Pop-Location
    }
}

###################################################################################################
#
# Main execution block.
#

try
{
    # Ensure we set the working directory to that of the script.
    Push-Location $PSScriptRoot

    Write-Host 'Validating parameters'
    Test-Parameters -VstsAccount $vstsAccount -WorkDirectory $workDirectory

    Write-Host 'Setting ServerUrl'
    $vstsUrlFull = Set-ServerUrl -VstsUrl $vstsUrl -VstsAccount $vstsAccount

    Write-Host 'Preparing agent installation location'
    $agentInstallPath = New-AgentInstallPath -DriveLetter $driveLetter -AgentName $agentName

    if (-not $replaceAgent)
    {
        Write-Host 'Checking for previously configured agent'
        Test-AgentExists -InstallPath $agentInstallPath -AgentName $agentName
    }

    Write-Host "Downloading agent package from $vstsUrlFull"
    $agentPackagePath = Get-AgentPackage -VstsUrl $vstsUrlFull -VstsUserPassword $vstsUserPassword

    Write-Host 'Extracting agent package contents'
    Extract-AgentPackage -PackagePath $agentPackagePath -Destination $agentInstallPath

    Write-Host 'Getting agent installer path'
    $agentExePath = Get-AgentInstaller -InstallPath $agentInstallPath

    # Call the agent with the configure command and all the options (this creates the settings file)
    # without prompting the user or blocking the cmd execution.
    Write-Host 'Installing agent'
    $config = @{
        AgentExePath = $agentExePath
        AgentInstallPath = $agentInstallPath
        AgentName = $agentName
        PoolName = $poolName
        ReplaceAgent = $replaceAgent
        RunAsAutoLogon = $runAsAutoLogon
        ServerUrl = $vstsUrlFull
        VstsUserPassword = $vstsUserPassword
        WindowsLogonAccount = $windowsLogonAccount
        WindowsLogonPassword = $windowsLogonPassword
        WorkDirectory = $workDirectory
    }
    Install-Agent -Config $config

    Write-Host "`nThe artifact was applied successfully.`n"
}
finally
{
    Pop-Location
}
