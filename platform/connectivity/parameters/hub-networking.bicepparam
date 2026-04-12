using '../main.bicep'

// ============================================================
// Hub Networking Parameters — Australia East
// ExpressRoute: Standard / UnlimitedData / 1 Gbps
// Checkpoint  : CloudGuard (sg-byol)
// No Bastion  : Access management VMs via ExpressRoute from on-prem
// ============================================================

param location = 'australiaeast'

param hubVnetAddressPrefix = '10.0.0.0/16'

// Injected from GitHub Actions secret LOG_ANALYTICS_WORKSPACE_ID
param logAnalyticsWorkspaceId = ''

param checkpointAdminUsername = 'azureadmin'
// Injected from GitHub Actions secret CHECKPOINT_ADMIN_PASSWORD
param checkpointAdminPassword = ''

param checkpointVmSize = 'Standard_D3_v2'

// sg-byol  = Bring Your Own Licence (requires Checkpoint licence)
// sg-ngtp  = PAYG — Next Gen Threat Prevention
// sg-ngtx  = PAYG — Next Gen Threat Extraction
param checkpointSku = 'sg-byol'

// ---- ExpressRoute Circuit ----
param erCircuitName       = 'erc-hub-australiaeast-001'
param erServiceProviderName = '<YOUR_ER_PROVIDER>'   // e.g. 'Equinix' or 'Megaport'
param erPeeringLocation   = 'Sydney'                 // ER peering location (not Azure region)
param erBandwidthInMbps   = 1000                     // 1 Gbps
param erSkuTier           = 'Standard'
param erSkuFamily         = 'UnlimitedData'
param erGatewaySku        = 'ErGw1AZ'               // Zone-redundant; upgrade to ErGw2AZ for 10G

param tags = {
  environment : 'connectivity'
  region      : 'australiaeast'
  managedBy   : 'platform-team'
  createdBy   : 'alz-bicep'
  costCenter  : 'platform'
}
