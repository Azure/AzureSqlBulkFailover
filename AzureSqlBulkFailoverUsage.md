# AzureSqlBulkFailover - Usage

----

# Prerequisites

* You must have [deployed](./AzureSqlBulkFailoverSetup.md) the AzureSqlBulkFailover runbook into the subscription that contains your databases.
* TODO: Role membership required

----

# Usage

1. Log in to the Azure portal https://portal.azure.com. 
2. Browse to the AzureSqlBulkFailoverRunbook resource. You can do this by entering "_AzureSqlBulkFailover**Runbook**_" in the search bar at the top of the page. Note that you want the Runbook resource, not the Automation Account resource with a similar name "AzureSqlBulkFailover".
3. Click the **Start** button to begin failover. To see interdiate output as the process executes, click the **Refresh** button. 
    > ![Runbook Start Button](./Media/RunbookStart.png)
4. The output will automatically refresh when the operation completes. Look for the message ```<todo>``` at the end of the output. This indicates that all databases were upgraded.


