# Last Updated: 2024-11-27
# Purpose: This script is used to failover all databases and elastic pools in a subscription to a secondary, already upgraded replica
# Usage: This script is intended to be run as an Azure Automation Runbook or locally.
# Notes: This script is intended to be used to facilitate CMW customers to upgrade their databases on demand when upgrades are ready (one touch 
# Warning: This will failover ALL resources that the caller has access to in all subscriptions in the tenant, filtering by SubscriptionId, ResourceGroupName and LogicalServerName.
# Copyright 2023 Microsoft Corporation. All rights reserved. MIT License
# Read input parameters subscriptionId and ResourceGroup
param(
    [Parameter(Mandatory=$true)]
    [psobject]$ScriptProperties
)

# Base URI for ARM API calls, used to parse out the FailoverStatus path for the failover request
$global:ARMBaseUri = "https://management.azure.com";

# Sleep time in seconds between checking the FailoverStatus of the failover request
$global:SleepTime = 15;

# LogLevel is used to control the amount of logging in the script, all only shows critical messages, info shows normal process messages, verbose shows all messages
$global:LogLevel = 'Info';
try {
    $global:LogLevel = Get-AutomationVariable -Name 'LogLevel'    
}
catch {
    # do nothing
}

# Create a list to store the log messages with their level to be displayed at end of script execution
$global:LogList = [System.Collections.Generic.List[Tuple[string,int]]]::new()

# CheckPlannedMaintenanceNotification is used to control whether the script checks for a planned maintenance notification before proceeding
$global:CheckPlannedMaintenanceNotification = $false;
try {
    $global:CheckPlannedMaintenanceNotification = [bool](Get-AutomationVariable -Name 'CheckPlannedMaintenanceNotification')
}
catch {
    # do nothing
}

#region Enumerations, globals and helper functions
# enum containing resource object FailoverStatus values
enum FailoverStatus {
    Pending # The resource is pending to be failedover.
    InProgress # The failover process is in progress.
    Succeeded # The failover process succeeded.
    Skipped # The failover process was skipped (the database did not need to be failed over or was not eligible).
    Failed # The failover process failed.
}

# Get the numeric value of the LogLevel to facilitate comparison
function LogLevelValue($logLevel) {
    switch ($logLevel) {
        "Always" { return 0; } # When passed to Log ensures the message is logged
        "Minimal" { return 1; } # When defined as log level ensures only Always messages are logged
        "Info" { return 2; } # When defined as log level ensures only info and Always messages are logged
        "Verbose" { return 3; } # When defined as log level ensures all messages are logged
        default { return 2; } # When LogLevel is not defined, default to Info
    }
}

function GetPlannedNotificationId {
    # query resource health for planned maintenance notifications
    $notifications = Search-AzGraph -Query @"
ServiceHealthResources
| where type =~ 'Microsoft.ResourceHealth/events'
| extend notificationTime = todatetime(tolong(properties.LastUpdateTime)),
          eventType = properties.EventType,
          status = properties.Status,
          summary = properties.Summary,
          trackingId = tostring(properties.TrackingId)
| where eventType == 'PlannedMaintenance' 
      and status == 'Active' 
      and summary contains 'azsqlcmwselfservicemaint'
| summarize arg_max(notificationTime, *) by trackingId
| project trackingId
"@;

    if ($notifications.Count -gt 0) {
        return $notifications[0].trackingId;
    }
    else {
        return $null;
    }
}

# helper function to Log -message messages to the log message list
# LogLevel values can be 'Minimal', 'Info', 'Verbose'
function Log([string]$message, [string]$logLevel) {
    $logLevelValue =[int](LogLevelValue($logLevel));
    $outputMessage = "$($logLevel): $([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")) => $message";
    $global:LogList.Add([Tuple]::Create($outputMessage,$logLevelValue));
}

