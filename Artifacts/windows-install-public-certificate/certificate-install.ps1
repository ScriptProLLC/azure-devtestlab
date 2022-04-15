<#
Installs a public certificate into a specified LocalMachine (Computer) certificate store.
#>
[CmdletBinding()]
Param(    
    [ValidateNotNullOrEmpty()]
    # This is a base64 encoded string of the contents of an exported certificate.
    # If the certificate was exported as base64, this value needs to be the base64 encoded value of the base64 certificate
    [string] $base64cert,
    [ValidateNotNullOrEmpty()]
    # must be valid values from https://docs.microsoft.com/en-us/dotnet/api/system.security.cryptography.x509certificates.storename?view=net-6.0
    [string] $storeName = "Root"
)

##################################################################################################
#
# Powershell Configurations
#

# Note: Because the $ErrorActionPreference is "Stop", this script will stop on first failure.  
#       This is necessary to ensure we capture errors inside the try-catch-finally block.
$ErrorActionPreference = "Stop"

# Ensure we set the working directory to that of the script.
Push-Location $PSScriptRoot

# Ensure that current process can run scripts. 
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope Process -Force 

##################################################################################################
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
# Main execution block.
#

try
{
    Write-Host "Installing certificate into store COMPUTER\$storeName"

        $tempFilePath = [System.IO.Path]::GetTempFileName()
        Write-Verbose "Temp file path '$tempFilePath'" 

        [System.IO.File]::WriteAllBytes($tempFilePath, [System.Convert]::FromBase64String($base64cert))
        Write-Verbose "Certificate saved"

        Import-Certificate -FilePath $tempFilePath -CertStoreLocation Cert:\LocalMachine\$storeName
        Write-Host "Certificate $certificateName added to the LocalMachine\$storeName store succesfully."

    Write-Host "`nThe artifact was applied successfully.`n"
}
finally
{
    Pop-Location
}
