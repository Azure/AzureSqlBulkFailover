# Developer Deployment Guide
As we add new features or fix bugs, we will need to deploy the changes to the RunbookEntrypointManifest and any files referenced by that manifest. The issue is that the RunbookEntrypoint script needs to retrieve this manifest and referenced files from the corresponding developer branch. In order to do this, we have added a branch variable to the RunbookEntrypoint script. This variable is set to the name of the branch that contains the manifest and referenced files. The RunbookEntrypoint script will retrieve the manifest and referenced files from this branch. This said, it is not the greatest user experience to click on the deploy buttion from the AzureSqlBulkFailoverSetup.md file (from within a branch) and then have to manually enter the name of the branch when running the script. To solve this we have created a DeployTemplate.html file that gets the URL of the calling page and then parses the branch name from the URL. This branch name is then passed to the Arm template deployment URL so that it can then set as a variable in the automation account (branch_name) and used by default in the bootstrapper (RunbookEntrypoint.ps1) script.
When running the runbook, the branch name will default to the value in this variable. If you want to deploy from a different branch, you can override the value of the branch_name variable or set it on the fly when running the runbook. This is simply to facilitate the testing of the AzureBulkFailover and potentially other scripts in the manifest, before merging the code to the main branch.