$scriptStartTime = (Get-Date).ToUniversalTime().ToString("o")
Write-Output "Executing RunbookEntrypoint.ps1 with PS ver $($PSVersionTable.PSVersion) at $($scriptStartTime) on $($env:COMPUTERNAME) as $($env:USERNAME)"

$remoteScriptPath = 'https://raw.githubusercontent.com/Azure/AzureSqlBulkFailover/main/Source/AzureSqlBulkFailover.ps1'
$tempPath = [System.IO.Path]::Combine($env:TEMP, "AzureSqlBulkFailover_$([System.Guid]::NewGuid())")
$localScriptPath = "$($tempPath)\AzureSqlRunbookEntrypoint.ps1"

New-Item -Path $tempPath -ItemType "directory" | Out-Null

Write-Output "Downloading $($remoteScriptPath)..."
Invoke-WebRequest -Uri $remoteScriptPath -OutFile $localScriptPath
Unblock-File $localScriptPath

Write-Output "Executing $($localScriptPath)..."
& $localScriptPath
