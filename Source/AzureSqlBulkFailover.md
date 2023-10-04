# AzureSqlBulkFailover.ps1

This script is used to failover all databases and elastic pools in a subscription to a secondary, already upgraded replica.

## Usage

This script is intended to be run as an Azure Automation Runbook or locally.

## Parameters

- `SubscriptionId`: The ID of the subscription to failover. Optional.
- `ResourceGroupName`: The name of the resource group to failover. Optional.
- `LogicalServerName`: The name of the logical server to failover. Optional.

## Notes

- This script is intended to be used to facilitate CMW customers to upgrade their databases on demand when upgrades are ready (one touch).
- This script will failover ALL resources that the caller has access to in all subscriptions in the tenant, filtering by SubscriptionId, ResourceGroupName and LogicalServerName.
- The base URI for ARM API calls is `https://management.azure.com`.
- The script will wait for 15 seconds on each itteration before checking failover status.

## Enumerations, globals and helper functions

- `FailoverStatus`: An enumeration containing resource object FailoverStatus values.
- `Log`: A helper function to log messages to the console including the date, name of the calling class and method.

## License

This script is licensed under the MIT License.

## Author

Microsoft Corporation

# Classes
## Server Class

This class represents the information for a server and associated helper methods.

### Properties

- `SubscriptionId`: The subscription ID for the server.
- `ResourceGroupName`: The resource group name for the server.
- `Name`: The name of the server.

### Constructor

- `Server([PSObject]$server)`: Takes a server response object as returned from the API call methods and creates a server object with the required properties to facilitate processing and querying of state.

### Methods

- `GetFailoverStatus()`: Gets the failover status of the server.
- `GetFailoverStatusPath()`: Gets the failover status path of the server.
- `GetFailoverStatusUrl()`: Gets the failover status URL of the server.
- `GetFailoverUrl()`: Gets the failover URL of the server.
- `GetPrimaryLocation()`: Gets the primary location of the server.
- `GetSecondaryLocation()`: Gets the secondary location of the server.
- `GetServerUrl()`: Gets the server URL of the server.

### Notes

- This class is used in the `AzureSqlBulkFailover.ps1` script to represent a server and its associated properties.
- The `Server` class is used to facilitate processing and querying of state for a server.
- The `GetFailoverStatus()`, `GetFailoverStatusPath()`, `GetFailoverStatusUrl()`, `GetFailoverUrl()`, `GetPrimaryLocation()`, `GetSecondaryLocation()`, and `GetServerUrl()` methods are used to retrieve information about the server and its failover status.
- The `Server` class is used in conjunction with the `FailoverStatus` enumeration to determine the status of a server failover.
- The `Server` class is used to facilitate processing and querying of state for a server.
- The `Server` class is used in the `AzureSqlBulkFailover.ps1` script to represent a server and its associated properties.

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

### Methods

- `GetResourceId([PSObject]$resource)`: Helper to get the resource ID (path) from the resource response object.
- `GetName([PSObject]$resource)`: Helper to get the name of the resource from the resource response object.
- `GetIsFailoverUpgrade([PSObject]$resource)`: Helper to determine if the failover will actually invoke the UpgradeMeNow process. This is determined by whether the CurrentSku tier of the database is not HyperScale.
- `GetFailoverUrl()`: Gets the failover URL of the resource.
- `ShouldFailover([PSObject]$resource)`: Determines if the resource should be failed over by checking its status and tier.

### Notes

- This class is used in the `AzureSqlBulkFailover.ps1` script to represent a database or elastic pool resource and its associated properties.
- The `DatabaseResource` class is used to facilitate processing and querying of state for a database or elastic pool resource.
- The `GetResourceId()`, `GetName()`, and `GetIsFailoverUpgrade()` methods are used to retrieve information about the resource.
- The `DatabaseResource` class is used in conjunction with the `FailoverStatus` enumeration to determine the status of a resource failover.
- The `DatabaseResource` class is used to facilitate processing and querying of state for a database or elastic pool resource.

## ElasticPoolResource Class

This class represents an elastic pool resource and associated helper methods.

### Properties

- `Server`: The server object that contains the elastic pool.
- `FailoverStatus`: Used to store the FailoverStatus of the elastic pool.
- `FailoverStatusPath`: Used to store the API path to get the FailoverStatus of the elastic pool.
- `Message`: Used to store the last message for an API call to the elastic pool FailoverStatus or failover.
- `Name`: Name of the elastic pool.
- `ResourceId`: The id (path) of the elastic pool.
- `ShouldFailover`: Used to store if the elastic pool will upgrade when failover is invoked (if this is false, elastic pool will be skipped).

### Constructor

- `ElasticPoolResource([Server]$server, [PSObject]$resource)`: Takes a server object and an elastic pool resource object as returned from the API call methods and creates an elastic pool resource object with the required properties to facilitate processing and querying of state.

### Methods

- `GetResourceId([PSObject]$resource)`: Helper to get the resource ID (path) from the elastic pool resource response object.
- `GetName([PSObject]$resource)`: Helper to get the name of the elastic pool from the elastic pool resource response object.

### Notes

