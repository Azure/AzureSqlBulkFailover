# CMW Self-Service Maintenance - Overview

For general information about this project and contributing, see [README.md](./README.md).

# Overview

This document describes the Self-Service Maintenance process for Azure SQL Database and Azure SQL Managed Instance. 

**Step 1**. [You receive a Pending Self-Service Maintenance notification](#step-1-you-receive-a-pending-self-service-maintenance-notification).

**Step 2**. [You initiate failover to upgrade databases](#step-2-you-initiate-failover-to-upgrade-databases).

**Step 3**. [The system initiates failover for any remaining databases](#step-3-the-system-initiates-failover-for-remaining-databases).

----

# Prerequisites

* This process is invitation-only and requires subscription-level enrollment by Microsoft engineers. 
* You must [configure a service health alert](https://learn.microsoft.com/en-us/azure/azure-sql/database/advance-notifications?view=azuresql#configure-an-advance-notification) to receive push notifications in advance of planned maintenance. 

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
* The deadline (2023-7-3 in this example) should allow at least 10 days to prepare. At any time prior to this deadline, you can initiate failover and complete the upgrade for a database, as described below. 

----

# Step 2: You initiate failover to upgrade databases

:exclamation: **Important:** The process described below is appropriate if you wish to trigger failover for a small number of databases.
For simplified failover of dozens or hundreds of SQL DB resources, you can [deploy AzureSqlBulkFailover](./AzureSqlBulkFailoverSetup.md) into a subscription and grant the automation account access to the resource group that contains your databases and then use use AzureSqlBulkFailover to trigger the failover at the desired time. Currently this solution doesn't support Azure SQL MI resources.
1. Go to http://portal.azure.com. 
    * For Azure SQL Database elastic pools and databases, the account must belong to the _Subscription Owner_ or _SQL DB Contributor roles_. 
    * For Azure SQL Managed Instances, the account must belong to the _Subscription Owner_ or _Managed Instance Contributor_ roles. 
1. In the toolbar to the upper right, click the Cloud Shell icon ![CloudShellIcon.png](/Media/CloudShellIcon.png). 
   * Cloud Shell requires a storage account. If you have never used Cloud Shell before, on the first use you will be prompted to create or select a storage account. For more information, see [Persist files in Azure Cloud Shell](https://learn.microsoft.com/en-us/azure/cloud-shell/persisting-shell-storage).
1. Set the shell's context to the subscription that contains the databases:
    ```
    Set-AzContext -Subscription <subscription_guid>
    ```
1. Run a failover command to upgrade each managed instance, database or elastic pool: 
    * Run this command to upgrade a database that is NOT part of an elastic pool or a managed instance: 
      ```
      Invoke-AzSqlDatabaseFailover -ResourceGroupName <resource group name> -ServerName <SQL server name> -DatabaseName <database name>
      ```
    * Run this command to upgrade the databases in an elastic pool: 
      ```
      Invoke-AzSqlElasticPoolFailover -ResourceGroupName <resource group name> -ServerName <SQL server name> -ElasticPoolName <elastic pool>
      ```
    * Or, run this command to upgrade a managed instance: 
      ```
      Invoke-AzSqlInstanceFailover -ResourceGroupName <resource group name> -Name <managed instance name>
      ```

The upgrade will require from a few seconds to a minute or two per database or pool. When the command completes, the upgrade of that database or pool of databases is complete. 
There is no output if the operation is successful. You will receive an error if the operation fails. 

----

# Step 3: The system initiates failover for remaining databases

At some point after the deadline time mentioned in the Pending maintenance notification, the system will force failover for any remaining databases. In the current version of the system, this failover may not occur at the precise deadline time; system-initiated failover will not occur _before_ the deadline, but it may occur several hours or even several days after the deadline time. For this reason, we encourage you to invoke the failover command for all critical databases at an appropriate time. 

After all databases are upgraded, you will receive another maintenance notification with status "Complete" for the same maintenance event ID. Please note that a maintenance event typically covers many databases. And, in the current system, the "Complete" notification may be sent several hours or even days after the last database failover has occurred. _The upgrade for any particular database is complete as soon as the failover command has completed._ 

----

# Frequently Asked Questions

## How can I upgrade many databases at once? 

These instructions allow failover of from one to a few databases. We have implemented the AzureSqlBulkFailover runbook as a simplified way to trigger failover of many databases at the same time. Instruction for [deployment](AzureSqlBulkFailoverSetup.md) and [usage](AzureSqlBulkFailoverUsage.md) are provided here. 

## What is the maximum time that should be required for upgrade of any single database and server with hundreds of databases? 

Currently, using this failover technique, a single database will be failedover in seconds and a server with a large number of databases will be completely failed over within 15 to 30 minutes, although most servers will require less than 5 minutes. We will be monitoring the system to collect data about performance under a variety of conditions, and we will look for opportunities to provide the most consistent experience.

## How can I have the system initiate scheduled failover for me, at a precise time? 

Azure SQL Self-Service Maintenance does not yet provide precise system-initiated upgrade. The customer must initiate the upgrade. We are planning to add scheduled failover features in the future. However, if you are using Self-Service Maintenance and you are notified of a maintenance event, we will failover the database soon after the deadline and in the future at the deadline.
Another way that a scheduled maintenance can be implemented for customers that have Self-Service Maintenance is by automating the runbook execution at a specific time during the maintenance window. For more information, see [Automate Runbook Execution](https://learn.microsoft.com/en-us/azure/automation/shared-resources/schedules)

## What is the relationship of this to [Azure SQL Maintenance Window](https://learn.microsoft.com/en-us/azure/azure-sql/database/maintenance-window?view=azuresql-mi) features? 

The widely-available Azure SQL Maintenance Window features allow customers to limit planned maintenance to either weekday (Monday - Thursday) or weekend (Friday - Sunday) evenings, 10pm to 6am. This document relates to a new, pre-release capability that provides more precise maintenance windows, and increases customer control by allowing customers to directly initiate the upgrade of particular databases.
