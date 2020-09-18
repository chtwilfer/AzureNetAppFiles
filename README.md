# Azure NetAppFiles

Create Azure NetApp Files (ANF) in Azure.
Declare your variables accordingly.
Log in to your public Azure Subscription.
Make sure that your subscription is ready fro ANF (https://docs.microsoft.com/en-us/azure/azure-netapp-files/azure-netapp-files-register).
Install Azure Modules - if nessecary.
Paramter prompt - fill in | more Parameters to check and change.
        		
## Creation Date: 29.05.2020
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
