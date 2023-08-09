#
Write-Host "Hello: " 
Start-Sleep -Seconds 1
foreach ($i in 1..10) {
    Write-Host "World $i"
    Start-Sleep -Seconds 1
}
Write-Host "Goodbye all."