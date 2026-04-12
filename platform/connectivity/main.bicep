targetScope = 'subscription'

// ============================================================
// Azure Landing Zone - Connectivity / Hub Networking
// Region        : Australia East
// Topology      : Hub & Spoke
// NVA           : Checkpoint CloudGuard
// WAN Edge      : ExpressRoute (Standard, Unlimited Data)
// Note          : Azure Bastion is NOT used in this design
// ============================================================

@description('Azure region')
param location string = 'australiaeast'

@description('Hub VNet address space')
param hubVnetAddressPrefix string = '10.0.0.0/16'

@description('Log Analytics workspace resource ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('Checkpoint admin username')
param checkpointAdminUsername string = 'azureadmin'

@secure()
@description('Checkpoint admin password')
param checkpointAdminPassword string

@description('Checkpoint VM size')
param checkpointVmSize string = 'Standard_D3_v2'

@description('Checkpoint licence SKU: sg-byol | sg-ngtp | sg-ngtx')
@allowed(['sg-byol', 'sg-ngtp', 'sg-ngtx'])
param checkpointSku string = 'sg-byol'

// ---- ExpressRoute parameters ----
@description('ExpressRoute circuit name')
param erCircuitName string = 'erc-hub-australiaeast-001'

@description('ExpressRoute service provider name (e.g. Equinix, Megaport)')
param erServiceProviderName string

@description('ExpressRoute peering location (e.g. Sydney, Melbourne)')
param erPeeringLocation string = 'Sydney'

@description('ExpressRoute bandwidth in Mbps: 50 | 100 | 200 | 500 | 1000 | 2000 | 5000 | 10000')
@allowed([50, 100, 200, 500, 1000, 2000, 5000, 10000])
param erBandwidthInMbps int = 1000

@description('ExpressRoute SKU tier: Standard | Premium')
@allowed(['Standard', 'Premium'])
param erSkuTier string = 'Standard'

@description('ExpressRoute SKU family: MeteredData | UnlimitedData')
@allowed(['MeteredData', 'UnlimitedData'])
param erSkuFamily string = 'UnlimitedData'

@description('ExpressRoute Gateway SKU: ErGw1AZ | ErGw2AZ | ErGw3AZ')
@allowed(['ErGw1AZ', 'ErGw2AZ', 'ErGw3AZ'])
param erGatewaySku string = 'ErGw1AZ'

@description('Resource tags')
param tags object = {
  environment: 'connectivity'
  managedBy: 'platform-team'
  createdBy: 'alz-bicep'
}

// ============================================================
// Resource Group
// ============================================================
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-connectivity-hub-australiaeast-001'
  location: location
  tags: tags
}

// ============================================================
// Public IPs
// ============================================================

