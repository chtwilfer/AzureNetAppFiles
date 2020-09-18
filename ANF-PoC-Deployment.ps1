<#
	.SYNOPSIS
	Create Azure NetApp Files (ANF) in Azure

	.DESCRIPTION
		Declare your variables accordingly.
		Log in to your public Azure Subscription.
        Make sure that your subscription is ready fro ANF (https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-register)
        Install Azure Modules - if nessecary
        Paramter prompt - fill in
        more Parameters to check and change
        		
	
	.NOTES
	Version:	1.6
	Author: 	Orange Networks GmbH	- Christian Twilfer (c.twilfer@orangenet.de)
	
	Creation Date: 29.05.2020
        Purpose / Changes:

                20.08.2020 - Register Provider Feature ANF SnapshotPolicy for Subscription### - if neccessary
                20.08.2020 - Install-Module -Name Az -AllowClobber -Scope CurrentUser
                20.08.2020 - Update Azure NetApp & Azure Modules - if neccessary
                31.08.2020 - Register Provider Feature ANF TierChange for Subscription### - if neccessary
                31.08.2020 - Check if Provider Feature are registered, if not -> register
                31.08.2020 - region / endregion
                14.09.2020 - Parameter changes
                15.09.2020 - Second Location with Parameters etc. 
                15.09.2020 - Start-Sleep for Oneclick-Deployment
                15.09.2020 - Add Snapshot for Volumes in Region 1
                16.09.2020 - Add Cross-Region Replication
                17.09.2020 - Add Snapshot for Volumes in Region 2                     

		
	.PARAMETER
        $location                       = First Azure Location
        $resourceGroup                  = the name of the Resource Group
        $anfAccountName                 = ANF Account Name
        $anfDelegation                  = Creates an new Delegation
        $poolSizeBytes                  = 4398046511104 -> 4TiB - firmly defined
        $volumeSizeBytes                = 104857600 -> 100GiB - firmly defined
        $volumeName                     = Please note that creation token needs to be unique within subscription and region
        
        $Secondlocation                 = Second Azure Location
        $SecondresourceGroup            = the name of the second Resource Group
        $SecondanfAccountName           = ANF Account Name in the second location
        $SecondanfDelegation            = Creates an new Delegation in the second location
        $SecondpoolSizeBytes            = 4398046511104 -> 4TiB - firmly defined in the second location
        $SecondvolumeSizeBytes          = 104857600 -> 100GiB - firmly defined in the second location
        $SecondvolumeName               = Please note that creation token needs to be unique within subscription and the second region
        
        
        #More Parameters
        $poolName                       = ($anfAccountName + "-pool")
        $VirtualNetworkName             = ($anfAccountName+"-vnet")
        $VirtualSubnetName              = ($anfAccountName+"-subnet")
        $volumeName                     = ($anfAccountName+"-vVolume")
        $serviceLevel                   = "Standard"
        $Protocol                       = "NFSv3"

        $SecondpoolName                 = ($SecondanfAccountName+"-pool")
        $SecondVirtualNetworkName       = ($SecondanfAccountName+"-vnet")
        $SecondVirtualSubnetName        = ($SecondanfAccountName+"-subnet")
        $SecondvolumeName               = ($SecondanfAccountName+"-volume")
        $SecondserviceLevel             = "Standard"
        $SecondProtocol                 = "NFSv3"
             
#>

Set-ExecutionPolicy unrestricted -force

#region put in Parameters
param(

 [Parameter(Mandatory=$True)] # Azure Region e.g. WestEurope, germanywestcentral
 [string] $location,

 [Parameter(Mandatory=$True)] # Resource Group Name
 [string] $resourceGroup,

 [Parameter(Mandatory=$True)] # ANF Account Name
 [string] $anfAccountName,

 [Parameter(Mandatory = $True)] # ANF CreationToke - as a filepath e.g. myfilepath1
 [string] $CreationToken,

 [Parameter(Mandatory = $True)] # ANF Subnet Address Prefix e.g. "10.7.0.0/24"
 [string] $SubnetAddressPrefix,

 [Parameter(Mandatory=$True)] #ANF Virtual Network Address Prefix e.g. "10.7.0.0/16"
 [string] $NetworkAddressPrefix,

 #Input for the Second Location 
 [Parameter(Mandatory=$True)] # Azure Region e.g. WestEurope, germanywestcentral
 [string] $Secondlocation,

 [Parameter(Mandatory=$True)] # Resource Group Name
 [string] $SecondresourceGroup,

 [Parameter(Mandatory=$True)] # ANF Account Name
 [string] $SecondanfAccountName,

 [Parameter(Mandatory = $True)] # ANF CreationToke - as a filepath e.g. myfilepath1
 [string] $SecondCreationToken,

 [Parameter(Mandatory = $True)] # ANF Subnet Address Prefix e.g. "10.7.0.0/24"
 [string] $SecondSubnetAddressPrefix,

 [Parameter(Mandatory=$True)] #ANF Virtual Network Address Prefix e.g. "10.7.0.0/16"
 [string] $SecondNetworkAddressPrefix

 )
