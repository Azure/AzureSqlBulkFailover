# CMW Self-Service Maintenance - Overview

----

# Overview

This document describes the Self-Service Maintenance process for Azure SQL Database and Azure SQL Managed Instance. 

**Step 1**. [You receive a Pending Self-Service Maintenance notification](#step-1%3A-you-receive-a-pending-self-service-maintenance-notification).

**Step 2**. [You initiate failover to upgrade databases](#step-2%3A-you-initiate-failover-to-upgrade-databases).

**Step 3**. [The system initiates failover for remaining databases](#step-3%3A-the-system-initiates-failover-for-remaining-databases).

----

# Prerequisites

* This process is invitation-only and requires subscription-level enrollment by Microsoft engineers. 
* You must [configure a service health alert](https://learn.microsoft.com/en-us/azure/azure-sql/database/advance-notifications?view=azuresql#configure-an-advance-notification) to receive push notifications in advance of planned maintenance. 
* For rapid failover of many databases at once, you must [deploy AzureSqlBulkFailover](./DEPLOY.md) into the subscription that contains your databases. 

----

# Step 1: You receive a Pending Self-Service Maintenance notification

You receive a maintenance notification for an upcoming maintenance period. The content will look like: 

> **_Planned Maintenance Notification for Azure SQL Database_**<br/>
> <br/>
> The activity log alert **SelfServiceMaintenanceExampleAlert** was triggered for the Azure subscription **SelfServiceMaintenanceExampleSub**.<br/>
> Tracking ID: **VL9X-TP8**, Type: **Maintenance**<br/>
> Status: **Planned**<br/>
> <br/>
> Communication:<br/> _This notification is for new pending maintenance to your **Azure SQL DB** instance(s) in **Korea Central** and **JapanEast**. Planned maintenance is ready in all named regions. You may initiate upgrade of your databases at any time. During maintenance, your Azure SQL DB instance(s) may experience a brief drop in connectivity for a short number of seconds. If you do not trigger an upgrade for a database, maintenance will occur automatically at **2:37 UTC on 3 Jul 2023**, or at a later date and time. Please refer to the upgrade documentation (https://aka.ms/azsqlcmwselfservicemaint) for more information. For any additional questions, please contact support._

Note: 
* The text "_You may initiate upgrade of your databases at any time_" distinguishes _Self-Service Maintenance_ notifications from other maintenance events.  The notification will also identify the subscription.
* The deadline (2023-7-3 in this example) should allow at least 7 days to prepare. At any time prior to this deadline, you can initiate failover and complete the upgrade for a database, as described below. 

----

# Step 2: You initiate failover to upgrade databases

:exclamation: NOTE: :exclamation: The process described below is appropriate if you wish to trigger failover for a small number of databases.
For simplified failover of dozens or hundreds of databases, use [AzureSqlBulkFailover](AzureSqlBulkFailoverUsage.md) to trigger the failover 
at the desired time. Then return to this page and continue with **Step 3**. 

1. Go to http://portal.azure.com. 
    * For Azure SQL Database elastic pools and databases, the account must belong to the _Subscription Owner_ or _SQL DB Contributor roles_. 
    * For Azure SQL Managed Instances, the account must belong to the _Subscription Owner_ or _Managed Instance Contributor_ roles. 
1. In the toolbar to the upper right, click the Cloud Shell icon ![image.png](/.attachments/image-03fa2890-9f01-474b-a60a-024dbc678610.png). 
    * Cloud Shell requires a storage account. If you have never used Cloud Shell before, on the first use you will be prompted to create or select a storage account. For more information, see [Persist files in Azure Cloud Shell](https://learn.microsoft.com/en-us/azure/cloud-shell/persisting-shell-storage).
1. Run this command to upgrade a database that is NOT part of an elastic pool or a managed instance: 
    ```
    Invoke-AzSqlDatabaseFailover -ResourceGroupName <resource group name> -ServerName <SQL server name> -DatabaseName <database name>
    ```
    Run this command to upgrade the databases in an elastic pool: 
    ```
    Invoke-AzSqlElasticPoolFailover -ResourceGroupName <resource group name> -ServerName <SQL server name> -ElasticPoolName <elastic pool>
    ```
    Or, run this command to upgrade a managed instance: 
    ```
    Invoke-AzSqlInstanceFailover -ResourceGroupName <resource group name> -Name <managed instance name>
    ```

The upgrade will require from a few seconds to a minute or two per database or pool. When the command completes, the upgrade of that database or pool of databases is complete. 

----

# Step 3: The system initiates failover for remaining databases

At some point after the deadline time mentioned in the Pending maintenance notification, the system will force failover for any remaining databases. In the current version of the system, this failover may not occur at the precise deadline time; system-initiated failover will not occur _before_ the deadline, but it may occur several hours or even several days after the deadline time. For this reason, we encourage you to invoke the failover command for all critical databases at an appropriate time. 

After all databases are upgraded, you will receive another maintenance notification with status "Complete" for the same maintenance event ID. Please note that a maintenance event typically covers many databases. And, in the current system, the "Complete" notification may be sent several hours or even days after the last database failover has occurred. _The upgrade for any particular database is complete as soon as the failover command has completed._ 

----

# Frequently Asked Questions

## How can I upgrade many databases at once? 

These instructions allow failover of from one to a few databases. We are working on a simplified way to trigger failover of many databases at the same time, and we will update this documentation when this is ready for customer use. 

## What is the maximum time that should be required for upgrade of any single database? 

The upgrade of most databases will require from one to three minutes. We are striving for an SLA of < 30 minutes. We will be monitoring the system to collect data about performance under a variety of conditions, and we will look for opportunities to provide the most consistent experience. 

## How can I have the system initiate scheduled failover for me, at a precise time? 

Azure SQL Self-Service Maintenance does not yet provide precise system-initiated upgrade. The customer must initiate the upgrade. We are planning to add scheduled failover features in the future. 

## What is the relationship of this to [Azure SQL Maintenance Window](https://learn.microsoft.com/en-us/azure/azure-sql/database/maintenance-window?view=azuresql-mi) features? 

The widely-available Azure SQL Maintenance Window features allow customers to limit planned maintenance to either weekday (Monday - Thursday) or weekend (Friday - Sunday) evenings, 10pm to 6am. This document relates to a new, pre-release capability that provides more precise maintenance windows, and increases customer control by allowing customers to directly initiate the upgrade of particular databases. 

## Why did I receive the error "At least 15 minutes must pass between failovers"?
You may receive one of these errors: 

> <span style="color:red"> _There was a recent failover on the database or pool if database belongs in an elastic pool.  At least 15 minutes must pass between failovers._</span>

  or

> <span style="color:red"> _There was a recent failover on the managed instance. At least 15 minutes must pass between instance failovers._ </span>

To provide a consistent experience for all customers, the system returns this error if there are repeated identical requests for the same action on the same resource. The error means that the system did receive your earlier request. There is no benefit from re-running the same command. 


----
----

**TO DO**:
* Cross-Ring and Cross-Region Maintenance Coordination
* FAQ: 
   * Support/escalation process if there are any surprises
* Move this to customer-visible repository and update aka short link. 