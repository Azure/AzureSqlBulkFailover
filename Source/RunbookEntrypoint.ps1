<#
  .SYNOPSIS
  Provides fast failover for a large set of Azure SQL databases. 

  .DESCRIPTION
  Provides fast failover for a large set of Azure SQL databases.

  .PARAMETER SubscriptionId
  Specifies the subscription that contains the target databases. If omitted, the subscription that contains this runbook will be assumed. 

  .PARAMETER ServerName
  Specifies the name of the logical server that contains the target databases. If omitted, all logical servers in the target subscription will be targeted. 

  .INPUTS
  None. You can't pipe objects to this script.

  .OUTPUTS
  Output messages intended for user interface, for compatibility with Azure Automation. 
#>

#Read input parameters subscriptionId and ResourceGroupName and LogicalServerName
param(
    # SubscriptionId: This is the ID of the subscription where the resources to be failed over are located.
    # Use * to target the default subscription in the tenant.
    [Parameter(Mandatory=$true)]
    [string]$SubscriptionId,
    # ResourceGroupName: This is the name of the resource group where the resources to be failed over are located.
    # Use * to target all resource groups in the subscription.
    [Parameter(Mandatory=$true)]
    [string]$ResourceGroupName = "Use * for all resource groups",
    # LogicalServerName: This is the name of the logical server where the resources to be failed over are located.
    # Use * to target all logical servers in the subscription.
    [Parameter(Mandatory=$true)]
    [string]$LogicalServerName = "Use * for all logical servers or comma-delimited list of server names with no quotes",
    # branch_name: This is the name of the branch to use to get the scripts that are eecuted by the runbook.
    # Use main to target the main branch, leaving this empty will default to main.
    [Parameter(Mandatory=$false)]
    [string]$branch_name="main"
)

$scriptStartTime = (Get-Date).ToUniversalTime().ToString("o")
Write-Output "Executing RunbookEntrypoint.ps1 with PS ver $($PSVersionTable.PSVersion) at $($scriptStartTime) on $($env:COMPUTERNAME) as $($env:USERNAME) from branch_name: $branch_name"

# Retry configuration – defaults overridden by Automation variables  ------------
$DownloadRetryMaxAttempts         = 10
$DownloadRetryInitialDelaySeconds = 2
try { $DownloadRetryMaxAttempts         = [int](Get-AutomationVariable -Name 'DownloadRetryMaxAttempts') }         catch {}
try { $DownloadRetryInitialDelaySeconds = [int](Get-AutomationVariable -Name 'DownloadRetryInitialDelaySeconds') } catch {}

# Retry helper ------------------------------------------------------------------
function Invoke-WithRetry ([scriptblock]$scriptBlock, [int]$maxRetries, [int]$initialDelaySeconds, [double]$backoffFactor = 2) {
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            return & $scriptBlock
        } catch {
            if ($attempt -eq $maxRetries) { throw $_ }
            $delay = [math]::Pow($backoffFactor, $attempt - 1) * $initialDelaySeconds
            Write-Output "Attempt $attempt failed: $($_.Exception.Message). Retrying in $delay seconds..."
            Start-Sleep -Seconds $delay
        }
    }
}

# Gets one file from GitHub -----------------------------------------------------
function Get-File ([string]$remoteRootUri, [string]$remoteFile, [string]$localRootPath, [ref]$localFilePath = '') {
    $remoteFileUri      = "$remoteRootUri/$remoteFile"
    $localFileName      = [System.IO.Path]::GetFileName($remoteFile)
    $downloadedFilePath = "$localRootPath\$localFileName"

    Invoke-WithRetry -maxRetries:$DownloadRetryMaxAttempts -initialDelaySeconds:$DownloadRetryInitialDelaySeconds {
        Write-Output "Downloading $remoteFileUri..."
        Invoke-WebRequest -Uri $remoteFileUri -OutFile $downloadedFilePath -ErrorAction Stop
        Unblock-File $downloadedFilePath
    }

    $localFilePath.Value = $downloadedFilePath
}

function Get-AllFiles ([string]$remoteRootUri, [string]$localRootPath, [ref]$allFiles) {
  # A comment about the $localFilePaths output parameter: In PS a "Write-Output $x" is equivalent to "return $x". 
  # We cannot use the output stream for function return values because, in Azure Automation, the output stream is 
  # dedicated to logging. (Write-Host is not displayed.) So we use function output parameters instead of 'return'. 
  $manifestFilePath = [string]""
  Get-File -remoteRootUri $remoteRootUri -remoteFile 'Source/RunbookEntrypointManifest.json' -localRootPath $localRootPath -localFilePath ([ref]$manifestFilePath)
  $allFiles.Value = (Get-Content $manifestFilePath | ConvertFrom-Json)

  # create the script objects and set their execution parameters
  foreach ($file in $allFiles.Value) {
    $localFilePath = ''
    Get-File -remoteRootUri $remoteRootUri -remoteFile $file.File -localRootPath $localRootPath -localFilePath ([ref]$localFilePath)
    Add-Member -InputObject $file -NotePropertyName LocalFilePath -NotePropertyValue $localFilePath 
    Add-Member -InputObject $file -NotePropertyName SubscriptionId -NotePropertyValue $SubscriptionId
    Add-Member -InputObject $file -NotePropertyName ResourceGroupName -NotePropertyValue $ResourceGroupName
    Add-Member -InputObject $file -NotePropertyName LogicalServerName -NotePropertyValue $LogicalServerName
  }
}
# Make script stop on exception
$ErrorActionPreference = "Stop"

$remoteRootUri = "https://raw.githubusercontent.com/Azure/AzureSqlBulkFailover/$branch_name"
$localRootPath = [System.IO.Path]::Combine($env:TEMP, "AzureSqlBulkFailover_$([System.Guid]::NewGuid())")
New-Item -Path $localRootPath -ItemType "directory" | Out-Null

$allFiles = @()
Get-AllFiles -remoteRootUri $remoteRootUri -localRootPath $localRootPath -allFiles ([ref]$allFiles)

$scriptsToExecute = ($allFiles | Where-Object { $_.Execute -eq $true })
$scriptNum = 0
foreach ($scriptToExecute in $scriptsToExecute) {
  $scriptNum++
  Write-Output "----`r`n---- Executing $($scriptToExecute.File) ($($scriptNum) of $($scriptsToExecute.Length))...`r`n----"
  $scriptToExecute | Format-List -Property *
  & ($scriptToExecute.LocalFilePath) -ScriptProperties $scriptToExecute
}