#endregion


#more Parameters for Deployment
$poolName = ($anfAccountName + "-pool")
$VirtualNetworkName = ($anfAccountName+"-vnet")
$VirtualSubnetName = ($anfAccountName+"-subnet")
$volumeName = ($anfAccountName+"-vVolume")
$serviceLevel = "Standard"
$Protocol = "NFSv3"

$SecondpoolName = ($SecondanfAccountName+"-pool")
$SecondVirtualNetworkName = ($SecondanfAccountName+"-vnet")
$SecondVirtualSubnetName = ($SecondanfAccountName+"-subnet")
$SecondvolumeName = ($SecondanfAccountName+"-volume")
$SecondserviceLevel = "Standard"
$SecondProtocol = "NFSv3"


read-host "Press ENTER to continue..."

#region - Install Module
     # Install or Update Azure NetApp & Azure Modules - if neccessary
        if ($PSVersionTable.PSEdition -eq 'Desktop' -and (Get-Module -Name AzureRM -ListAvailable)) {
                Write-Warning -Message ('Az module not installed. Having both the AzureRM and ' +
                'Az modules installed at the same time is not supported.')
        } else {
        Install-Module -Name Az -AllowClobber -Force
        }
        Import-Module -Name Az
#endregion

read-host "Press ENTER to continue..."
      
#region - Login to Azure, Subscription and register Provider
        #Login to Azure and selct your subscription where you want to deploy ANF
        Connect-AzAccount

        #Subscription
        #List all Subscriptions in Azure and grab your SubscriptionID
        Write-Host "Connecting to Azure subscription."
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
        
read-host "Press ENTER to continue..."

#Region Create ANF Ressources
    #First Location
        #Create a Resource Group
        New-AzResourceGroup -Name $resourceGroup -Location $location

        #NetApp Account creation
        # reate an NetApp Account
        Write-Host "Creating new ANF Account $($anfAccountName)." 
        New-AzNetAppFilesAccount -ResourceGroupName $resourceGroup -Location $location -Name $anfAccountName

        #Capacity pool
        #Create a capacity pool
        $poolSizeBytes = 4398046511104 # 4TiB - firmly defined
        Write-Host "Creating new ANF capacity pool $($PoolName) with a size of $($PoolSize) TiB. Service level: $($ServiceLevel)."
        New-AzNetAppFilesPool -ResourceGroupName $resourceGroup -Location $location -AccountName $anfAccountName -Name $poolName -PoolSize $poolSizeBytes -ServiceLevel $serviceLevel

        #Volume - line by line
        #Create volume (NFSv3) with VNet & Subnet (include subnet delegation)
        $anfDelegation = New-AzDelegation -Name ([guid]::NewGuid().Guid) -ServiceName "Microsoft.NetApp/volumes"
        Start-Sleep -s 10
        $vnet = New-AzVirtualNetwork -Name $VirtualNetworkName -ResourceGroupName $resourceGroup -Location $location -AddressPrefix $NetworkAddressPrefix -Subnet $subnet
        Start-Sleep -s 10
        $subnet = New-AzVirtualNetworkSubnetConfig -Name $VirtualSubnetName -AddressPrefix $SubnetAddressPrefix -Delegation $anfDelegation
        Start-Sleep -s 10
        $subnetId = $vnet.Subnets[0].Id
        Start-Sleep -s 10
        $volumeSizeBytes = 107374182400 # 100GiB - firmly defined
        New-AzNetAppFilesVolume -ResourceGroupName $resourceGroup -Location $location -AccountName $anfAccountName -PoolName $poolName -UsageThreshold $volumeSizeBytes -SubnetId $subnetId -CreationToken $CreationToken -ServiceLevel $serviceLevel -Name $volumeName -ProtocolType $Protocol 
#endregion

