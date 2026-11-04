# Oracle infrastructure on Azure with ANF volumes

This example creates **infrastructure only**:

- A Windows Server 2022 application VM (`App-VM`).
- A Linux Oracle Marketplace VM (`OracleDB-VM`) using SSH-key authentication.
- An ANF account, 4 TiB capacity pool and two 100 GiB NFSv3 volumes for database
  data and logs.
- Three VNets, with bidirectional application-to-Oracle and Oracle-to-ANF peerings.

It does **not** initialize an Oracle database, mount ANF volumes, install Oracle
Direct NFS, create Bastion/VPN/NAT, configure database listener rules or validate
database performance/licensing. VNet peering is not transitive: the application
VNet is not directly connected to the ANF VNet.

## Prerequisites

Use the [repository requirements](../README.md#requirements), including
`Az.Compute` and `Az.MarketplaceOrdering`. Supply a Windows administrator
credential and an OpenSSH **public key value**, not a private key or a filename.

The original Oracle 19c offer/SKU is retained by default:
`oracle:oracle-database-19-3:oracle-database-19-0904:latest`.
The script checks regional image availability and Linux OS type before creating
resources. Image availability is not guaranteed. Override
`-OracleImagePublisher`, `-OracleImageOffer`, `-OracleImageSku` and
`-OracleImageVersion` with an explicitly chosen supported Linux image if needed.
Use a concrete image version for reproducible deployments.

If the image carries a purchase plan, Marketplace terms must already have been
accepted in the subscription. The script checks acceptance and applies the plan
to the VM, but never accepts terms on your behalf. VM security type is explicitly
`Standard` to retain compatibility with the original generation-1 Oracle image.

Both VMs have **private NICs only**. Default NSG rules permit virtual-network
traffic, including peered networks; no Internet-wide SSH/RDP rule is added.
Provide private administrative connectivity and any required outbound access
separately. You cannot connect directly from the Internet after deployment.

## Example from the repository root

```powershell
$deployment = @{
    SubscriptionId = '<subscription-guid>'
    Location = 'westeurope'
    ResourceGroup = 'oracle-anf-poc'
    AnfAccountName = 'oracleanfpoc'
    Cred = Get-Credential -Message 'Windows application VM administrator'
    SshPublicKey = (Get-Content ~/.ssh/id_ed25519.pub -Raw).Trim()
}

& './Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1' @deployment -WhatIf
& './Oracle on Azure/OracleDB-ANF-PoC-Deployment.ps1' @deployment
```

Defaults are `10.5.0.0/16`/`10.5.2.0/24` for the application,
`10.6.0.0/16`/`10.6.2.0/24` for ANF, and `10.7.0.0/16`/`10.7.2.0/24`
for Oracle. The VNets must not overlap. Parameterize all ranges for your
environment. Only the Oracle subnet is allowed by the NFS export rules.

Other options include `-OracleAdminUsername`, `-VmSize`, `-AppImageSku`,
`-PoolSizeTiB`, `-VolumeSizeGiB`, `-ServiceLevel`, `-AllowRootAccess`,
`-RegisterProviders` and `-TimeoutSeconds`. Root access is disabled by default;
plan filesystem ownership and permissions before using the volumes.

## Existing resources and partial failures

The historical VNet name **`OracelVM-VNet`**, including its spelling, is
preserved to avoid creating a parallel network in an existing environment.

Existing matching ANF/VNet resources are reused. Existing VMs, NICs or NSGs with
the expected names cause a failure before those resources are modified. This
avoids silently retaining public access or overwriting VMs from an older run.
Following a partial failure, inspect all resources and explicitly remove or
migrate the conflicting VM/NIC/NSG resources before retrying. Do not delete ANF
volumes containing data to bypass a configuration check.

There is no rollback. ANF capacity, VM disks and other remaining resources may
continue to incur charges after an error.
