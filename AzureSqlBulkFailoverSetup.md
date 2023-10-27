# AzureSqlBulkFailover - Setup

1. Click the button below to deploy the runbook. 
    <button onclick="deployTemplate()" style="background-image: url('https://aka.ms/deploytoazurebutton'); background-repeat: no-repeat; background-position: center; background-color: transparent; background-size: contain; width: 200px; height: 41px; border: none; cursor: pointer;"></button>
2. Log in to Azure with an account that has Contributor or Owner permission for the subscription that contains your user databases. 
3. Select a resource group to contain the AzureSqlBulkFailover resources. You may want to create a new resource group that is dedicated to this solution. 
4. Click "Review + Create", then "Create". 
5. The runbook is fully deployed when you see the message "_Your deployment is complete_". 

To execute the runbook, see [AzureSqlBulkFailover - Usage](./AzureSqlBulkFailoverUsage.md). 

<!-- This script defines the deployTemplate() function, which deploys the ARM template for the AzureSqlBulkFailover solution. It is executed when the "deploy to azure button" is pressed-->

<script>
function deployTemplate() {
  const branchName = "main";
  const url = location.href;
  if (url.startsWith("https://github.com/")) {
    branchName = url.substring(url.indexOf("blob/") + 5, url.indexOf("/AzureSqlBulkFailoverSetup.md"));
  }
  const escapedUrl = "https://portal.azure.com/#blade/Microsoft_Azure_CreateUIDef/CustomDeploymentBlade/uri/https%3A%2F%2Fraw.githubusercontent.com%2FAzure%2FAzureSqlBulkFailover%2F" + escape(branchName) + "%2FSource%2FArmTemplate.json";
  const xhr = new XMLHttpRequest();
  xhr.open("PUT", escapedUrl, true);
  xhr.setRequestHeader("Content-Type", "application/json");
  xhr.onreadystatechange = function() {
    if (xhr.readyState === 4 && xhr.status === 200) {
      console.log("Template deployed successfully.");
    }
  };
  xhr.send(JSON.stringify({}));
}
</script>
