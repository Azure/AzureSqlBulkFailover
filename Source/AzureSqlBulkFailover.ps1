# Written by: Eduardo Rojas (eduardoro@microsoft.com) - With the help of GitHub CoPilot :)
# Last Updated: 2023-08-03
# Purpose: This script is used to failover all databases and elastic pools in a subscription to a secondary, already upgraded replica
# Usage: This script is intended to be run as an Azure Automation Runbook or locally.
# Notes: This script is intended to be used to facilitate CMW customers to upgrade their databases on demand when upgrades are ready (one touch 
# Warning: This will failover ALL resources that the caller has access to in all subscriptions in the tenant.
# copywrite 2023 Microsoft Corporation. All rights reserved. MIT License

# Base URI for ARM API calls, used to parse out the FailoverStatus path for the failover request
$global:ARMBaseUri = "https://management.azure.com";
$global:MaxAttempts = 5;
$global:RetryThrottleDelay = 5; # minutes
$global:SleepTime = 15; # seconds
$global:RecentFailoverTime = 20; # The time in minutes to check for a completed or in progress failover when the failover request is throttled

#region Enumerations, globals and helper functions
# enum containing resource object FailoverStatus values
enum FailoverStatus {
    Pending
    WaitingToRetry
    InProgress
    Succeeded
    Skipped
    Failed
}

# helper function to log messages to the console including the date, name of the calling class and method
function Log($message) {
    Write-Verbose "$([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")) => $message"
}
#endregion

#region basic classes
# Class that represents the base class for resource objects (databases and elastic pools)
class DatabaseResource {
    [Server]$Server # The server object that contains the resource
    [FailoverStatus]$FailoverStatus # Used to store the FailoverStatus of the resource
    [string]$FailoverStatusPath # Used to store the API path to get the FailoverStatus of the resource
    [string]$Message # Used to store the last message for an API call to the resource FailoverStatus or failover
    [datetime]$NextAttempt # Used to store the next time to attempt to get the FailoverStatus of the resource
    [int]$Attempts # Used to store the number of times we have tried to failover the resource
    [string]$Name # Name of the resource
    [string]$ResourceId # The id (path) of the resource
    [bool]$ShouldFailover # Used to store if the resource will upgrade when failver is invoked (if this is false, resource will be skipped)
    [bool]$RecentFailoverChecked # Used to store if the resource has been checked for a recent failover

