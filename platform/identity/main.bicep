targetScope = 'subscription'

// ============================================================
// Azure Landing Zone - Identity Subscription
// Region: Australia East | AD DS Domain Controllers
// ============================================================

@description('Azure region')
param location string = 'australiaeast'

@description('Hub VNet resource ID for peering')
param hubVnetId string

@description('Route table resource ID from hub connectivity — forces DC traffic through Checkpoint NVA')
param hubRouteTableId string

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Resource tags')
param tags object = {
  environment: 'identity'
  managedBy: 'platform-team'
  createdBy: 'alz-bicep'
}

// ---- Resource Group ----
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-identity-australiaeast-001'
  location: location
  tags: tags
}

// ---- Identity VNet ----
module identityVnet 'br/public:avm/res/network/virtual-network:0.5.2' = {
  name: 'deploy-identity-vnet'
  scope: rg
  params: {
    name: 'vnet-identity-australiaeast-001'
    location: location
    addressPrefixes: ['10.10.0.0/16']
    tags: tags
    subnets: [
      {
        name: 'snet-domain-controllers'
        addressPrefix: '10.10.0.0/24'
        // Route DC traffic through Checkpoint in hub
        routeTableResourceId: hubRouteTableId
      }
    ]
    peerings: [
      {
        remoteVirtualNetworkId: hubVnetId
        allowVirtualNetworkAccess: true
        allowForwardedTraffic: true
        allowGatewayTransit: false
        useRemoteGateways: true   // Use VPN Gateway in hub
        remotePeeringEnabled: true
        remotePeeringAllowVirtualNetworkAccess: true
        remotePeeringAllowForwardedTraffic: true
        remotePeeringAllowGatewayTransit: true
        remotePeeringUseRemoteGateways: false
      }
    ]
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceId
      }
    ]
  }
}

// ---- Outputs ----
output identityVnetId string = identityVnet.outputs.resourceId
output resourceGroupId string = rg.id
