$scriptStartTime = (Get-Date).ToUniversalTime().ToString("o")
Write-Output "Executing RunbookEntrypoint.ps1 with PS ver $($PSVersionTable.PSVersion) at $($scriptStartTime) on $($env:COMPUTERNAME) as $($env:USERNAME)"

function Download-File ([string]$remoteRootUri, [string]$remoteFile, [string]$localRootPath, [ref]$localFilePath = '') {
  $remoteFileUri = "$($remoteRootUri)/$($remoteFile)"
  $localFileName = [System.IO.Path]::GetFileName($remoteFile)
  $downloadedFilePath = "$($localRootPath)\$($localFileName)"
  Write-Output "Downloading $($remoteFileUri)..."
  Invoke-WebRequest -Uri $remoteFileUri -OutFile $downloadedFilePath 
  Unblock-File $downloadedFilePath
  $localFilePath.Value = $downloadedFilePath
}

function Download-AllFiles ([string]$remoteRootUri, [string]$localRootPath, [ref]$allFiles) {
  # A comment about the $localFilePaths output parameter: In PS a "Write-Output $x" is equivalent to "return $x". 
  # We cannot use the output stream for function return values because, in Azure Automation, the output stream is 
  # dedicated to logging. (Write-Host is not displayed.) So we use function output parameters instead of 'return'. 
  $manifestFilePath = [string]""
  Download-File -remoteRootUri $remoteRootUri -remoteFile 'Source/RunbookEntrypointManifest.json' -localRootPath $localRootPath -localFilePath ([ref]$manifestFilePath)
  $allFiles.Value = (Get-Content $manifestFilePath | ConvertFrom-Json)

  foreach ($file in $allFiles.Value) {
    $localFilePath = ''
    Download-File -remoteRootUri $remoteRootUri -remoteFile $file.File -localRootPath $localRootPath -localFilePath ([ref]$localFilePath)
    Add-Member -InputObject $file -NotePropertyName LocalFilePath -NotePropertyValue $localFilePath 
  }
}

$remoteRootUri = 'https://raw.githubusercontent.com/Azure/AzureSqlBulkFailover/main'
$localRootPath = [System.IO.Path]::Combine($env:TEMP, "AzureSqlBulkFailover_$([System.Guid]::NewGuid())")
New-Item -Path $localRootPath -ItemType "directory" | Out-Null

$allFiles = @()
Download-AllFiles -remoteRootUri $remoteRootUri -localRootPath $localRootPath -allFiles ([ref]$allFiles)

$scriptsToExecute = ($allFiles | ? { $_.Execute -eq $true })
$scriptNum = 0
foreach ($scriptToExecute in $scriptsToExecute) {
  $scriptNum++
  Write-Output "----`r`n---- Executing $($scriptToExecute.File) ($($scriptNum) of $($scriptsToExecute.Length))...`r`n----"
  & ($scriptToExecute.LocalFilePath) -ScriptProperties $scriptToExecute
}
