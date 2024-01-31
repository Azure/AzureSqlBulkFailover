# AzureSqlBulkFailover - Setup

1. Click the button below to deploy the runbook.
  
    [![Deploy to Azure](https://aka.ms/deploytoazurebutton)](https://azure.github.io/AzureSqlBulkFailover/DeployTemplate.html)

2. Log in to Azure with an account that has Contributor or Owner permission for the subscription that contains your user databases. 
3. Select a resource group to contain the AzureSqlBulkFailover resources. You may want to create a new resource group that is dedicated to this solution. 
4. Enter a name for the automation account that will contain the runbook. Note that this must be a unique name in the subscription, so if you need multple deployments for different users or resource groups you should use some naming scheme that guarantees uniqueness (for example: <resource group>_AzureBulkFailover). If you want to redeploy over an existing deployment you must first delete the existing automation account.
5. Select a branch name to pull the runbook from. This should be the name of the branch that contains the runbook you want to deploy. If you want to deploy the runbook from the main branch (current release), enter "main" or leave as is (this is the default value). To deploy from a custom branch, enter the name of the custom branch. See: [DeveloperDeployment.md](./DeveloperDeployment.md) for more information.
5. Click "Review + Create", then "Create". 
6. The runbook is fully deployed when you see the message "_Your deployment is complete_". 
7. Assign permissions to the automation account that was created during deployment (AzureSqlBulkFailover) so that it can access the databases that it needs to failover. See [AzureSqlBulkFailover - Permissions](./AzureSqlBulkFailoverPermissions.md) for instructions.

To execute the runbook, see [AzureSqlBulkFailover - Usage](./AzureSqlBulkFailoverUsage.md).