# Helper function to display the log messages at the end of the script execution
function DisplayLogMessages([string]$logLevel) {
    [int]$logLevelValue = [int](LogLevelValue($logLevel));
    foreach ($tuple in $global:LogList) {
        $message = $tuple.Item1
        $level = $tuple.Item2
        if ($level -le $logLevelValue) {
            Write-Output $message
        }
    }
}
#endregion

#region basic classes

# Class that represents the information for a server and associated helper methods
class Server{
    [string]$SubscriptionId # Subscription ID for the server
    [string]$ResourceGroupName # Resource group name for the server
    [string]$Name # Name of the server

    # Constructor takes a server response object as returned from the API call methods 
    # and creates a server object with the required properties to facilitate processing and querying of state
    Server([PSObject]$server) {
        $this.SubscriptionId = $this.GetSubscriptionId($server);
        $this.ResourceGroupName = $this.GetResourceGroupName($server);
        $this.Name = $this.GetName($server);
    }

    # Helper to get the subscription ID from the server respose object
    [string]GetSubscriptionId([PSObject]$server) {
        return $server.id.Split("/")[2];
    }

    # Helper to get the resource group name from the server response object
    [string]GetResourceGroupName([PSObject]$server) {
        return $server.id.Split("/")[4];
    }

    # Helper to get the name of the server from the server response object
    [string]GetName([PSObject]$server) {
        return $server.name;
    }
}

# Class that represents the base class for resource objects (databases and elastic pools)
class DatabaseResource {
    [Server]$Server # The server object that contains the resource
    [FailoverStatus]$FailoverStatus # Used to store the FailoverStatus of the resource
    [string]$FailoverStatusPath # Used to store the API path to get the FailoverStatus of the resource
    [string]$Message # Used to store the last message for an API call to the resource FailoverStatus or failover
    [string]$Name # Name of the resource
    [string]$ResourceId # The id (path) of the resource
    [bool]$ShouldFailover # Used to store if the resource will upgrade when failover is invoked (if this is false, resource will be skipped)
    [bool]$IsPool # Used to store if the resource is an elastic pool

    # Constructor takes a Server object, and a resource object (database or elastic pool) as returned from the API call methods 
    # and creates a resource object with the required properties to facilitate processing and querying of state
    DatabaseResource([Server]$server, [PSObject]$resource, [bool]$isPool) {
        $this.Server = $server;
        $this.FailoverStatus = [FailoverStatus]::Pending;
        $this.FailoverStatusPath = "";
        $this.Message = "";
        $this.Name = $this.GetName($resource); 
        $this.ResourceId = $this.GetResourceId($resource);
        $this.IsPool = $isPool;
        $this.ShouldFailover = $this.IsPool -or $this.GetIsFailoverUpgrade($resource);
    }

    # Determines if the database resource is in an elastic pool
    static [bool]IsInElasticPool([PSObject]$resource) {
        # use reflexion to check if the property exists
        $hasElasticPoolId = [bool]($resource.properties | Get-Member -Name "elasticPoolId" -MemberType "NoteProperty")
        return $hasElasticPoolId -and ($null -ne $resource.properties.elasticPoolId);
    }

    # return the URL to failover the resource (without the ARM base)
    [string]FailoverUri() {
        return "$($this.ResourceId)/failover?api-version=2021-02-01-preview";
    }

    # gets the resource ID (path) from the resource object
    [string]GetResourceId([PSObject]$resource)
    {
        return $resource.id;
    }

    # gets the name of the resource from the resource object
    [string]GetName([PSObject]$resource)
    {
        return $resource.name;
    }

    # Helper to get the subscription ID from the server object
    [string]SubscriptionId() {
        return $this.Server.SubscriptionId;
    }

    # Helper to get the resource group name from the server object
    [string]ResourceGroupName() {
        return $this.Server.ResourceGroupName;
    }

    # Helper to get the server name from the server object
    [string]ServerName() {
        return $this.Server.Name;
    }

