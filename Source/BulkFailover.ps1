# Written by: Eduardo Rojas (eduardoro@microsoft.com) - With the help of GitHub CoPilot :)
# Last Updated: 2023-08-03
# Purpose: This script is used to failover all databases and elastic pools in a subscription to a secondary, already upgraded replica
# Usage: This script is intended to be run as an Azure Automation Runbook or locally
# Notes: This script is intended to be used to facilitate CMW customers to upgrade their databases on demand when upgrades are ready (one touch upgrade)
# copywrite 2023 Microsoft Corporation. All rights reserved. MIT License

# Get the subscriptionId and resource group name from the parameters}
# if on a runbook then will use the default sub and resource group
param (
    [string] $SubscriptionId,
    [string] $ResourceGroupName
)

# Base URI for ARM API calls, used to parse out the status path for the failover request
$global:ARMBaseUri = "https://management.azure.com";
$global:MaxRetries = 3;
$global:RetryDelay = 5; # minutes
$global:SleepTime = 15; # seconds

#region Enumerations, globals and helper functions
# enum containing resource object status values
enum ResourceStatus {
    New
    Throttled
    InProgress
    Succeeded
    Failed
}


# helper function to log messages to the console including the date, name of the calling class and method
function Log($message) {
    # Get the name of the calling class and method
    $stack1 = (Get-PSCallStack)[1]
    $variables = $stack1.GetFrameVariables();
    $className = $variables["this"].Value
    $functionName = $stack1.FunctionName
    Write-Host "$([DateTime]::Now.ToString("yyyy-MM-dd HH:mm:ss")) - $className.$functionName => $message"
}

#endregion

#region server and resource classes
# Class that represents the base class for resource objects (databases and elastic pools)
class DatabaseResource {
    [Server]$Server # The server object that contains the resource
    [ResourceStatus]$Status # Used to store the status of the resource
    [string]$StatusPath # Used to store the API path to get the status of the resource
    [string]$Message # Used to store the last message for an API call to the resource status or failover
    [datetime]$NextAttempt # Used to store the next time to attempt to get the status of the resource
    [int]$RetryCount # Used to store the number of times we have tried to failover the resource
    [string]$Name # Name of the resource
    [string]$ResourceId # The id (path) of the resource

    # Constructor takes a Server object, and a resource object (database or elastic pool) as returned from the API call methods 
    # and creates a resource object with the required properties to facilitate processing and querying of state
    Resource([Server]$server, [PSObject]$resource) {
        $this.Server = $server;
        $this.Status = [ResourceStatus]::New;
        $this.StatusPath = "";
        $this.Message = "";
        $this.NextAttempt = Get-Date;
        $this.RetryCount = 0;
        $this.Name = GetName($resource); 
        $this.ResourceId = GetResourceId($resource);
    }

    # return the URL to failover the resource (without the ARM base)
    [string]FailoverUri() {
        return "$($this.ResourceId)/failover?api-version=2021-02-01-preview";
    }

    # Fails over the resource, updating the required request information and status in it
    [void]Failover()
    {
        $response = Invoke-AzRestMethod -Method POST -Path $this.FailoverUri();
        if (($response.StatusCode -eq 202) -or ($response.StatusCode -eq 200)) {# check if the failover request was accepted or completed Succeededfully
            # get the header that gives us the URL to query the status of the request and remove the ARM prefix, add it to the resource as the status path
            # get the AsynOperationHeader value from the response and parse out the path to the status of the request
            $this.Status = [ResourceStatus]::InProgress;
            $this.Message = "";
            $CheckStatusPath = $response.Headers["Azure-AsyncOperation"];
            $CheckStatusPath = $CheckStatusPath -replace [regex]::Escape($($global:ARMBaseUri)), "";
            $this.StatusPath = $CheckStatusPath;
            Log "$($this.ResourceId). Monitoring....";
        } else {# If we got another kind of response, we failed to failover the resource
            $this.Status = [ResourceStatus]::Failed;
            $this.Message = $response.Content;
            Log "$($this.ResourceId). Error: $($response.StatusCode) - $($this.Message).";
        }
    }

