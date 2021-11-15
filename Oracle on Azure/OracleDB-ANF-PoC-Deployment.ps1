<#
	.SYNOPSIS
	Create Azure NetApp Files (ANF) in Azure w ith Oracle Databases

	.DESCRIPTION
	Log in to your public Azure Subscription.
        Make sure that your subscription is ready fro ANF (https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-register)
        Install Azure Modules - if nessecary
        three paramter and Windows Credentials to fill in on start
        more Variabels to check and change
        there is a Bastion Host for the acceess in Azure
        		
	
	.NOTES
	Version:	1.0
	Author: 	Christian Twilfer (christian.twilfer@outlook.de)
	
	Creation Date: 23.09.2020
        Purpose / Changes:

        
	.PARAMETER
        $location                       = First Azure Location
        $resourceGroup                  = the name of the Resource Group
        $anfAccountName                 = the name of the ANF Account
             
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

 [System.Management.Automation.PSCredential] # Windows Credentials
 $Cred = $(Get-Credential)
 
 )
#endregion

#region Change these Parameters for your Deployment 
     #more Variables for ANF Deployment
        $CreationToken = "standard"
        $CreationToken2 = "standard2"
        $poolName = ($anfAccountName + "-pool")
        $VirtualNetworkName = ($anfAccountName+"-vnet")
        $VirtualSubnetName = ($anfAccountName+"-subnet")
        $NetworkAddressPrefix = "10.6.0.0/16"
        $SubnetAddressPrefix = "10.6.2.0/24"
        $volumeName1 = ($anfAccountName+"-volume-db")
        $volumeName2 = ($anfAccountName+"-volume-logs")
        $serviceLevel = "Standard"
        $Protocol = "NFSv3"
 #endregion


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
        
read-host "Press ENTER to continue for Deployment App VM ..."

