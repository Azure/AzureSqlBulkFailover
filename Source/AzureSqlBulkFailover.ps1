# Last Updated: 2023-08-03
# Purpose: This script is used to failover all databases and elastic pools in a subscription to a secondary, already upgraded replica
# Usage: This script is intended to be run as an Azure Automation Runbook or locally.
# Notes: This script is intended to be used to facilitate CMW customers to upgrade their databases on demand when upgrades are ready (one touch 
# Warning: This will failover ALL resources that the caller has access to in all subscriptions in the tenant, filtering by SubscriptionId, ResourceGroupName and LogicalServerName.
# Copyright 2023 Microsoft Corporation. All rights reserved. MIT License
#Read input parameters subscriptionId and ResourceGroup
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

# helper function to Log -message messages to the console including the date, name of the calling class and method
# LogLevel values can be 'Minimal', 'Info', 'Verbose'
function Log([string]$message, [string]$logLevel)
{
    if ([int](LogLevelValue($logLevel)) -le [int](LogLevelValue($global:LogLevel))) {
        $outputMessage = "$($logLevel): $([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")) => $message";
        Write-Verbose $outputMessage;
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

    # Constructor takes a Server object, and a resource object (database or elastic pool) as returned from the API call methods 
    # and creates a resource object with the required properties to facilitate processing and querying of state
    DatabaseResource([Server]$server, [PSObject]$resource) {
        $this.Server = $server;
        $this.FailoverStatus = [FailoverStatus]::Pending;
        $this.FailoverStatusPath = "";
        $this.Message = "";
        $this.Name = $this.GetName($resource); 
        $this.ResourceId = $this.GetResourceId($resource);
        $this.ShouldFailover = $this.GetIsFailoverUpgrade($resource);
    }

    # return the URL to failover the resource (without the ARM base)
    [string]FailoverUri() {
        return "$($this.ResourceId)/failover?api-version=2021-02-01-preview";
    }

    # gets the resource ID (path) from the resource object
    # this method is overridden in the ElasticPoolResource class to get the correct path for elastic pools
    [string]GetResourceId([PSObject]$resource)
    {
        return $resource.id;
    }

    # gets the name of the resource from the resource object
    # this method is overridden in the ElasticPoolResource class to get the correct name for elastic pools
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
        return ($resource.Properties.CurrentSku.tier) -ne "Hyperscale";
    }

    # Helper to determine if the resource should be failed over
    [bool]ShouldFailover([PSObject]$resource) {
        # note that if the DB is inactive and then become active during the script run
        # it will not be failed over which is fine because it will get activated on the correct upgrade domain so doesnt need to be failed over
        return $this.GetIsFailoverUpgrade($resource) -and $this.GetIsActive($resource);
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

# Class that represents an elastic pool resource, 
# needs to override the GetResourceId and GetName methods to get the correct values
class ElasticPoolResource : DatabaseResource{
    # Constructor takes a Server object, and a resource object (database or elastic pool) as returned from the API call methods
    ElasticPoolResource([Server]$server, [PSObject]$resource) : base($server, $resource) {}

    # Gets the resource ID (path) from the elastic pool resource object
    [string]GetResourceId([PSObject]$resource)
    {
        return "/subscriptions/$($this.SubscriptionId())/resourcegroups/$($this.ResourceGroupName())/providers/Microsoft.Sql/servers/$($this.ServerName())/elasticpools/$($this.Name)";
    }

    # We only have one pool with many databases, so we need to get the name for the resource from the elasticPool that the database is contained in
    # this makes the FailoverKey the same for all resources in a pool
    [string]GetName([PSObject]$resource)
    {
        return ($resource.properties.elasticPoolId).Split("/")[-1];
    }
}

#endregion

#region List classes
# Class that represents a list of resources and associated helper methods
# Note that the base class for all resources is DatabaseResource
class ResourceList : System.Collections.Generic.List[object]{
    # Helper to get the url (path) to get the list of resources from the server
    static [string]ResourceListUrl([Server]$server){
        return "/subscriptions/$($server.SubscriptionId)/resourcegroups/$($server.ResourceGroupName)/providers/Microsoft.Sql/servers/$($server.Name)/databases?api-version=2021-02-01-preview";
    }
    
    # Determines if the resource is an elastic pool
    static [bool]IsElasticPool([PSObject]$resource) {
        # use reflexion to check if the property exists
        $hasElasticPoolId = [bool]($resource.properties | Get-Member -Name "elasticPoolId" -MemberType "NoteProperty")
        return $hasElasticPoolId -and ($null -ne $resource.properties.elasticPoolId);
    }

    # Creates the right kind of resource, depending on whether or not it is an elastic pool
    static [DatabaseResource]CreateResource([Server]$server, [PSObject]$resource) {
        if ([ResourceList]::IsElasticPool($resource)) {
            [ElasticPoolResource]$object = [ElasticPoolResource]::new($server, $resource);
        }
        else {
            [DatabaseResource]$object = [DatabaseResource]::new($server, $resource);
        }
        return $object;
    }

    # returns the FailoverKey for the resource (makes all databases in an elastic pool have the same FailoverKey,
    # while allowing a database and elastic pool with the same name to have different FailoverKeys)
    static [string]FailoverKey([PSObject]$resource) {
        if ([ResourceList]::IsElasticPool($resource))
        {
            return "ElasticPool_$($resource.properties.elasticPoolId.Split("/")[-1])";
        }else{
            return "Database_$($resource.name)";
        }
    }

    # Adds a list of Resource objects (databases and elastic pools) in a server to this list
    # returns the number of resources added
    [int]AddResources([Server]$server) {
        # get all the databases (including those in pools)
        # create a hashtable to store the unique resources in
        # the resources failoverkey ensures we only add resources we can failover to the list
        $url = [ResourceList]::ResourceListUrl($server)
        # loop while $url is not null
        $resourcesToAdd = New-Object -TypeName System.Collections.Hashtable
        do {
            Log -message "AddResources: Invoke-AzRestMethod -Method GET -Path $url" -logLevel "Verbose"
            $response = Invoke-AzRestMethod -Method GET -Path $url;
            Log -message "response StatusCode: $($response.StatusCode)" -logLevel "Verbose"
            $content = ($response.Content | ConvertFrom-Json).value;
            $content | ForEach-Object {
                # create a resource object and add it to the hashtable using the failoverkey as the key
                # ensure we only create and add one resource foreeach key value
                $key = [ResourceList]::FailoverKey($_);
                if (-not $resourcesToAdd.ContainsKey($key)) {
                    $resource = [ResourceList]::CreateResource($server, $_);
                    $resourcesToAdd[$key] = $resource;
                    $this.Add($resource);
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
        return $resourcesToAdd.Count;
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

#region Script Body

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

    Log -message "Starting AzureSqlBulkFailover.ps1 on sub:'$($SubscriptionId)', resource group: '$($ResourceGroupName)', server: '$($LogicalServerName)'..." -logLevel "Always"

    # Connect to the sub using a system assigned managed identity
    Log -message "Using subscription $subscriptionId" -logLevel "Verbose"
    $AzureContext = (Connect-AzAccount -Identity -Subscription $SubscriptionId).context
    Log -message "Connected to subscription $($AzureContext.Subscription.Name)." -logLevel "Verbose"

    # Create the bulk failover object and run the failover process
    Log -message "Initiating BulkFailover..." -logLevel "Always"
    [BulkFailover]$bulkFailover = [BulkFailover]::new();
    $bulkFailover.Run($SubscriptionId, $ResourceGroupName, $LogicalServerName);
    Log -message "Failover process complete." -logLevel "Always"
}
catch {
    # Complete all progress bars and write the error
    Log -message "Exception: $($_)" -logLevel "Always"
    throw
}

#endregion