// Checkpoint external PIP
module checkpointExternalPip 'br/public:avm/res/network/public-ip-address:0.7.1' = {
  name: 'deploy-pip-checkpoint-external'
  scope: rg
  params: {
    name: 'pip-checkpoint-external-001'
    location: location
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
    zones: ['1', '2', '3']
    tags: tags
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ExpressRoute Gateway PIP (zone-redundant)
module erGatewayPip 'br/public:avm/res/network/public-ip-address:0.7.1' = {
  name: 'deploy-pip-ergw'
  scope: rg
  params: {
    name: 'pip-ergw-hub-001'
    location: location
    skuName: 'Standard'
    publicIPAllocationMethod: 'Static'
    zones: ['1', '2', '3']
    tags: tags
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// Network Security Groups
// ============================================================

module nsgCheckpointExternal 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'deploy-nsg-checkpoint-external'
  scope: rg
  params: {
    name: 'nsg-checkpoint-external-001'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'Allow-HTTPS-Inbound'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '443'
        }
      }
      {
        name: 'Allow-HTTP-Inbound'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '80'
        }
      }
      {
        name: 'Allow-CheckpointMgmt-Inbound'
        properties: {
          priority: 120
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefixes: ['10.0.0.0/8']
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['18190', '19009', '257', '8211']
        }
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

module nsgCheckpointInternal 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'deploy-nsg-checkpoint-internal'
  scope: rg
  params: {
    name: 'nsg-checkpoint-internal-001'
    location: location
    tags: tags
    securityRules: []
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// Route Table — force spoke traffic through Checkpoint
// ============================================================
module routeTableSpoke 'br/public:avm/res/network/route-table:0.4.0' = {
  name: 'deploy-udr-to-checkpoint'
  scope: rg
  params: {
    name: 'udr-to-checkpoint-001'
    location: location
    tags: tags
    routes: [
      {
        name: 'route-default-to-checkpoint'
        properties: {
          addressPrefix: '0.0.0.0/0'
          nextHopType: 'VirtualAppliance'
          nextHopIpAddress: '10.0.1.4'   // Checkpoint internal NIC static IP
        }
      }
    ]
  }
}

// ============================================================
// Hub Virtual Network
// ============================================================
module hubVnet 'br/public:avm/res/network/virtual-network:0.5.2' = {
  name: 'deploy-hub-vnet'
  scope: rg
  params: {
    name: 'vnet-hub-australiaeast-001'
    location: location
    addressPrefixes: [hubVnetAddressPrefix]
    tags: tags
    subnets: [
      {
        // Checkpoint external (untrusted) interface
        name: 'snet-checkpoint-external'
        addressPrefix: '10.0.0.0/28'
        networkSecurityGroupResourceId: nsgCheckpointExternal.outputs.resourceId
      }
      {
        // Checkpoint internal (trusted) interface — UDR applied here too
        name: 'snet-checkpoint-internal'
        addressPrefix: '10.0.1.0/28'
        networkSecurityGroupResourceId: nsgCheckpointInternal.outputs.resourceId
      }
      {
        // Management / jump hosts (reach via ER from on-prem)
        name: 'snet-management'
        addressPrefix: '10.0.2.0/24'
        routeTableResourceId: routeTableSpoke.outputs.resourceId
      }
      {
        // ExpressRoute Gateway subnet — no NSG or UDR allowed
        name: 'GatewaySubnet'
        addressPrefix: '10.0.3.0/27'
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// ExpressRoute Circuit
// ============================================================
resource erCircuit 'Microsoft.Network/expressRouteCircuits@2023-09-01' = {
  name: erCircuitName
  location: location
  tags: tags
  sku: {
    name: '${erSkuTier}_${erSkuFamily}'
    tier: erSkuTier
    family: erSkuFamily
  }
  properties: {
    serviceProviderProperties: {
      serviceProviderName: erServiceProviderName
      peeringLocation: erPeeringLocation
      bandwidthInMbps: erBandwidthInMbps
    }
    allowClassicOperations: false
  }
}

// ---- Diagnostic settings on ER circuit ----
resource erCircuitDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${erCircuitName}'
  scope: erCircuit
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { categoryGroup: 'allLogs'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
    metrics: [
      { category: 'AllMetrics'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
  }
}

// ============================================================
// ExpressRoute Virtual Network Gateway (Zone-Redundant)
// ============================================================
module erGateway 'br/public:avm/res/network/virtual-network-gateway:0.5.0' = {
  name: 'deploy-er-gateway'
  scope: rg
  params: {
    name: 'ergw-hub-australiaeast-001'
    location: location
    gatewayType: 'ExpressRoute'
    vNetResourceId: hubVnet.outputs.resourceId
    skuName: erGatewaySku
    gatewayPipName: erGatewayPip.outputs.name
    tags: tags
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// ExpressRoute Connection (Gateway <--> Circuit)
// NOTE: Circuit must be provisioned by the provider before
//       this resource will reach 'Succeeded' state.
// ============================================================
resource erConnection 'Microsoft.Network/connections@2023-09-01' = {
  name: 'con-ergw-to-circuit-001'
  location: location
  tags: tags
  properties: {
    connectionType: 'ExpressRoute'
    virtualNetworkGateway1: {
      id: erGateway.outputs.resourceId
      properties: {}
    }
    peer: {
      id: erCircuit.id
    }
    routingWeight: 0
  }
}

// ============================================================
// Checkpoint CloudGuard NVA
// ============================================================
module checkpointNva './modules/checkpoint-nva.bicep' = {
  name: 'deploy-checkpoint-nva'
  scope: rg
  params: {
    location: location
    vmName: 'vm-checkpoint-hub-001'
    vmSize: checkpointVmSize
    adminUsername: checkpointAdminUsername
    adminPassword: checkpointAdminPassword
    checkpointSku: checkpointSku
    externalSubnetId: '${hubVnet.outputs.resourceId}/subnets/snet-checkpoint-external'
    internalSubnetId: '${hubVnet.outputs.resourceId}/subnets/snet-checkpoint-internal'
    externalPublicIpId: checkpointExternalPip.outputs.resourceId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags: tags
  }
}

// ============================================================
// Outputs
// ============================================================
output hubVnetId string = hubVnet.outputs.resourceId
output hubVnetName string = hubVnet.outputs.name
output checkpointInternalIp string = '10.0.1.4'
output erCircuitId string = erCircuit.id
output erGatewayId string = erGateway.outputs.resourceId
output routeTableId string = routeTableSpoke.outputs.resourceId
output resourceGroupId string = rg.id
