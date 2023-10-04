GitHub Copilot: Sure, here's an example of an MD document for the `RunbookEntrypoint.ps1` script:

# RunbookEntrypoint.ps1

This PowerShell script is designed to download and execute a series of scripts from a remote location, passing in the required parameters for each script.

## Usage

To use this script, you will need to provide the following parameters:

- `$SubscriptionId`: The ID of the Azure subscription to use.
- `$ResourceGroupName`: The name of the resource group to use.
- `$ServerName`: The name of the logical server to use.

Here's an example of how to run the script:

```powershell
.\RunbookEntrypoint.ps1 -SubscriptionId "12345678-1234-1234-1234-123456789012" -ResourceGroupName "MyResourceGroup" -ServerName "MyLogicalServer"
```

## Functionality

The script performs the following steps:

1. Downloads a manifest file (`RunbookEntrypointManifest.json`) from a remote location.
2. Parses the manifest file to get a list of files to download and execute.
3. Downloads each file to a local directory.
4. Executes each file in turn, passing in the required parameters (SubscriptionId, ResourceGroupName and ServerName).

## Functions

The script includes the following functions:

### `Get-AllFiles`

This function gets all files listed in the manifest file and adds the local file path to the file object.

### `Get-File`

This function gets a single file from a remote location.

## Variables

The script uses the following variables:

- `$remoteRootUri`: The root URI of the remote location to download files from.
- `$localRootPath`: The local directory to download files to.
- `$allFiles`: An array of file objects, each representing a file to download and execute.
- `$scriptsToExecute`: An array of file objects, each representing a script to execute.
- `$scriptNum`: A counter for the number of scripts executed.

## Loop

The script uses a `foreach` loop to iterate over the `$scriptsToExecute` array and execute each script in turn. For each script, the loop outputs a message indicating which script is being executed, and then uses the call operator (`&`) to invoke the script. The script is invoked with several named parameters (`-SubscriptionId`, `-ResourceGroupName`, `-ServerName`) that are passed to the script as arguments.

## Notes

- This script requires PowerShell version 3.0 or later.
- This script assumes that the manifest file is named `RunbookEntrypointManifest.json` and is located in the `Source` directory of the remote location.
- This script assumes that each script listed in the manifest file has a corresponding `.ps1` file extension.