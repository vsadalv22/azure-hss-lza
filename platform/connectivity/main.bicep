targetScope = 'subscription'

// ============================================================
// Azure Landing Zone - Connectivity / Hub Networking
// Region        : Australia East
// Topology      : Hub & Spoke
// NVA           : Checkpoint CloudGuard
// WAN Edge      : ExpressRoute
//
// NOTE — ExpressRoute circuit lifecycle:
//   The ER circuit itself is created MANUALLY by the network
//   team via Azure Portal or CLI (see docs/expressroute-setup.md).
//   This template deploys only the Azure-side infrastructure:
//     • Hub VNet + subnets
//     • ExpressRoute Virtual Network Gateway (ErGw1AZ)
//     • Checkpoint CloudGuard NVA (dual NIC)
//     • NSGs, Route Tables, Public IPs
//   Once the circuit is manually created and the provider has
//   provisioned it, run the separate workflow:
//     03b-platform-er-connection  (links gateway → circuit)
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

@description('ExpressRoute Gateway SKU. ErGw1AZ = zone-redundant 1 Gbps. Upgrade to ErGw2AZ for 10 Gbps.')
@allowed(['ErGw1AZ', 'ErGw2AZ', 'ErGw3AZ'])
param erGatewaySku string = 'ErGw1AZ'

@description('Resource tags')
param tags object = {
  environment: 'connectivity'
  managedBy  : 'platform-team'
  createdBy  : 'alz-bicep'
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

// Checkpoint external NIC — needs a public IP for internet egress
module checkpointExternalPip 'br/public:avm/res/network/public-ip-address:0.7.1' = {
  name: 'deploy-pip-checkpoint-external'
  scope: rg
  params: {
    name                   : 'pip-checkpoint-external-001'
    location               : location
    skuName                : 'Standard'
    publicIPAllocationMethod: 'Static'
    zones                  : ['1', '2', '3']
    tags                   : tags
    diagnosticSettings     : [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ExpressRoute Gateway PIP — zone-redundant, required by ErGw*AZ SKUs
module erGatewayPip 'br/public:avm/res/network/public-ip-address:0.7.1' = {
  name: 'deploy-pip-ergw'
  scope: rg
  params: {
    name                   : 'pip-ergw-hub-001'
    location               : location
    skuName                : 'Standard'
    publicIPAllocationMethod: 'Static'
    zones                  : ['1', '2', '3']
    tags                   : tags
    diagnosticSettings     : [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// Network Security Groups
// ============================================================

module nsgCheckpointExternal 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'deploy-nsg-checkpoint-external'
  scope: rg
  params: {
    name    : 'nsg-checkpoint-external-001'
    location: location
    tags    : tags
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
          sourceAddressPrefixes: ['10.0.0.0/8']   // On-prem only
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
    name    : 'nsg-checkpoint-internal-001'
    location: location
    tags    : tags
    securityRules: []
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// Route Table — force all spoke default traffic via Checkpoint
// ============================================================
module routeTableSpoke 'br/public:avm/res/network/route-table:0.4.0' = {
  name: 'deploy-udr-to-checkpoint'
  scope: rg
  params: {
    name    : 'udr-to-checkpoint-001'
    location: location
    tags    : tags
    routes  : [
      {
        name: 'route-default-to-checkpoint'
        properties: {
          addressPrefix   : '0.0.0.0/0'
          nextHopType     : 'VirtualAppliance'
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
    name           : 'vnet-hub-australiaeast-001'
    location       : location
    addressPrefixes: [hubVnetAddressPrefix]
    tags           : tags
    subnets: [
      {
        // Checkpoint eth0 — external / untrusted
        name                         : 'snet-checkpoint-external'
        addressPrefix                : '10.0.0.0/28'
        networkSecurityGroupResourceId: nsgCheckpointExternal.outputs.resourceId
      }
      {
        // Checkpoint eth1 — internal / trusted. All spoke traffic enters here.
        name                         : 'snet-checkpoint-internal'
        addressPrefix                : '10.0.1.0/28'
        networkSecurityGroupResourceId: nsgCheckpointInternal.outputs.resourceId
      }
      {
        // Management jump hosts — reachable from on-prem via ER (no Bastion)
        name                : 'snet-management'
        addressPrefix       : '10.0.2.0/24'
        routeTableResourceId: routeTableSpoke.outputs.resourceId
      }
      {
        // Reserved for ExpressRoute Gateway — no NSG or UDR permitted
        name         : 'GatewaySubnet'
        addressPrefix: '10.0.3.0/27'
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// ExpressRoute Virtual Network Gateway (Zone-Redundant)
//
// This gateway is deployed by IaC and waits for the manually-
// created ER circuit to be linked via the separate
// 03b-platform-er-connection workflow once the provider has
// provisioned the circuit.
// ============================================================
module erGateway 'br/public:avm/res/network/virtual-network-gateway:0.5.0' = {
  name: 'deploy-er-gateway'
  scope: rg
  params: {
    name              : 'ergw-hub-australiaeast-001'
    location          : location
    gatewayType       : 'ExpressRoute'
    vNetResourceId    : hubVnet.outputs.resourceId
    skuName           : erGatewaySku
    gatewayPipName    : erGatewayPip.outputs.name
    tags              : tags
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// Checkpoint CloudGuard NVA
// ============================================================
module checkpointNva './modules/checkpoint-nva.bicep' = {
  name: 'deploy-checkpoint-nva'
  scope: rg
  params: {
    location               : location
    vmName                 : 'vm-checkpoint-hub-001'
    vmSize                 : checkpointVmSize
    adminUsername          : checkpointAdminUsername
    adminPassword          : checkpointAdminPassword
    checkpointSku          : checkpointSku
    externalSubnetId       : '${hubVnet.outputs.resourceId}/subnets/snet-checkpoint-external'
    internalSubnetId       : '${hubVnet.outputs.resourceId}/subnets/snet-checkpoint-internal'
    externalPublicIpId     : checkpointExternalPip.outputs.resourceId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    tags                   : tags
  }
}

// ============================================================
// Outputs
// ============================================================
output hubVnetId           string = hubVnet.outputs.resourceId
output hubVnetName         string = hubVnet.outputs.name
output checkpointInternalIp string = '10.0.1.4'
output erGatewayId         string = erGateway.outputs.resourceId
output erGatewayName       string = 'ergw-hub-australiaeast-001'
output routeTableId        string = routeTableSpoke.outputs.resourceId
output resourceGroupId     string = rg.id
// NOTE: erCircuitId is NOT output here — the circuit is created manually.
// After manual creation, copy the circuit resource ID and use it in
// the 03b-platform-er-connection workflow.