    # update the resource status based on the status of the failover request
    # only update status on pending resources
    [void]UpdateFailoverStatus(){
        if ($this.Status -eq [ResourceStatus]::InProgress) {
            $response = Invoke-AzRestMethod -Method GET -Path $this.StatusPath
            if ($response.StatusCode -eq 200) {
                # check the content of the request to figure out if the failover completed Succeededfully
                # if their was no error but the failover has not yest completed then do nothing
                $requestContent = $response.Content | ConvertFrom-Json;
                if ($requestContent.Status -eq "Failed") {
                    Log "$($this.ResourceId) => Throttle: $($requestContent.error.message) while trying to failover.";
                    $this.RetryCount++;
                    $this.NextAttempt = (Get-Date).AddMinutes($global:RetryDelay);
                    $this.Status = [ResourceStatus]::Throttled;
                    $this.Message = $requestContent.error.message;
                }
                elseif ($requestContent.Status -eq "Succeeded") {
                    Log "$($this.ResourceId) => Successfully failed over.";
                    $this.Status = [ResourceStatus]::Succeeded;
                }
            }
            else{
                # if the request did not complete then report the error and remove the request from the list
                Log "$($this.ResourceId) => Error: $($response.StatusCode) while trying to get status.";
                $this.Status = [ResourceStatus]::Failed;
                $this.Message = $response.Content;
            }
        }
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
}

# Class that represents an elastic pool resource, 
# needs to override the GetResourceId and GetName methods to get the correct values
class ElasticPoolResource : DatabaseResource{
    # Gets the resource ID (path) from the elastic pool resource object
    [string]GetResourceId([PSObject]$resource)
    {
        return "/subscriptions/$($this.SubscriptionId)/resourcegroups/$($this.ResourceGroupName)/providers/Microsoft.Sql/servers/$($this.Server.Name)/elasticpools/$($this.Name)";
    }

    # We only have one pool with many databases, so we need to get the name for the resource from the elasticPool that the database is contained in
    # this makes the FailoverKey the same for all resources in a pool
    static [string]GetName([PSObject]$resource)
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
        $this.SubscriptionId = GetSubscriptionId($server);
        $this.ResourceGroupName = GetResourceGroupName($server);
        $this.Name = GetName($server);
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
class ResourceList : System.Collections.Generic.List[DatabaseResource]{
    # Helper to get the url (path) to get the list of resources from the server
    static [string]ResourceListUrl([Server]$server){
        return "/subscriptions/$($server.SubscriptionId)/resourcegroups/$($server.ResourceGroupName)/providers/Microsoft.Sql/servers/$($server.Name)/databases?api-version=2021-02-01-preview";
    }
    
    # Determines if the resource is an elastic pool
    static [bool]IsElasticPool([PSObject]$resource) {
        return $null -ne $resource.properties.elasticPoolId;
    }

    # Creates the right kind of resource, depending on whether or not it is an elastic pool
    static [DatabaseResource]CreateResource([Server]$server, [PSObject]$resource) {
        if (ResourceList::IsElasticPool($resource)) {
            return [ElasticPoolResource]::new($server, $resource);
        }
        else {
            return [DatabaseResource]::new($server, $resource);
        }
    }

    # returns the FailoverKey for the resource (makes all databases in an elastic pool have the same FailoverKey,
    # while allowing a database and elastic pool with the same name to have different FailoverKeys)
    static [string]FailoverKey([PSObject]$resource) {
        if (ResourceList::IsElasticPool($resource))
        {
            return "ElasticPool_$($resource.properties.elasticPoolName)";
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
        $url = ResourceListUrl $server
        $response = Invoke-AzRestMethod -Method GET -Path $url;
        $resourcesToAdd = New-Object -TypeName System.Collections.Hashtable
        $content = ($response.Content | ConvertFrom-Json).value;
        $content | ForEach-Object {
            # create q resource object and add it to the hashtable using the failoverkey as the key
            # ensure we only create and add one resource foreeach key value
            $key = ResourceList::FailoverKey($_);
            if (-not $resourcesToAdd.ContainsKey($key)) {
                $resource = $this.CreateResource($server, $_);
                $resourcesToAdd[$key] = $resource;
                $this.Add($resource);
            }
        }    
        return $resourcesToAdd.Count;
    }

    # Helper to get the number of resources in the list that are in the specified ResourceStatus
    [int]CountInStatus([ResourceStatus]$status) {
        return $this.FindAll({$_.Status -eq $status}).Count;
    }

}

# Class that represents a list of servers and associates helper methods
class ServerList : System.Collections.Generic.List[Server]{
    # Helper to get the url (path) to get the list of servers from the subscription and resource group
    static [string]ServerListUrl([string]$subscriptionId, [string]$resourceGroupName) {
        return "/subscriptions/$subscriptionId/resourcegroups/$resourceGroupName/providers/Microsoft.Sql/servers?api-version=2021-02-01-preview";
    }

