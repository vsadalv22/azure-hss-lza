using '../main.bicep'

// ⚠ CIDR Configuration — set these two address prefixes and ALL subnets/IPs are auto-derived:
//   hubVnetAddressPrefix    : Hub VNet (ER gateway + Checkpoint internal NIC)
//   ingressVnetAddressPrefix: Ingress VNet (internet-facing Checkpoint external NIC)
//   onPremAddressSpace      : On-premises CIDR (used in NSG allow rules for management access)
//
// Do NOT hardcode individual subnet CIDRs — they are calculated automatically in main.bicep.

// ============================================================
// Hub Networking Parameters — Australia East
//
// What this deploys (IaC):
//   • Hub VNet (hubVnetAddressPrefix) with subnets derived via cidrSubnet()
//   • Ingress VNet (ingressVnetAddressPrefix) with subnets derived via cidrSubnet()
//   • ExpressRoute Gateway — ErGw1AZ (zone-redundant)
//   • Checkpoint CloudGuard R81.10 NVA (dual NIC, IPs derived via cidrHost())
//   • NSGs, Route Table (UDR → Checkpoint)
//
// What is NOT deployed by code:
//   • ExpressRoute circuit — created manually (see docs/expressroute-setup.md)
//   • ER connection        — created via workflow 03b after provider provisioning
// ============================================================

param location = 'australiaeast'

param hubVnetAddressPrefix = '10.0.0.0/16'

param onPremAddressSpace = '10.0.0.0/8'

// Set via GitHub Actions secret: LOG_ANALYTICS_WORKSPACE_ID
param logAnalyticsWorkspaceId = ''

param checkpointAdminUsername = 'azureadmin'
// Set via GitHub Actions secret: CHECKPOINT_ADMIN_PASSWORD
param checkpointAdminPassword = ''

param checkpointVmSize = 'Standard_D3_v2'

// sg-byol  = Bring Your Own Licence
// sg-ngtp  = PAYG Next Gen Threat Prevention
// sg-ngtx  = PAYG Next Gen Threat Extraction
param checkpointSku = 'sg-byol'

// ErGw1AZ  = Zone-redundant, up to 1 Gbps  (default)
// ErGw2AZ  = Zone-redundant, up to 2 Gbps
// ErGw3AZ  = Zone-redundant, up to 10 Gbps
param erGatewaySku = 'ErGw1AZ'

param tags = {
  environment: 'connectivity'
  region     : 'australiaeast'
  managedBy  : 'platform-team'
  createdBy  : 'alz-bicep'
  costCenter : 'platform'
}

// Set to false only during initial development/testing — always true in production
param enableResourceLocks = true

param deployPrivateDnsZones = true
