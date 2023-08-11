Param(
  [Parameter(Mandatory=$false)]
  [PSObject]$ScriptProperties
  )

Write-Output "Hello: $($ScriptProperties.Execute)" 
Start-Sleep -Seconds 1
foreach ($i in 1..10) {
    Write-Output "World $i"
    Start-Sleep -Seconds 1
}
Write-Output "Goodbye all."
