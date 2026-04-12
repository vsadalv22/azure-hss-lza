targetScope = 'resourceGroup'

// ============================================================
// ExpressRoute Connection — Gateway <--> Manually-created Circuit
//
// Run this ONLY after:
//   1. ER circuit has been created manually (Portal / CLI)
//   2. Service key has been sent to the provider
//   3. Provider has set circuit status to "Provisioned"
//
// Triggered via workflow: 03b-platform-er-connection
// ============================================================

@description('ExpressRoute Gateway resource ID (output from workflow 03)')
param erGatewayId string

@description('ExpressRoute circuit resource ID (from manually-created circuit)')
param erCircuitResourceId string

@description('Connection name')
param connectionName string = 'con-ergw-to-circuit-001'

@description('Azure region')
param location string = 'australiaeast'

@description('Routing weight — leave at 0 for default BGP preference')
param routingWeight int = 0

@description('Log Analytics workspace resource ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('Resource tags')
param tags object = {
  environment: 'connectivity'
  managedBy  : 'platform-team'
  createdBy  : 'alz-bicep'
}

// ============================================================
// ExpressRoute Connection
// ============================================================
resource erConnection 'Microsoft.Network/connections@2023-09-01' = {
  name: connectionName
  location: location
  tags: tags
  properties: {
    connectionType: 'ExpressRoute'
    virtualNetworkGateway1: {
      id        : erGatewayId
      properties: {}
    }
    peer: {
      id: erCircuitResourceId
    }
    routingWeight: routingWeight
  }
}

// ---- Diagnostics on the connection ----
resource erConnectionDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name  : 'diag-${connectionName}'
  scope : erConnection
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
  }
}

// ============================================================
// Outputs
// ============================================================
output erConnectionId   string = erConnection.id
output erConnectionName string = erConnection.name
