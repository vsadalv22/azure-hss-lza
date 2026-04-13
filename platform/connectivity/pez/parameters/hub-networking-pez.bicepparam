using '../main.bicep'

// ⚠ CIDR Configuration — set these two address prefixes and ALL subnets/IPs are auto-derived:
//   hubVnetAddressPrefix    : Hub VNet (ER gateway + Checkpoint internal NIC)
//   ingressVnetAddressPrefix: Ingress VNet (internet-facing Checkpoint external NIC)
//   onPremAddressSpace      : On-premises CIDR (used in NSG allow rules for management access)
//
// Do NOT hardcode individual subnet CIDRs — they are calculated automatically in main.bicep.

// ============================================================
// Perth Extended Zone (PEZ) — Hub Networking Parameters
// DD17: Secondary location alongside Australia East
// DD22: Single fault domain — ErGw1 (no AZ suffix)
// ============================================================

param location = 'australiaeast'

param edgeZone = 'perth'

param hubVnetAddressPrefix = '10.2.0.0/16'

param ingressVnetAddressPrefix = '10.3.0.0/16'

// Set via pipeline variable: LOG_ANALYTICS_WORKSPACE_ID
param logAnalyticsWorkspaceId = ''

param checkpointAdminUsername = 'azureadmin'
// Set via pipeline secret: CHECKPOINT_ADMIN_PASSWORD
param checkpointAdminPassword = ''

param checkpointSku = 'sg-byol'

// ErGw1 — Standard SKU, no zone redundancy (DD22: PEZ single fault domain)
param erGatewaySku = 'ErGw1'

// Set to output ddosProtectionPlanId from 03-connectivity pipeline run
param ddosProtectionPlanId = ''

param onPremAddressSpace = '10.0.0.0/8'

// DD17: PEZ reduced footprint — set to 2 for HA
param checkpointInstanceCount = 2

param tags = {
  environment : 'connectivity'
  region      : 'pez-perth'
  managedBy   : 'platform-team'
  createdBy   : 'alz-bicep'
  costCenter  : 'platform'
}

param enableResourceLocks = true