    # Adds the list of servers in a subscriptions resource group to this list
    [int]AddServers([string]$subscriptionId, [string]$resourceGroupName) {
        $response = Invoke-AzRestMethod -Method GET -Path ServerList::ServerListUrl($subscriptionId, $resourceGroupName);
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
    # Constructor creates the lists of servers and resources
    BulkFailover() {
        $this.servers = [ServerList]::new();
        $this.resources = [ResourceList]::new();
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

    # Fail over all the resources in the resources list that are new or throttled and ready for retry
    [void]Failover() {
        $this.resources | ForEach-Object {
            if ($_.Status -eq ([ResourceStatus]::New)) {
                $_.Failover();
            }elseif ($_.Status -eq ([ResourceStatus]::Throttled)) {
                # check if enough time has gone by, if so, failover if the number of retries is less than the max
                # if the number of retries has reached the max, then set the status to failed
                if ((Get-Date) -ge $_.RetryTime) {
                    if ($_.Retries -lt $global:MaxRetries) {
                        $_.Failover();
                    }else{
                        $_.Status = [ResourceStatus]::Failed;
                    }
                }
            }
        }
    }

    # Update the failover status of all resources that are InProgress
    [void]UpdateFailoverStatus() {
        $this.resources | ForEach-Object {
            if ($_.Status -eq ([ResourceStatus]::InProgress)) {
                $_.UpdateFailoverStatus();
            }
        }
    }

    # Main body that does the bulk failover
    [void]Run([string] $SubscriptionId, [string] $ResourceGroupName) {
        # log the start of the failover process and the time
        $start = Get-Date;
        Log "Starting bulk failover of all resources in resource group $ResourceGroupName in subscription $SubscriptionId at $start."

        # add the servers and resources
        $this.AddServers($SubscriptionId, $ResourceGroupName);
        $this.AddResources();
        Log "Found $($this.resources.Count) resources in $($this.servers.Count) to be failed over."

        # loop until all resources are failed or succeeded
        do {
            # failover new or throttled, wait for the sleep time and update status
            $this.Failover();
            Start-Sleep -Seconds $global:SleepTime;
            $this.UpdateFailoverStatus();
¿        }while (($this.resources.CountInStatus([ResourceStatus]::New) -gt 0) -or `
                ($this.resources.CountInStatus([ResourceStatus]::Throttled) -gt 0) -or `
                ($this.resources.CountInStatus([ResourceStatus]::InProgress) -gt 0));
    
        # log the final status of the resources
        $end = Get-Date;
        Log "Succeeded Failing over $($this.Resources.CountInStatus([ResourceStatus]::Failed)) out of $($this.Resources.Count) resources by $end. Process took: $($end - $start).";
    }
}

#endregion

#region Script Body
# Main method that runs the script to failover all databases and elastic pools in a resource group
try
{
    # Set the verbose preference to continue so we can see the output
    $VerbosePreference = "Continue"
    Log "Starting UpgradeMeNow script. Authenticating....."

    if ($env:AutomationWorker) {
        Log "Running on azure runbook.."
        # Connect to Azure with system-assigned managed identity and get the default subscriptionId
        # Ensures you do not inherit an AzContext in your runbook
        Disable-AzContextAutosave -Scope Process
        Connect-AzAccount
        $AzureContext = (Connect-AzAccount -Identity).context
        $subscriptionId = $AzureContext.Subscription
        # set and store context, subscriptionId and the resource group name
        Set-AzContext -SubscriptionName $subscriptionId -DefaultProfile $AzureContext
        # Get the resource group
        $resourceGroupName = Get-AzResourceGroup | Select-Object -ExpandProperty resourceGroupName
    }
    else {
        Log "Running locally.."
        # To do this locally, you need to have the Az module installed and logged in
        # Select the subscription 
        Select-AzSubscription -SubscriptionId $subscriptionId
    }

    # Create the bulk failover object and run the failover process
    [BulkFailover]$bulkFailover = [BulkFailover]::new();
    $bulkFailover.Run($subscriptionId, $resourceGroupName);
}
catch {
    # Complete all progress bars and write the error
    Write-Error -Message $_.Exception
    throw $_.Exception
}
#endregion