    # Helper to get the IsActive property from the resource object 
    [bool]GetIsActive([PSObject]$resource) {
        return ($resource.Properties.FailoverStatus) -eq "Online";
    }

    # Helper to determine if the failover will actually invoke the UpgradeMeNow process.
    # This is determined by whether the CurrentSku tier of the databse is not HyperScale
    [bool]GetIsFailoverUpgrade([PSObject]$resource) {
        return $this.IsPool -or ($resource.Properties.CurrentSku.tier) -ne "Hyperscale";
    }

    # Helper to determine if the resource should be failed over
    [bool]ShouldFailover([PSObject]$resource) {
        # note that if the DB is inactive and then become active during the script run
        # it will not be failed over which is fine because it will get activated on the correct upgrade domain so doesnt need to be failed over
        return $this.IsPool -or ($this.GetIsFailoverUpgrade($resource) -and $this.GetIsActive($resource));
    }

    # Helper to determine if the resource failover process is complete
    [bool]IsComplete() {
        return ($this.FailoverStatus -eq ([FailoverStatus]::Succeeded)) -or ($this.FailoverStatus -eq ([FailoverStatus]::Failed)) -or ($this.FailoverStatus -eq ([FailoverStatus]::Skipped));
    }

    # Fails over the resource, updating the required request information and FailoverStatus in it
    [void]Failover()
    {
        #only failover resources that should be failed over, set the FailoverStatus of the rest to skipped
        if ($this.ShouldFailover) {
            $url = $this.FailoverUri();
            Log -message "Failover: Invoke-AzRestMethod -Method GET -Path $url" -logLevel "Verbose"
            $response = Invoke-AzRestMethod -Method POST -Path $url;
            Log -message "response StatusCode: $($response.StatusCode)" -logLevel "Verbose"
            if (($response.StatusCode -eq 202) -or ($response.StatusCode -eq 200)) {# check if the failover request was accepted or completed Succeededfully
                # get the header that gives us the URL to query the FailoverStatus of the request and remove the ARM prefix, add it to the resource as the FailoverStatus path
                # get the AsynOperationHeader value from the response and parse out the path to the FailoverStatus of the request
                $this.FailoverStatus = [FailoverStatus]::InProgress;
                $this.Message = "";
                $CheckStatusPath = $response.Headers | Where-Object -Property Key -EQ "Azure-AsyncOperation";
                $this.FailoverStatusPath  = ($CheckStatusPath.value[0]) -replace [regex]::Escape($($global:ARMBaseUri)), "";
                Log -message "$($this.ResourceId). Monitoring failover status...." -logLevel "Info";
            } else {# If we got another kind of response, we failed to failover the resource
                $this.FailoverStatus = [FailoverStatus]::Failed;
                $this.Message = $response.Content;
                Log -message "$($this.ResourceId). Error: $($response.StatusCode) - $($this.Message)." -logLevel "Always";
            }
        }
        else {
            $this.FailoverStatus = [FailoverStatus]::Skipped;
            $this.Message = "Resource is not eligible (is hyperscale) or does not need failover (is offline).";
            Log -message "$($this.ResourceId). $($this.Message). Will be skipped." -logLevel "Info";
        }
    }