#Region Create ANF Ressources
    #Second Location
        #Create a Resource Group
        New-AzResourceGroup -Name $SecondresourceGroup -Location $Secondlocation

        #NetApp Account creation
        # reate an NetApp Account
        Write-Host "Creating new ANF Account $($SecondanfAccountName)." 
        New-AzNetAppFilesAccount -ResourceGroupName $SecondresourceGroup -Location $Secondlocation -Name $SecondanfAccountName

        #Capacity pool
        #Create a capacity pool
        $SecondpoolSizeBytes = 4398046511104 # 4TiB - firmly defined
        Write-Host "Creating new ANF capacity pool $($SecondPoolName) with a size of $($SecondPoolSizeBytes) Bytes. Service level: $($SecondServiceLevel)."
        New-AzNetAppFilesPool -ResourceGroupName $SecondresourceGroup -Location $Secondlocation -AccountName $SecondanfAccountName -Name $SecondpoolName -PoolSize $SecondpoolSizeBytes -ServiceLevel $SecondserviceLevel

        #Volume - line by line
        #Create volume (NFSv3) with VNet & Subnet (include subnet delegation)
        $SecondanfDelegation = New-AzDelegation -Name ([guid]::NewGuid().Guid) -ServiceName "Microsoft.NetApp/volumes"
        Start-Sleep -s 10
        $Secondvnet = New-AzVirtualNetwork -Name $SecondVirtualNetworkName -ResourceGroupName $SecondresourceGroup -Location $Secondlocation -AddressPrefix $SecondNetworkAddressPrefix -Subnet $Secondsubnet
        Start-Sleep -s 10
        $Secondsubnet = New-AzVirtualNetworkSubnetConfig -Name $SecondVirtualSubnetName -AddressPrefix $SecondSubnetAddressPrefix -Delegation $SecondanfDelegation
        Start-Sleep -s 10
        $SecondsubnetId = $Secondvnet.Subnets[0].Id
        Start-Sleep -s 10
        $SecondvolumeSizeBytes = 107374182400 # 100GiB - firmly defined
        New-AzNetAppFilesVolume -ResourceGroupName $SecondresourceGroup -Location $Secondlocation -AccountName $SecondanfAccountName -PoolName $SecondpoolName -UsageThreshold $SecondvolumeSizeBytes -SubnetId $SecondsubnetId -CreationToken $SecondCreationToken -ServiceLevel $SecondserviceLevel -Name $SecondvolumeName -ProtocolType $SecondProtocol
        Start-Sleep -s 240
#endregion

#region Snapshot
        #Get FilSystemID from Volume
        $FileSystemID = Get-AzNetAppFilesVolume -ResourceGroupName $ResourceGroup -AccountName $anfAccountName -PoolName $poolName -VolumeName $volumeName
        
        # Create a new snapshot from specified volume Region 1
        New-AzNetAppFilesSnapshot -ResourceGroupName $ResourceGroup -l $location -AccountName $anfAccountName -PoolName $poolname -VolumeName $volumename -SnapshotName "MyAnfSnapshot" -FileSystemId $FileSystemID.FileSystemID

        #Get FilSystemID from Volume second location
        $FileSystemID = Get-AzNetAppFilesVolume -ResourceGroupName $secondResourceGroup -AccountName $secondanfAccountName -PoolName $secondpoolName -VolumeName $secondvolumeName

        #Create a new snapshot from specified volume Region 2
        New-AzNetAppFilesSnapshot -ResourceGroupName $secondResourceGroup -l $secondlocation -AccountName $secondanfAccountName -PoolName $secondpoolname -VolumeName $secondvolumename -SnapshotName "MyAnfSnapshot" -FileSystemId $FileSystemID.FileSystemID
#endregion

#region cross-region replication from region 1 to region 2
        #Create / Approve cross-region replication from a volume
#        $Volume = Get-AzNetAppFilesVolume -ResourceGroupName $ResourceGroup -AccountName $anfAccountName -PoolName $poolName -VolumeName $volumeName
        
        #Approve cross-region replication from vloume 1 in region 1 to region 2
#        Approve-AzNetAppFilesReplication -ResourceGroupName $Resourcegroup -AccountName $anfAccountName -PoolName $poolName -VolumeName $volumeName -DataProtectionVolumeId $Volume.ID
#endregion

#region - Cleanup ressources
        #Delete ResourceGroup with all ressources in there
#        Remove-AzResourceGroup -Name $ResourceGroup
#        Remove-AzResourceGroup -Name $SecondResourceGroup
#endregion
