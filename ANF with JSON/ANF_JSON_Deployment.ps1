<#
	.SYNOPSIS
	Create Azure NetApp Files (ANF) in Azure with JSON

	.DESCRIPTION
		Declare your variables accordingly.
		Log in to your public Azure Subscription.
        Make sure that your subscription is ready fro ANF (https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-register)
        Install Azure Modules - if nessecary
        		
	
	.NOTES
	Version:	1.0
	Author: 	Christian Twilfer (christian.twilfer@outlook.de)
	
	Creation Date: 22.09.2020
        Purpose / Changes:
               
		
	.PARAMETER
        $location                       = First Azure Location
        $resourceGroup                  = the name of the Resource Group

             
#>

Set-ExecutionPolicy unrestricted -force
Start-Sleep -Seconds 5

#region put in Parameters
param(
 [Parameter(Mandatory=$True)] # Azure Region e.g. WestEurope, germanywestcentral
 [string] $location,

 [Parameter(Mandatory=$True)] # Resource Group Name
 [string] $resourcegroup
 )
 #endregion

read-host "Press ENTER to continue..."

#region - Install Module
        #Install and Import Azure NetApp & Azure Modules - if neccessary - this will take some time
        Install-Module -Name Az -AllowClobber -Scope CurrentUser
        # Install-Module -Name Az.NetAppFiles
        # Install-Module -Name Az.Resources
        # Install-Module -Name Az.Network

        # Update Azure NetApp & Azure Modules - if neccessary
        if ($PSVersionTable.PSEdition -eq 'Desktop' -and (Get-Module -Name AzureRM -ListAvailable)) {
                Write-Warning -Message ('Az module not installed. Having both the AzureRM and ' +
                'Az modules installed at the same time is not supported.')
        } else {
        Install-Module -Name Az -AllowClobber -Force
        }
#endregion

read-host "Press ENTER to continue..."
      
#region - Login to Azure, Subscription and register Provider
        #Login to Azure and selct your subscription where you want to deploy ANF
        Connect-AzAccount

        #Subscription
        #List all Subscriptions in Azure and grab your SubscriptionID
        Get-AzSubscription | Where-Object -Property State -eq "Enabled" | Out-Gridview -PassThru | Select-AzSubscription
    
        if ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFSnapshotPolicy).RegistrationState -ne "Registered") {
            Register-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFSnapshotPolicy
        }
        if ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFTierChange).RegistrationState -ne "Registered") {
            Register-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFTierChange
        }

        # Wait for registration to complete
        while ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFSnapshotPolicy).RegistrationState -ne "Registered") {
            Start-Sleep -Seconds 10
        }
        
        while ((Get-AzProviderFeature -ProviderNamespace Microsoft.NetApp -FeatureName ANFTierChange).RegistrationState -ne "Registered") {
            Start-Sleep -Seconds 10
    }
#endregion

New-AzResourceGroup -Name $resourcegroup -Location $location
Start-Sleep -Seconds 10
New-AzResourceGroupDeployment -TemplateParameterFile C:\temp\azuredeploy.parameters.json -Templatefile C:\temp\azuredeploy.json -Name "NetApp-Deployment" -ResourceGroupName $resourcegroup -Mode Incremental
