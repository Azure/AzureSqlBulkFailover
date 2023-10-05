# AzureSqlBulkFailover.ps1

This script is used to failover all databases and elastic pools in a subscription to a secondary, already upgraded replica. It filters by subscription, resource group and logical server name. It is intended to be used to facilitate CMW customers to upgrade their databases on demand when upgrades are ready (one touch).

## Usage

This script is intended to be run as an Azure Automation Runbook or locally.

## Parameters

- `SubscriptionId`: The ID of the subscription to failover. Optional.
- `ResourceGroupName`: The name of the resource group to failover. Optional.
- `LogicalServerName`: The name of the logical server to failover. Optional.

## Notes

- This script will failover ALL resources that the caller has access to in all subscriptions in the tenant, filtering by SubscriptionId, ResourceGroupName and LogicalServerName.
- The base URI for ARM API calls is `https://management.azure.com`.
- The script will wait for 15 seconds on each itteration before checking failover status.

## Enumerations, globals and helper functions

- `FailoverStatus`: An enumeration containing resource object FailoverStatus values.
    - `Pending`: The resource is pending to be failedover.
    - `InProgress`: The failover process is in progress.
    - `Succeeded`: The failover process succeeded.
    - `Skipped`: The failover process was skipped (the database did not need to be failed over or was not eligible).
    - `Failed`: The failover process failed.
- `Log`: A helper function to log messages to the console including the date, name of the calling class and method.

## Main script flow
The script performs the following steps:
- Authenticates to Azure using the `Connect-AzAccount` cmdlet and sets the context.
- Creates a new instance of the `BulkFailover` class.
- Invokes the Run method of the `BulkFailover` class, passing the subscriptionId, resourceGroupName and logicalServerName parameters.
- Logs the process and reports the number of resources that were failed over (were successfully updated).

The `BulkFailover` class performs the following steps:
- Adds all servers in the subscription and resource group to the `Servers` list.
- Adds all resources in all servers in the `Servers` list to the `Resources` list.
- Initiates the failover operation for all `Pending` resources in the `Resources` list.
- Updates the failover status for all resources in the `Resources` list that are in progress.
- Continues to update the failover status for all resources in the `Resources` list that are in progress until all resources are `Succeeded`, `Failed` or `Skipped`.

## License

This script is licensed under the MIT License.

## Author

Microsoft Corporation

# Classes
## Server Class

This class represents the information for a server and associated helper methods and is used by the `AzureSqlBulkFailover.ps1` script to facilitate the processing of the databases and elastic pools in the server.

### Properties

- `SubscriptionId`: The subscription ID for the server.
- `ResourceGroupName`: The resource group name for the server.
- `Name`: The name of the server.

### Constructor

- `Server([PSObject]$server)`: Takes a server response object as returned from the API call methods and creates a server object with the required properties to facilitate processing and querying of state.

### Instance Methods

- `GetSubscriptionId([PSObject]$server)`: Helper to get the subscription ID from the server response object.
- `GetResourceGroupName([PSObject]$server)`: Helper to get the resource group name from the server response object.
- `GetName([PSObject]$server)`: Helper to get the name of the server from the server response object.

## DatabaseResource Class

This class represents the base class for resource objects (databases and elastic pools) and associated helper methods.

### Properties

- `Server`: The server object that contains the resource.
- `FailoverStatus`: Used to store the FailoverStatus of the resource.
- `FailoverStatusPath`: Used to store the API path to get the FailoverStatus of the resource.
- `Message`: Used to store the last message for an API call to the resource FailoverStatus or failover.
- `Name`: Name of the resource.
- `ResourceId`: The id (path) of the resource.
- `ShouldFailover`: Used to store if the resource will upgrade when failover is invoked (if this is false, resource will be skipped).

### Constructor

- `DatabaseResource([Server]$server, [PSObject]$resource)`: Takes a server object and a resource object (database or elastic pool) as returned from the API call methods and creates a resource object with the required properties to facilitate processing and querying of state.

### Instance Methods

- `GetResourceId([PSObject]$resource)`: Helper to get the resource ID (path) from the resource response object.
- `GetName([PSObject]$resource)`: Helper to get the name of the resource from the resource response object.
- `GetIsFailoverUpgrade([PSObject]$resource)`: Helper to determine if the failover will actually invoke the UpgradeMeNow process. This is determined by whether the CurrentSku tier of the database is not HyperScale.
- `GetFailoverUrl()`: Gets the failover URL of the resource.
- `ShouldFailover([PSObject]$resource)`: Determines if the resource should be failed over by checking its status and tier.

### Notes

- This class is used in the `AzureSqlBulkFailover.ps1` script to represent a database or elastic pool resource and its associated properties.
- The `DatabaseResource` class is used to facilitate processing and storing and querying of state for a database or elastic pool resource.
- The `GetResourceId()`, `GetName()`, and `GetIsFailoverUpgrade()` methods are used to retrieve information about the resource.
- The `DatabaseResource` class is used in conjunction with the `FailoverStatus` enumeration to determine the status of a resource failover.
- The `DatabaseResource` class is used to facilitate processing and querying of state for a database or elastic pool resource.

