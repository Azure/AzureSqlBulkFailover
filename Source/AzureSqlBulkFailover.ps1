#
Write-Output "Hello: " 
Start-Sleep -Seconds 1
foreach ($i in 1..10) {
    Write-Output "World $i"
    Start-Sleep -Seconds 1
}
Write-Output "Goodbye all."