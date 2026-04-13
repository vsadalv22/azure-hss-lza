using '../main.bicep'

// ============================================================
// Identity Platform Parameters
// Deploys: AD Domain Controller VNet, peering to hub
// ============================================================

param location = 'australiaeast'

// Set via pipeline variable: LOG_ANALYTICS_WORKSPACE_ID
param logAnalyticsWorkspaceId = ''

// Set via pipeline output from 03-connectivity: HUB_VNET_ID
param hubVnetId = ''

// Set via pipeline output from 03-connectivity: ROUTE_TABLE_ID
param hubRouteTableId = ''

param tags = {
  environment : 'identity'
  managedBy   : 'platform-team'
  createdBy   : 'alz-bicep'
  costCenter  : 'platform'
}