## ElasticPoolResource Class

This class is used in the `AzureSqlBulkFailover.ps1` script to represent an elastic pool resource and its associated properties, it descends from a database resource, overriding the GetName and GetResourceId methods to ensure a single elastic pool object is created for all databases belonging in the pool.

### Properties

This class descends from the [DatabaseResource](#databaseresource-class) class and adds no new properties to it.

### Constructor

- `ElasticPoolResource([Server]$server, [PSObject]$resource)`: Takes a server object and an elastic pool resource object as returned from the API call methods and creates an elastic pool resource object with the required properties to facilitate processing and querying of state.

### Instance Methods

- `GetResourceId([PSObject]$resource)`: Overrides base class helper to get the resource ID (path) from the resource response object.
- `GetName([PSObject]$resource)`: Overrides base class helper to get the name of the elastic pool from the resource response object which is a database in a pool (so all databases in the pool return the same name).

## ResourceList Class

This class represents a list of resources and associated helper methods.

### Properties

- Descends from `System.Collections.Generic.List[object]` and therefore exposes the properties in the generic list class.

### Constructor

- `ResourceList()`: Creates a new instance of the `ResourceList` class.

### Static Methods

- `ResourceListUrl([Server]$server)`: Helper to get the URL (path) to get the list of resources from the server.
- `IsElasticPool([PSObject]$resource)`: Determines if the resource is in an elastic pool.
- `CreateResource([Server]$server, [PSObject]$resource)`: Creates the right kind of resource, depending on whether or not it is in an elastic pool.
- `FailoverKey([PSObject]$resource)`: Returns the FailoverKey for the resource.

### Instance Methods
- `AddResources([Server]$server)`: Adds a all resources in a server to the list.
- `CountInStatus([FailoverStatus]$status)`: Counts the number of resources in the list with the specified failover status.
- `HasPending()`: Determines if there are any resources in the list that are not complete (`Succeeded`, `Failed` or `Skipped`).

## ServerList Class

This from represents a list of servers and associates helper methods.

### Properties

- Descends from `System.Collections.Generic.List[object]` and therefore exposes the properties in the generic list class.

### Constructor

- `ServerList()`: Creates a new instance of the `ServerList` class.

### Static Methods

- `ServerListUrl([string]$subscriptionId, [string]$resourceGroupName)`: Helper to get the URL (path) to get the list of servers from the subscription and resource group.

### Instance Methods
- `AddServers([string]$subscriptionId, [string]$resourceGroupName, [string]$logicalServerName)`: Adds the list of servers in a subscription's resource group to this list. If no logical server name is provided, all logical servers are enumerated. If `$logicalServerName` is provided, the method just adds that server to the list.

## BulkFailover Class

This class represents a bulk failover operation for a list of databases and elastic pools. It is used in the `AzureSqlBulkFailover.ps1` in conjunction with the `ResourceList`, `DatabaseResource`, and `ElasticPoolResource` classes to invoke a bulk failover operation for a list of resources. The `AddServers()` and `AddServersInSubscription()` add server objects to the Servers list property and the `AddResources()` then adds all databases or pools in the list of servers to the resources list. The Failover method then fails over all the resources in that list and UpdateFailoverStatus checks their status. The run method of this class is the entry point for the bulk failover process.
### Properties

- `SubscriptionId`: The ID of the subscription to failover (global parameter passed to the Run method).
- `ResourceGroupName`: The name of the resource group to failover (global parameter passed to the Run method).
- `LogicalServerName`: The name of the logical server to failover (global parameter passed to the Run method).
- `Servers`: A list of servers containing the resources (databases or pools) to failover.
- `Resources`: The list of resources (databases or pools) to failover.

## Constructor

- `BulkFailover()`: Creates a new instance of the `BulkFailover` class.

## Methods

- `AddServers([string]$subscriptionId, [string]$resourceGroupName, [string]$logicalServerName)`: Adds a list of servers to the `Servers` property, filtering those that belong to the subscription and resource group or that have the specific server name. Returns the number of servers added.
- `AddServerResources($server)`: Adds the list of resources (databases or pools) that are in a particular server to the list of resources to the `Resources` property. Returns the number of resources added for the server.
- `AddServersInSubscription([string]$subscriptionId, [string]$logicalServerName)` Adds all servers in a subscription to the `Servers` list, filtering those that have the specific server name (if provided). Returns the number of servers added.
- `AddResources()`: Adds all resources in all servers in the `Servers` list to the `Resources` list. Returns the number of resources added.
- `Failover()`: Initiates the failover operation for all `Pending` resources in the `Resources` list.
- `UpdateFailoverStatus()`: Updates the failover status for all resources in the `Resources` list that are in progress.
- `Run([string]$subscriptionId, [string]$resourceGroupName, [string]$logicalServerName)`: Runs the failover operation for all the resources matching the subscriptionId, ResourceGroupName and logicalServerName.