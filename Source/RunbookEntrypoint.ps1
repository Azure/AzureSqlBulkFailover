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
    [Parameter(Mandatory=$false)]
    [string]$SubscriptionId,
    [Parameter(Mandatory=$false)]
    [string]$ResourceGroupName,
    [Parameter(Mandatory=$false)]
    [string]$LogicalServerName
)

$scriptStartTime = (Get-Date).ToUniversalTime().ToString("o")
Write-Output "Executing RunbookEntrypoint.ps1 with PS ver $($PSVersionTable.PSVersion) at $($scriptStartTime) on $($env:COMPUTERNAME) as $($env:USERNAME)"

function Get-File ([string]$remoteRootUri, [string]$remoteFile, [string]$localRootPath, [ref]$localFilePath = '') {
  $remoteFileUri = "$($remoteRootUri)/$($remoteFile)"
  $localFileName = [System.IO.Path]::GetFileName($remoteFile)
  $downloadedFilePath = "$($localRootPath)\$($localFileName)"
  Write-Output "Downloading $($remoteFileUri)..."
  Invoke-WebRequest -Uri $remoteFileUri -OutFile $downloadedFilePath 
  Unblock-File $downloadedFilePath
  $localFilePath.Value = $downloadedFilePath
}

function Get-AllFiles ([string]$remoteRootUri, [string]$localRootPath, [ref]$allFiles) {
  # A comment about the $localFilePaths output parameter: In PS a "Write-Output $x" is equivalent to "return $x". 
  # We cannot use the output stream for function return values because, in Azure Automation, the output stream is 
  # dedicated to logging. (Write-Host is not displayed.) So we use function output parameters instead of 'return'. 
  $manifestFilePath = [string]""
  Get-File -remoteRootUri $remoteRootUri -remoteFile 'Source/RunbookEntrypointManifest.json' -localRootPath $localRootPath -localFilePath ([ref]$manifestFilePath)
  $allFiles.Value = (Get-Content $manifestFilePath | ConvertFrom-Json)

  foreach ($file in $allFiles.Value) {
    $localFilePath = ''
    Download-File -remoteRootUri $remoteRootUri -remoteFile $file.File -localRootPath $localRootPath -localFilePath ([ref]$localFilePath)
    Add-Member -InputObject $file -NotePropertyName LocalFilePath -NotePropertyValue $localFilePath 
    Add-Member -InputObject $file -NotePropertyName SubscriptionId -NotePropertyValue $SubscriptionId
    Add-Member -InputObject $file -NotePropertyName ServerName -NotePropertyValue $ServerName
  }
}

$remoteRootUri = 'https://raw.githubusercontent.com/Azure/AzureSqlBulkFailover/main'
$localRootPath = [System.IO.Path]::Combine($env:TEMP, "AzureSqlBulkFailover_$([System.Guid]::NewGuid())")
New-Item -Path $localRootPath -ItemType "directory" | Out-Null

$allFiles = @()
Download-AllFiles -remoteRootUri $remoteRootUri -localRootPath $localRootPath -allFiles ([ref]$allFiles)

$scriptsToExecute = ($allFiles | Where-Object { $_.Execute -eq $true })
$scriptNum = 0
foreach ($scriptToExecute in $scriptsToExecute) {
  $scriptNum++
  Write-Output "----`r`n---- Executing $($scriptToExecute.File) ($($scriptNum) of $($scriptsToExecute.Length))...`r`n----"
  $scriptToExecute | Format-List -Property *
  & ($scriptToExecute.LocalFilePath) -ScriptProperties $scriptToExecute -SubscriptionId $SubscriptionId -ResourceGroupName $ResourceGroupName -LogicalServerName $LogicalServerName
}