    # update the resource FailoverStatus based on the FailoverStatus of the failover request
    # only update FailoverStatus on pending resources
    [void]UpdateFailoverStatus(){
        if ($this.FailoverStatus -eq [FailoverStatus]::InProgress) {
            $url = $this.FailoverStatusPath;
            Log -message "UpdateFailoverStatus: Invoke-AzRestMethod -Method GET -Path $url" -logLevel "Verbose"
            $response = Invoke-AzRestMethod -Method GET -Path ($this.FailoverStatusPath)
            Log -message "response StatusCode: $($response.StatusCode)" -logLevel "Verbose"
            if ($response.StatusCode -eq 200) {
                # check the content of the request to figure out if the failover completed Succeededfully
                # if their was no error but the failover has not yest completed then do nothing
                $requestContent = $response.Content | ConvertFrom-Json;
                if ($requestContent.Status -eq "Failed") {
                    if($requestContent.Error.Code -eq "DatabaseNotInStateToFailover"){
                        Log -message "$($this.ResourceId) => Is serverless and offline so doesnt need failover." -logLevel "Info";
                        $this.FailoverStatus = [FailoverStatus]::Skipped;
                        $this.Message = $requestContent.error.message;
                    }
                    else{
                        Log -message "$($this.ResourceId) => Error: $($requestContent.error.message) while trying to failover. Will not retry." -logLevel "Always";
                        $this.FailoverStatus = [FailoverStatus]::Failed;
                        $this.Message = $requestContent.error.message;
                    }
                }
                elseif ($requestContent.Status -eq "Succeeded") {
                    Log -message "$($this.ResourceId) => Successfully failed over." -logLevel "Always";
                    $this.FailoverStatus = [FailoverStatus]::Succeeded;
                }
            }
            else{
                # if the request did not complete then report the error and remove the request from the list
                Log -message "$($this.ResourceId) => Error: $($response.StatusCode) while trying to get FailoverStatus." -logLevel "Always";
                $this.FailoverStatus = [FailoverStatus]::Failed;
                $this.Message = $response.Content;
            }
        }
    }   
}
#endregion

#region List classes
# Class that represents a list of resources and associated helper methods
# Note that the base class for all resources is DatabaseResource
class ResourceList : System.Collections.Generic.List[object]{
    # Helper to get the url (path) to the list of database resources in the server
    static [string]DatabaseResourceListUrl([Server]$server){
        return "/subscriptions/$($server.SubscriptionId)/resourcegroups/$($server.ResourceGroupName)/providers/Microsoft.Sql/servers/$($server.Name)/databases?api-version=2021-02-01-preview";
    }

    # Helper to get the url (path) to the list of pool resources in the server
    static [string]ElasticPoolResourceListUrl([Server]$server){
        return "/subscriptions/$($server.SubscriptionId)/resourcegroups/$($server.ResourceGroupName)/providers/Microsoft.Sql/servers/$($server.Name)/elasticpools?api-version=2021-02-01-preview";
    }

    # Adds all the database or pool resource to this list
    [int]AddDatabaseOrPoolResources([Server]$server, [bool] $pools) {
        # get all the databases or pools
        if ($pools)
        {
            $url = [ResourceList]::ElasticPoolResourceListUrl($server)
        } else {
            $url = [ResourceList]::DatabaseResourceListUrl($server)
        }

        # loop while $url is not null
        [int]$count = 0
        do {
            # query the URL and get the list of resources, filtering by pools or databases
            Log -message "AddResources: Invoke-AzRestMethod -Method GET -Path $url" -logLevel "Verbose"
            $response = Invoke-AzRestMethod -Method GET -Path $url;
            Log -message "response StatusCode: $($response.StatusCode)" -logLevel "Verbose"
            $content = @(($response.Content | ConvertFrom-Json).value);
            $content | ForEach-Object {
                # if the pools flag is set then all the resources are all pools and we need to add them, otherwise they are databases
                if ($pools) {
                    $resource = [DatabaseResource]::new($server, $_, $true);
                    $this.Add($resource);
                    $count = $count + 1;
                    Log -message "Found ElasticPool: $($resource.Name)" -logLevel "Verbose"
                # Check if the resource is in a pool and ignore if so (some databases may be in pools), if not add it to the list
                } elseif (-not ($pools -or [DatabaseResource]::IsInElasticPool($_))) {
                    $resource = [DatabaseResource]::new($server, $_, $false);
                    $this.Add($resource);
                    $count = $count + 1;
                    Log -message "Found Database: $($resource.Name)" -logLevel "Verbose"
                }
            } 
            # get the next page of results if there is one
            # check if the content has a nextLink property, if so, get the next page of results
            $url = $null;
            # convert the response content to a PSObject and check if it has a nextLink property
            $responseObject = $response.Content | ConvertFrom-Json;
            if ($responseObject | Get-Member -Name "nextLink" -MemberType "NoteProperty") {
                $url = $responseObject.nextLink;
                # remove the ARM base from the url
                $url = $url -replace [regex]::Escape($($global:ARMBaseUri)), "";
            }
        } while ($null -ne $url);
        # return the number of resources added
        return $count;
    }

