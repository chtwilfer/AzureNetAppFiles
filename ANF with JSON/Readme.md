# Azure NetApp Files Deployment with JSON Template

This template deploys ANF in your defined region, with one ANF account, one pool and one volume. The volume protocol ist NFS.

## First step:
Start by editing azure.parameters.json and define your parameters.

## Next step:
Open Powershell an start the ps1 Script -> .\ANF_JSON_Deployment.ps1 -resourcegroup "YOURRESOURCEGROUPNAME" -location "YOURLOCATION"

## Or:
Open Powershell ISE and the ps1 and start it from there