- This class is used in the `AzureSqlBulkFailover.ps1` script to represent an elastic pool resource and its associated properties.
- The `ElasticPoolResource` class is used to facilitate processing and querying of state for an elastic pool resource.
- The `GetResourceId()` and `GetName()` methods are used to retrieve information about the elastic pool resource.
- The `ElasticPoolResource` class is used in conjunction with the `FailoverStatus` enumeration to determine the status of an elastic pool failover.
- The `ElasticPoolResource` class is used to facilitate processing and querying of state for an elastic pool resource.

## ResourceList Class

This class represents a list of resources and associated helper methods.

### Properties

- None

### Constructor

- `ResourceList()`: Creates a new instance of the `ResourceList` class.

### Methods

- `ResourceListUrl([Server]$server)`: Helper to get the URL (path) to get the list of resources from the server.
- `IsElasticPool([PSObject]$resource)`: Determines if the resource is an elastic pool.
- `CreateResource([Server]$server, [PSObject]$resource)`: Creates the right kind of resource, depending on whether or not it is an elastic pool.
- `FailoverKey([PSObject]$resource)`: Returns the FailoverKey for the resource.
- `AddResource([PSObject]$resource)`: Adds a resource to the list.
- `CountInStatus([FailoverStatus]$status)`: Counts the number of resources in the list with the specified failover status.
- `HasPending()`: Determines if there are any resources in the list with a failover status of `Pending`.

### Notes

- This class is used in the `AzureSqlBulkFailover.ps1` script to represent a list of resources and associated properties.
- The `ResourceList` class is used to facilitate processing and querying of state for a list of resources.
- The `ResourceListUrl()`, `IsElasticPool()`, `CreateResource()`, and `FailoverKey()` methods are used to retrieve information about the resources and create the right kind of resource object.
- The `AddResource()`, `CountInStatus()`, and `HasPending()` methods are used to manipulate and query the list of resources.
- The `ResourceList` class is used in conjunction with the `DatabaseResource` and `ElasticPoolResource` classes to represent a list of resources and their associated properties.
- The `ResourceList` class is used to facilitate processing and querying of state for a list of resources.

## ServerList Class

This class represents a list of servers and associates helper methods.

### Properties

- None

### Constructor

- `ServerList()`: Creates a new instance of the `ServerList` class.

### Methods

- `ServerListUrl([string]$subscriptionId, [string]$resourceGroupName)`: Helper to get the URL (path) to get the list of servers from the subscription and resource group.
- `AddServers([string]$subscriptionId, [string]$resourceGroupName, [string]$logicalServerName)`: Adds the list of servers in a subscription's resource group to this list. If no logical server name is provided, all logical servers are enumerated. If `$logicalServerName` is provided, the method serves to discover the logical server's resource group.

### Notes

- This class is used in the `AzureSqlBulkFailover.ps1` script to represent a list of servers and associated properties.
- The `ServerList` class is used to facilitate processing and querying of state for a list of servers.
- The `ServerListUrl()` and `AddServers()` methods are used to retrieve information about the servers and add them to the list.
- The `ServerList` class is used in conjunction with the `Server` class to represent a list of servers and their associated properties.
- The `ServerList` class is used to facilitate processing and querying of state for a list of servers.

## BulkFailover Class

This class represents a bulk failover operation for a list of databases and elastic pools.

### Properties

- `SubscriptionId`: The ID of the subscription to failover (global parameter passed to the Failover method).
- `ResourceGroupName`: The name of the resource group to failover (global parameter passed to the Failover method).
- `LogicalServerName`: The name of the logical server to failover (global parameter passed to the Failover method).
- `Servers`: A list of servers to failover.
- `Resources`: The list of resources (databases or pools) to failover.

## Constructor

- `BulkFailover()`: Creates a new instance of the `BulkFailover` class.

## Methods

- `AddServers([string]$subscriptionId, [string]$resourceGroupName, [string]$logicalServerName)`: Adds a list of servers to the `Servers` property, filtering those that belong to the subscription and resource group or that have the specific server name. Returns the number of servers added.
- `AddServerResources($server)`: Adds the list of resources (databases or pools) that are in a particular server to the list of resources to the `Resources` property. Returns the number of resources added for the server.
- `AddServersInSubscription([string]$subscriptionId, [string]$logicalServerName)` Adds all servers in a subscription to the `Servers` property, filtering those that have the specific server name (if provided). Returns the number of servers added.
- `AddResources()`: Adds all resources in all servers in the `Servers` property to the `Resources` property. Returns the number of resources added.
- `Failover()`: Initiates the failover operation for all resources in the `Resources` property.
- `UpdateFailoverStatus()`: Updates the failover status for all resources in the `Resources` property that are in progress.
- `Run([string]$subscriptionId, [string]$resourceGroupName, [string]$logicalServerName)`: Runs the failover operation for all the resources matching the subscriptionId, ResourceGroupName and logicalServerName.

## Notes

- This class is used in the `AzureSqlBulkFailover.ps1` in conjunction with the `ResourceList`, `DatabaseResource`, and `ElasticPoolResource` classes to represent a bulk failover operation for a list of resources. 
- The `BulkFailover` class is used to facilitate processing and querying of state for a bulk failover operation.
- The `AddServers()` and `AddServersInSubscription()` add server objects to the Servers list property and the `AddResources()` then adds all databases or pools in the list of servers to the resources list. The Failover method then fails over all the resources in that list and UpdateFailoverStatus checks their status. The run method of this class is the entry point for the entire process.