    # Adds a list of Resource objects (databases and elastic pools) in a server to this list
    # returns the number of resources added
    [int]AddResources([Server]$server) {
        # Add the pools and databases to the list of servers
        return $this.AddDatabaseOrPoolResources($server, $true) + $this.AddDatabaseOrPoolResources($server, $false)
    }

    # Helper to get the number of resources in the list that are in the specified FailoverStatus
    [int]CountInStatus([FailoverStatus]$FailoverStatus) {
        [int]$count = 0;
        foreach ($resource in $this) {
            if ($resource.FailoverStatus -eq $FailoverStatus) {
                $count++;
            }
        }
        return $count;
    }

    # Helper to determine if the list has any resources that are not complete
    [bool]HasPending() {
        foreach ($resource in $this) {
            if (-not ($resource.IsComplete())) {
                return $true;
            }
        }
        return $false;
    }
}

# Class that represents a list of servers and associates helper methods
class ServerList : System.Collections.Generic.List[object]{
    # Helper to get the url (path) to get the list of servers from the subscription and resource group
    static [string]ServerListUrl([string]$subscriptionId, [string]$resourceGroupName) {
        return "/subscriptions/$subscriptionId/resourcegroups/$resourceGroupName/providers/Microsoft.Sql/servers?api-version=2021-02-01-preview";
    }

    # Adds the list of servers in a subscriptions resource group to this list. If no logical server name is provided, all logical servers 
    # are enumerated. If $logicalServerName is provided, the method just adds that server to the list. 
    [int]AddServers([string]$subscriptionId, [string]$resourceGroupName, [string]$logicalServerName) {
        $url = [ServerList]::ServerListUrl($subscriptionId,$resourceGroupName)
        Log -message "AddServers: Invoke-AzRestMethod -Method GET -Path $url" -logLevel "Verbose"
        $response = Invoke-AzRestMethod -Method GET -Path $url;
        Log -message "response StatusCode: $($response.StatusCode)" -logLevel "Verbose"
        $content = ($response.Content | ConvertFrom-Json).value;
        $serverArray = @();
        # if we have more than one server, split the logicalServerName into an array
        if (-not [String]::IsNullOrEmpty($logicalServerName)){
            $serverArray = $logicalServerName.Split(",") | ForEach-Object { $_.Trim() };
        }
        [int]$count = 0;
        $content | ForEach-Object {
            if ([String]::IsNullOrEmpty($logicalServerName) -or ($serverArray -contains $_.name)) {
                $this.Add([Server]::new($_));
            }
            $count++;
        }
        return $count;
    }
}
#endregion

#region BulkFailover class
# Class that executes the failover process for all database or elastic pool resources in a resource group within a subscription
class BulkFailover{
    [ServerList]$servers # list of servers in the resource group
    [ResourceList]$resources # list of resources in the servers

    # Constructor creates the lists of servers and resources
    BulkFailover() {
        $this.servers = ([ServerList]::new());
        $this.resources = ([ResourceList]::new());
    }

    # Adds a list of servers to the servers list using the subscriptionId and resource group name
    # returns the number of servers added
    [int]AddServers([string]$subscriptionId, [string]$resourceGroupName, [string]$logicalServerName) {
        $serversAdded = $this.servers.AddServers($subscriptionId, $resourceGroupName, $logicalServerName);
        if ($serversAdded -gt 0) { 
            Log -message "Found $serversAdded servers in resource group $resourceGroupName in subscription $subscriptionId." -logLevel "Info";
        }
        return $serversAdded;
    }