    # Constructor takes a Server object, and a resource object (database or elastic pool) as returned from the API call methods 
    # and creates a resource object with the required properties to facilitate processing and querying of state
    DatabaseResource([Server]$server, [PSObject]$resource) {
        $this.Server = $server;
        $this.FailoverStatus = [FailoverStatus]::Pending;
        $this.FailoverStatusPath = "";
        $this.Message = "";
        $this.NextAttempt = Get-Date;
        $this.Attempts = 0;
        $this.Name = $this.GetName($resource); 
        $this.ResourceId = $this.GetResourceId($resource);
        $this.ShouldFailover = $this.GetIsFailoverUpgrade($resource);
        $this.RecentFailoverChecked = $false;
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

    # Checks if the resource was recently failed over and sets the status to Skipped if it was
    [void]CheckForRecentFailover(){
        # create the filter and url to get the activity log for the resource
        $now = (Get-Date).ToUniversalTime()
        $startTime = $now.AddMinutes(-$global:RecentFailoverTime).ToString("yyyy-MM-ddTHH:mm:ssZ");
        $endTime = $now.ToString("yyyy-MM-ddTHH:mm:ssZ");
        $filter = "eventTimestamp ge '$startTime' and eventTimestamp le '$endTime' and eventChannels eq 'Admin, Operation' and resourceGroupName eq '$($this.ResourceGroupName())' and resourceId eq '$($this.ResourceId)' and levels eq 'Critical,Error,Warning,Informational'"
        $url = "/subscriptions/$($this.SubscriptionId())/providers/microsoft.insights/eventtypes/management/values?api-version=2017-03-01-preview&`$filter=$filter"

        # Get the activity log for the resource
        $response = Invoke-AzRestMethod -Method GET -Path $url;
        $requestContent = $response.Content | ConvertFrom-Json;

        # Check if the response contains any activity log entries for recent failovers and set status to skipped if successful
        $this.RecentFailoverChecked = $true;        
        $failoverEntries = $requestContent.value | Where-Object {
            (($_.authorization.action -eq "Microsoft.Sql/servers/databases/failover/action") -or
            ($_.authorization.action -eq "Microsoft.Sql/servers/elasticpools/failover/action")) -and
            ($_.status.value -eq "Succeeded")
        }
        if (($null -ne $failoverEntries) -and ($failoverEntries.Count -gt 0)) {
            $this.FailoverStatus = [FailoverStatus]::Succeeded;
        }
    }

    # Fails over the resource, updating the required request information and FailoverStatus in it
    [void]Failover()
    {
        #only failover resources that should be failed over, set the FailoverStatus of the rest to skipped
        if ($this.ShouldFailover) {
            $response = Invoke-AzRestMethod -Method POST -Path $this.FailoverUri();
            $this.Attempts++;
            if (($response.StatusCode -eq 202) -or ($response.StatusCode -eq 200)) {# check if the failover request was accepted or completed Succeededfully
                # get the header that gives us the URL to query the FailoverStatus of the request and remove the ARM prefix, add it to the resource as the FailoverStatus path
                # get the AsynOperationHeader value from the response and parse out the path to the FailoverStatus of the request
                $this.FailoverStatus = [FailoverStatus]::InProgress;
                $this.Message = "";
                $CheckStatusPath = $response.Headers | Where-Object -Property Key -EQ "Azure-AsyncOperation";
                $this.FailoverStatusPath  = ($CheckStatusPath.value[0]) -replace [regex]::Escape($($global:ARMBaseUri)), "";
                Log "$($this.ResourceId). Failover attempt $($this.Attempts), monitoring....";
            } else {# If we got another kind of response, we failed to failover the resource
                $this.FailoverStatus = [FailoverStatus]::Failed;
                $this.Message = $response.Content;
                Log "$($this.ResourceId). Error: $($response.StatusCode) - $($this.Message).";
            }
        }
        else {
            $this.FailoverStatus = [FailoverStatus]::Skipped;
            $this.Message = "Resource is not eligible (is hyperscale) or does not need failover (is offline).";
            Log "$($this.ResourceId). $($this.Message). Will be skipped.";
        }
    }

    # update the resource FailoverStatus based on the FailoverStatus of the failover request
    # only update FailoverStatus on pending resources
    [void]UpdateFailoverStatus(){
        if ($this.FailoverStatus -eq [FailoverStatus]::InProgress) {
            $response = Invoke-AzRestMethod -Method GET -Path ($this.FailoverStatusPath)
            if ($response.StatusCode -eq 200) {
                # check the content of the request to figure out if the failover completed Succeededfully
                # if their was no error but the failover has not yest completed then do nothing
                $requestContent = $response.Content | ConvertFrom-Json;
                if ($requestContent.Status -eq "Failed") {
                    # check if we were Throttled or if there was another errror
                    If ($requestContent.Error.Code -eq "DatabaseFailoverThrottled"){
                        Log "$($this.ResourceId) => Throttle: $($requestContent.error.message) while trying to failover. Will retry in $global:RetryThrottleDelay minutes.";
                        $this.NextAttempt = (Get-Date).AddMinutes($global:RetryThrottleDelay);
                        $this.FailoverStatus = [FailoverStatus]::WaitingToRetry;
                        $this.Message = $requestContent.error.message;
                    }elseif($requestContent.Error.Code -eq "DatabaseNotInStateToFailover"){
                        Log "$($this.ResourceId) => Is serverless and offline so doesnt need failover.";
                        $this.FailoverStatus = [FailoverStatus]::Skipped;
                        $this.Message = $requestContent.error.message;
                    }
                    else{
                        Log "$($this.ResourceId) => Error: $($requestContent.error.message) while trying to failover. Will not retry.";
                        $this.FailoverStatus = [FailoverStatus]::Failed;
                        $this.Message = $requestContent.error.message;
                    }
                    # Check if we have moved into the WaitingToRetry state, if so, 
                    # get the last completed or inprogress failover attemps.
                    # If the last one was completed, then log that we dont need to failover this one and move it to the succeeded state.
                    # If the last one was inprogress, then log that we need to monitor this one and move it to the inprogress state and set the appropriate FailoverStatusPath.
                    if (($this.FailoverStatus -eq ([FailoverStatus]::WaitingToRetry)) -and ($this.RecentFailoverChecked -eq $false)){
                        $this.CheckForRecentFailover();
                    }
                }
                elseif ($requestContent.Status -eq "Succeeded") {
                    Log "$($this.ResourceId) => Successfully failed over.";
                    $this.FailoverStatus = [FailoverStatus]::Succeeded;
                }
            }
            else{
                # if the request did not complete then report the error and remove the request from the list
                Log "$($this.ResourceId) => Error: $($response.StatusCode) while trying to get FailoverStatus.";
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
        $response = Invoke-AzRestMethod -Method GET -Path $url;
        $resourcesToAdd = New-Object -TypeName System.Collections.Hashtable
        $content = ($response.Content | ConvertFrom-Json).value;
        $content | ForEach-Object {
            # create q resource object and add it to the hashtable using the failoverkey as the key
            # ensure we only create and add one resource foreeach key value
            $key = [ResourceList]::FailoverKey($_);
            if (-not $resourcesToAdd.ContainsKey($key)) {
                $resource = [ResourceList]::CreateResource($server, $_);
                $resourcesToAdd[$key] = $resource;
                $this.Add($resource);
            }
        }    
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
    [string]ServerListUrl([string]$subscriptionId, [string]$resourceGroupName) {
        return "/subscriptions/$subscriptionId/resourcegroups/$resourceGroupName/providers/Microsoft.Sql/servers?api-version=2021-02-01-preview";
    }

    # Adds the list of servers in a subscriptions resource group to this list
    [int]AddServers([string]$subscriptionId, [string]$resourceGroupName) {
        $url = $this.ServerListUrl($subscriptionId,$resourceGroupName)
        $response = Invoke-AzRestMethod -Method GET -Path $url;
        $content = ($response.Content | ConvertFrom-Json).value;
        [int]$count = 0;
        $content | ForEach-Object {
            $this.Add([Server]::new($_));
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
    [int]AddServers([string]$subscriptionId, [string]$resourceGroupName) {
        $serversAdded = $this.servers.AddServers($subscriptionId, $resourceGroupName);
        Log "Found $serversAdded servers in resource group $resourceGroupName in subscription $subscriptionId.";
        return $serversAdded;
    }

    # Adds a list of resources from the server to the resources list
    # returns the number of resources added
    [int]AddServerResources($server) {
        $count = $this.resources.AddResources($server);
        Log "Found $count resources server $($server.Name) in resource group $($server.ResourceGroupName) in subscription $($server.SubscriptionId)";
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

    # Fail over all the resources in the resources list that are Pending or WaitingToRetry and ready for retry
    [void]Failover() {
        $this.resources | ForEach-Object {
            if ($_.FailoverStatus -eq ([FailoverStatus]::Pending)) {
                $_.Failover();
            }elseif ($_.FailoverStatus -eq ([FailoverStatus]::WaitingToRetry)) {
                # check if enough time has gone by, if so, failover if the number of Attempts is less than the max
                # if the number of Attempts has reached the max, then set the FailoverStatus to failed
                if ((Get-Date) -ge $_.NextAttempt) {
                    if ($_.Attempts -lt $global:MaxAttempts) {
                        $_.Failover();
                    }else{
                        Log "$($_.ResourceId) Max failover attempts reached. Failed to failover. $($_.Message)"
                        $_.FailoverStatus = [FailoverStatus]::Failed;
                    }
                }
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
    [int]AddServersInSubscription([string]$subscriptionId) {
        # In order to list the resource groups for a sub, we need to select the subscription first
        Select-AzSubscription -SubscriptionId $subscriptionId;
        [int]$count = 0;
        $resourceGroups = Get-AzResourceGroup;
        $resourceGroups | ForEach-Object {
            $resourceGroupName = $_.ResourceGroupName;
            Log "Adding resources for resource group $resourceGroupName in subscription $subscriptionName ($subscriptionId).";
            $count += $this.AddServers($subscriptionId, $resourceGroupName);
        }
        return $count;
    }

    # Main body that does the bulk failover
    [void]Run($subscriptionId){
        $start = Get-Date;
        # Get the default subscription and add the resource groups for it
        $count = $this.AddServersInSubscription($subscriptionId);
        Log "Found $count servers in subscription $subscriptionId.";

        # add the resources for all the servers and log the start of the failover process and the time
        $count = $this.AddResources();
        Log "Starting bulk failover of a total of $($this.resources.Count) resources in $($this.servers.Count) servers.";

        # loop until all resources are failed or succeeded
        do {
            # failover Pending or WaitingToRetry, wait for the sleep time and update FailoverStatus
            $toFailoverCount = ($this.resources.CountInStatus([FailoverStatus]::Pending))+($this.resources.CountInStatus([FailoverStatus]::WaitingToRetry))
            Log "$toFailoverCount resources to be failed over...."
            $this.Failover();
            $inProgressCount = ($this.resources.CountInStatus([FailoverStatus]::InProgress))
            Log "$inProgressCount resources in progress.... "
            Start-Sleep -Seconds $global:SleepTime;
            $this.UpdateFailoverStatus();
        }while ($this.resources.HasPending());
    
        # log the final FailoverStatus of the resources
        $end = Get-Date;
        Log "Succesfully failedover $($this.Resources.CountInStatus([FailoverStatus]::Succeeded)) out of $($this.Resources.Count) resources. Process took: $($end - $start).";
        if ($this.Resources.CountInStatus([FailoverStatus]::Failed) -gt 0) {
            Log "Failed to failover $($this.Resources.CountInStatus([FailoverStatus]::Failed)) eligable resources. Retry or contact system administrator for support.";
        }else{
            Log "All eligable resources failed over successfully.";
        }
    }
}

#endregion

#region Script Body
# Main method that runs the script to failover all databases and elastic pools in a resource group
try
{
    # Ensure we do not inherit the AzContext in the runbook
    Disable-AzContextAutosave -Scope Process
    # Set the strict variable declarations and verbose logging preference to continue so we can see the output
    Set-StrictMode -Version Latest
    $VerbosePreference = "Continue"
    Log "Starting UpgradeMeNow script. Authenticating....."
    # Get the default subscription
    $AzureContext = (Connect-AzAccount -Identity).context
    $subscriptionId = $AzureContext.Subscription
    # set and store context, subscriptionId and the resource group name
    Set-AzContext -SubscriptionName $subscriptionId -DefaultProfile $AzureContext
    Log "Initiating Bulk Failover for the following subscriptions: $subscriptionId"
    # Create the bulk failover object and run the failover process
    [BulkFailover]$bulkFailover = [BulkFailover]::new();
    $bulkFailover.Run($subscriptionId);
    Log "Failover process complete."
}
catch {
    # Complete all progress bars and write the error
    Write-Error -Message $_.Exception
    throw $_.Exception
}
#endregion