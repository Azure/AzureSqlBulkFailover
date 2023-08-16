
Write-Output "Testing Az..."
Write-Output "Testing: Disable-AzContextAutosave -Scope Process"
Disable-AzContextAutosave -Scope Process
Write-Output "Testing: Connect-AzAccount -Identity"
$AzureContext = (Connect-AzAccount -Identity).context
$AzureContext
$subscriptionId = $AzureContext.Subscription
Write-Output "Testing: Set-AzContext -SubscriptionName"
Set-AzContext -SubscriptionName $subscriptionId -DefaultProfile $AzureContext
Write-Output "Testing: Get-AzResourceGroup"
Get-AzResourceGroup
Write-Object "ResourceGroup = $out"
Write-Output "Testing Complete."