    # Adds a list of resources from the server to the resources list
    # returns the number of resources added
    [int]AddServerResources($server) {
        $count = $this.resources.AddResources($server);
        Log -message "Found $count resources in server $($server.Name) in resource group $($server.ResourceGroupName) in subscription $($server.SubscriptionId)" -logLevel "Info";
        return $count;
    }

    # Adds a list of resources from all the servers in the servers list to the resources list
    # returns the number of resources added
    [int]AddResources() {
        [int]$count = 0;
        $this.servers | ForEach-Object {
            $count += $this.AddServerResources($_);
        }
        return $count;
    }

    # Fail over all the resources in the resources list that are Pending
    [void]Failover() {
        $this.resources | ForEach-Object {
            if ($_.FailoverStatus -eq ([FailoverStatus]::Pending)) {
                $_.Failover();
            }
        }
    }

    # Update the failover FailoverStatus of all resources that are InProgress
    [void]UpdateFailoverStatus() {
        $this.resources | ForEach-Object {
            if ($_.FailoverStatus -eq ([FailoverStatus]::InProgress)) {
                $_.UpdateFailoverStatus();
            }
        }
    }

    # Add the servers in all resource groups for a subscription and return the number of servers found
    [int]AddServersInSubscription([string]$subscriptionId, [string]$logicalServerName) {
        # In order to list the resource groups for a sub, we need to select the subscription first
        [int]$count = 0;
        $resourceGroups = Get-AzResourceGroup;
        $resourceGroups | ForEach-Object {
            $resourceGroupName = $_.ResourceGroupName;
            Log -message "Adding resources for resource group $resourceGroupName in subscription $subscriptionId." -logLevel "Info";
            $count += $this.AddServers($subscriptionId, $resourceGroupName, $logicalServerName);
        }
        return $count;
    }

    # Main body that does the bulk failover
    [void]Run($subscriptionId, $resourceGroupName, $logicalServerName){
        $start = Get-Date;
        Log -message "BulkFailover.Run($subscriptionId, $resourceGroupName, $logicalServerName)" -logLevel "Info"
        
        # Get the default subscription and add the resource groups for it
        if ([String]::IsNullOrEmpty($resourceGroupName)) {
            $count = $this.AddServersInSubscription($subscriptionId, $logicalServerName);
        } else {
            $count = $this.AddServers($subscriptionId, $resourceGroupName, $logicalServerName);
        }
        
        Log -message "Found $count total servers in subscription $subscriptionId" -logLevel "Info";
        $this.servers | Format-Table

        if ($this.servers.Count -eq 0) {
            $errorMsg = "No servers found in subscription: $subscriptionId, resourceGroup: $resourceGroupName. Check the server name, resource group name and verify script has access to it.";
            throw $errorMsg;
        }
        
        # add the resources for all the servers and Log -message the start of the failover process and the time
        $count = $this.AddResources();
        Log -message "Starting bulk failover of a total of $($this.resources.Count) resources in $($this.servers.Count) servers." -logLevel "Info";

        # loop until all resources are failed or succeeded
        do {
            # failover Pending, wait for the sleep time and update FailoverStatus
            $toFailoverCount = ($this.resources.CountInStatus([FailoverStatus]::Pending))
            if ($toFailoverCount -gt 0)
            {
                Log -message "$toFailoverCount resources to be failed over...." -logLevel "Verbose"
                $this.Failover();
            }
            $inProgressCount = ($this.resources.CountInStatus([FailoverStatus]::InProgress))
            if ($inProgressCount -gt 0)
            {
                Log -message "$inProgressCount resources in progress.... " -logLevel "Verbose"
                Start-Sleep -Seconds $global:SleepTime;
            }
            $this.UpdateFailoverStatus();
        }while ($this.resources.HasPending());
    
        # Log -message the final FailoverStatus of the resources
        $end = Get-Date;
        Log -message "Succesfully failedover $($this.Resources.CountInStatus([FailoverStatus]::Succeeded)) out of $($this.Resources.Count) resources. Process took: $($end - $start)." -logLevel "Always";
        if ($this.Resources.CountInStatus([FailoverStatus]::Failed) -gt 0) {
            Log -message "Failed to failover $($this.Resources.CountInStatus([FailoverStatus]::Failed)) eligable resources. Retry or contact system administrator for support." -logLevel "Always";
        }else{
            Log -message "All eligable resources failed over successfully." -logLevel "Always";
        }
    }
}