#Region Create ResourceGroup, VNet 1 with 1 App VM
     #Create a Resource Group
        New-AzResourceGroup -Name $resourceGroup -Location $location

     #Create App VM1 with VNet and Subnet
        # Variables for common values
        $vmName = "App-VM"
        
        Write-Output "Creating the Virtual Machine App 1"
        # Create a subnet configuration
        $subnetConfig = New-AzVirtualNetworkSubnetConfig -Name "App-subnet" -AddressPrefix 10.5.2.0/24

        # Create a virtual network
        $vnet = New-AzVirtualNetwork -ResourceGroupName $resourceGroup -Location $location -Name "App-VNet" -AddressPrefix 10.5.0.0/16 -Subnet $subnetConfig

        # Create a public IP address and specify a DNS name
        $pip = New-AzPublicIpAddress -ResourceGroupName $resourceGroup -Location $location -Name "appvmpublicdns$(Get-Random)" -AllocationMethod Static -IdleTimeoutInMinutes 4

        # Create an inbound network security group rule for port 3389
        $nsgRuleRDP = New-AzNetworkSecurityRuleConfig -Name AppVMNSGRDP  -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow

        # Create a network security group
        $nsg = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroup -Location $location -Name AppVMNSG -SecurityRules $nsgRuleRDP

        # Create a virtual network card and associate with public IP address and NSG
        $nic = New-AzNetworkInterface -Name "AppVM-nic" -ResourceGroupName $resourceGroup -Location $location -SubnetId $vnet.Subnets[0].Id -PublicIpAddressId $pip.Id -NetworkSecurityGroupId $nsg.Id

        # Create a virtual machine configuration
        $vmConfig = New-AzVMConfig -VMName $vmName -VMSize Standard_D2_v3 | `
                Set-AzVMOperatingSystem -Windows -ComputerName $vmName -Credential $cred | `
                Set-AzVMSourceImage -PublisherName MicrosoftWindowsServer -Offer WindowsServer -Skus 2016-Datacenter -Version latest | `
                Add-AzVMNetworkInterface -Id $nic.Id

        # Create a virtual machine
        New-AzVM -ResourceGroupName $resourceGroup -Location $location -VM $vmConfig
        Start-Sleep -Seconds 10
        Write-Output "Virtual Machine App is created"
#endregion     

read-host "Press ENTER to continue for Deployment ANF Resources..."

#Region Create ANF Resources with 2 Voluems for Oracle DB, NSG

        #NetApp Account creation
        # Create an NetApp Account
        Write-Host "Creating new ANF Account $($anfAccountName)." 
        New-AzNetAppFilesAccount -ResourceGroupName $resourceGroup -Location $location -Name $anfAccountName

        #Capacity pool
        #Create a capacity pool
        $poolSizeBytes = 4398046511104 # 4TiB - firmly defined
        Write-Host "Creating new ANF capacity pool $($PoolName) with a size of $($PoolSize) TiB. Service level: $($ServiceLevel)."
        New-AzNetAppFilesPool -ResourceGroupName $resourceGroup -Location $location -AccountName $anfAccountName -Name $poolName -PoolSize $poolSizeBytes -ServiceLevel $serviceLevel

        #Create volume (NFSv3) with VNet & Subnet (include subnet delegation)
        $anfDelegation = New-AzDelegation -Name ([guid]::NewGuid().Guid) -ServiceName "Microsoft.NetApp/volumes"
        Start-Sleep -s 25
        $subnet2 = New-AzVirtualNetworkSubnetConfig -Name $VirtualSubnetName -AddressPrefix $SubnetAddressPrefix -Delegation $anfDelegation
        Start-Sleep -s 25
        $vnet2 = New-AzVirtualNetwork -Name $VirtualNetworkName -ResourceGroupName $resourceGroup -Location $location -AddressPrefix $NetworkAddressPrefix -Subnet $subnet2
        Start-Sleep -s 25
        $subnetId2 = $vnet2.Subnets[0].Id
        Start-Sleep -s 10
        $volumeSizeBytes = 107374182400 # 100GiB - firmly defined
        New-AzNetAppFilesVolume -ResourceGroupName $resourceGroup -Location $location -AccountName $anfAccountName -PoolName $poolName -UsageThreshold $volumeSizeBytes -SubnetId $subnetId2 -CreationToken $CreationToken -ServiceLevel $serviceLevel -Name $volumeName1 -ProtocolType $Protocol
        Start-Sleep -s 10
        New-AzNetAppFilesVolume -ResourceGroupName $resourceGroup -Location $location -AccountName $anfAccountName -PoolName $poolName -UsageThreshold $volumeSizeBytes -SubnetId $subnetId2 -CreationToken $CreationToken2 -ServiceLevel $serviceLevel -Name $volumeName2 -ProtocolType $Protocol 
        Start-Sleep -s 10
        
        
     #Create OracelDB VM with VNet and Subnet
        # Variables for common values
        $vmName = "OracleDB-VM"
        
        Write-Output "Creating the Virtual Machine OracleDB"

        # Create a subnet configuration
        $subnetConfig3 = New-AzVirtualNetworkSubnetConfig -Name "OracleVM-subnet" -AddressPrefix 10.7.2.0/24

        # Create a virtual network
        $vnet3 = New-AzVirtualNetwork -ResourceGroupName $resourceGroup -Location $location -Name "OracelVM-VNet" -AddressPrefix 10.7.0.0/16 -Subnet $subnetConfig3

        # Create a public IP address and specify a DNS name
        $pip3 = New-AzPublicIpAddress -ResourceGroupName $resourceGroup -Location $location -Name "oraclevmpublicdns$(Get-Random)" -AllocationMethod Static -IdleTimeoutInMinutes 4

        # Create an inbound network security group rule for port 3389
        $nsgRuleRDP3 = New-AzNetworkSecurityRuleConfig -Name OracleVMNSGRDP  -Protocol Tcp -Direction Inbound -Priority 1000 -SourceAddressPrefix * -SourcePortRange * -DestinationAddressPrefix * -DestinationPortRange 3389 -Access Allow

        # Create a network security group
        $nsg3 = New-AzNetworkSecurityGroup -ResourceGroupName $resourceGroup -Location $location -Name OracleVMNSG -SecurityRules $nsgRuleRDP3

        # Create a virtual network card and associate with public IP address and NSG
        $nic3 = New-AzNetworkInterface -Name "OracleVM-nic" -ResourceGroupName $resourceGroup -Location $location -SubnetId $vnet3.Subnets[0].Id -PublicIpAddressId $pip3.Id -NetworkSecurityGroupId $nsg3.Id

        # Create a virtual machine configuration
        $vmConfig = New-AzVMConfig -VMName $vmName -VMSize Standard_D2_v3 | `
                Set-AzVMOperatingSystem -Windows -ComputerName $vmName -Credential $cred | `
                Set-AzVMSourceImage -PublisherName oracle -Offer oracle-database-19-3 -Skus oracle-database-19-0904 -Version latest | `
                Add-AzVMNetworkInterface -Id $nic3.Id

        # Create a virtual machine
        New-AzVM -ResourceGroupName $resourceGroup -Location $location -VM $vmConfig
        Start-Sleep -Seconds 10
        Write-Output "Virtual Machine OracleDB is created"
#endregion

read-host "Press ENTER to continue for VNet-Peering..."

#region
     #VNet-Peering VNet1 to VNet 2
        Write-Output "Creating Virtual Network Peering"
        Add-AzVirtualNetworkPeering -Name PeeringAppVMtoOracleVM -VirtualNetwork $vnet -RemoteVirtualNetworkId $vnet3.Id
        Start-Sleep -Seconds 10
        Add-AzVirtualNetworkPeering -Name PeeringOracleVMtoAPPVM -VirtualNetwork $vnet3 -RemoteVirtualNetworkId $vnet.Id
        Start-Sleep -Seconds 10
        Write-Output "Virtual Network Peering is created"

     #VNet-Peering VNet2 to VNet 3
        Write-Output "Creating Virtual Network Peering"
        Add-AzVirtualNetworkPeering -Name PeeringOracleVMtoANFVolume -VirtualNetwork $vnet3 -RemoteVirtualNetworkId $vnet2.Id
        Start-Sleep -Seconds 10
        Add-AzVirtualNetworkPeering -Name PeeringANFVolumetoOracleVM -VirtualNetwork $vnet2 -RemoteVirtualNetworkId $vnet3.Id
        Start-Sleep -Seconds 10
        Write-Output "Virtual Network Peering is created"
#endregion


#End of Deployment
Write-Output "Deployment has finished!!!"



#region - Cleanup ressources
    #Delete ResourceGroup with all ressources in there
#       Remove-AzResourceGroup -Name $ResourceGroup
#endregion