#endregion

# region Script Body
# Main method that runs the script to failover all databases and elastic pools in a resource group
try
{
    # Ensure we do not inherit the AzContext in the runbook
    Disable-AzContextAutosave -Scope Process | Out-Null
    
    # Set the strict variable declarations and verbose logging preference to continue so we can see the output
    Set-StrictMode -Version Latest
    $VerbosePreference = "Continue"

    # Make script stop on exception
    $ErrorActionPreference = "Stop"
    
    # Get the input parameters   
    [string]$SubscriptionId = $ScriptProperties.SubscriptionId;
    [string]$ResourceGroupName = $ScriptProperties.ResourceGroupName;
    [string]$LogicalServerName = $ScriptProperties.LogicalServerName;

    # If the parameter is * then set it to $null, 
    if ($SubscriptionId -eq "*") {
        $SubscriptionId = $null;
    } 
    if ($ResourceGroupName -eq "*") {
        $ResourceGroupName = $null;
    } 
    if ($LogicalServerName -eq "*") {
        $LogicalServerName = $null;
    }

    # First check if the subscriptionId is null, if so, throw an exception
    if ($null -eq $SubscriptionId) {
        throw "SubscriptionId cannot be null."
    }

    # Connect to the sub using a system assigned managed identity
    Log -message "Using subscription $subscriptionId" -logLevel "Verbose"
    $AzureContext = (Connect-AzAccount -Identity -Subscription $SubscriptionId).context
    Log -message "Connected to subscription $($AzureContext.Subscription.Name)." -logLevel "Verbose"
    
    # if the global checkPlannedMaintenanceNotification is set to true, check
    if ($global:CheckPlannedMaintenanceNotification) {
        # Check that a planned maintenance notification has been sent to client for the subscription
        Log -message "Checking if a planned maintenance notification has been sent to client for subscription: $SubscriptionId..." -logLevel "Always"
        
        # now check if we have a planned maintenance notification
        $plannedNotificationId = GetPlannedNotificationId;
        if ($null -eq $plannedNotificationId) {
            throw "No planned maintenance notification found for subscription: $SubscriptionId. If you have received a maintenance notification for Self Service Maintenance, please contact support. To skip this check set the value of the global variable CheckPlannedMaintenanceNotification to false."
        }

        Log -message "Planned maintenance notification found for subscription: $SubscriptionId with EventID: $plannedNotificationId, proceeding..." -logLevel "Always"
    }
    else {
        Log -message "Skipped planned maintenance notification check. Set global variable CheckPlannedMaintenanceNotification to true to enable." -logLevel "Always"
    }
    
    Log -message "Starting AzureSqlBulkFailover.ps1 on sub:'$($SubscriptionId)', resource group: '$($ResourceGroupName)', server: '$($LogicalServerName)'..." -logLevel "Always"

    # Create the bulk failover object and run the failover process
    Log -message "Initiating BulkFailover..." -logLevel "Always"
    [BulkFailover]$bulkFailover = [BulkFailover]::new();
    $bulkFailover.Run($SubscriptionId, $ResourceGroupName, $LogicalServerName);
    Log -message "Failover process complete." -logLevel "Always"
    DisplayLogMessages($global:LogLevel)
}
catch {
    # Complete all progress bars and write the error
    Log -message "Exception: $($_)" -logLevel "Always"
    DisplayLogMessages($global:LogLevel)
    throw
}

#endregion
