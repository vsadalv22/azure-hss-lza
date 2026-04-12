targetScope = 'subscription'

// ============================================================
// Azure Landing Zone - Connectivity / Perth Extended Zone (PEZ)
// Region        : Australia East (PEZ is an Extended Zone of AustEast)
// Extended Zone : Perth
// Topology      : Hub & Spoke (Dual-VNet Security pattern)
// NVA           : Checkpoint CloudGuard (VMSS, reduced footprint)
// WAN Edge      : ExpressRoute
//
// Design decisions implemented:
//   DD17 — PEZ as secondary location alongside Australia East
//   DD22 — Single fault domain (no AZ support in PEZ)
//            → ErGw1  (NOT ErGw1AZ — no zone-redundant SKUs in PEZ)
//            → No zones: [] on PIPs (PEZ does not support AZs)
//
// VNet layout (PEZ):
//   vnet-hub-pez-001              10.2.0.0/16  — egress / hybrid
//     snet-checkpoint-internal    10.2.1.0/28  — Checkpoint eth1
//     snet-management             10.2.2.0/24  — jump hosts
//     GatewaySubnet               10.2.3.0/27  — ER Gateway
//
//   vnet-ingress-pez-001          10.3.0.0/16  — internet-facing / DMZ
//     snet-checkpoint-external    10.3.0.0/28  — Checkpoint eth0
//     snet-ingress-dmz            10.3.1.0/24  — DMZ workloads
//
// Extended Zone configuration:
//   All VNet and Gateway resources carry:
//     extendedLocation: { name: edgeZone, type: 'EdgeZone' }
//   This places them in the Perth Extended Zone, not the parent
//   Australia East region datacenter.
//
// NOTE — ExpressRoute circuit lifecycle:
//   The PEZ ER circuit is created MANUALLY (same pattern as Australia
//   East). This template deploys only the Azure-side PEZ infrastructure.
//   After circuit provisioning, link via 03b-platform-er-connection
//   workflow (point at this gateway's resource ID).
//
// NOTE — DDoS Protection Plan (DD34):
//   PEZ reuses the Australia East DDoS Protection Plan. A single plan
//   can protect VNets across the subscription. Pass the plan resource ID
//   from the Australia East deployment as ddosProtectionPlanId.
// ============================================================

@description('Azure region — PEZ is an Extended Zone of Australia East, location stays australiaeast')
param location string = 'australiaeast'

@description('Perth Extended Zone edge zone name. Pass the exact name returned by: az edge-zones list --query "[?location==\'australiaeast\'].name" -o tsv')
param edgeZone string = 'perth'

@description('Hub VNet address space (egress / hybrid VNet)')
param hubVnetAddressPrefix string = '10.2.0.0/16'

@description('Ingress VNet address space (internet-facing / DMZ VNet)')
param ingressVnetAddressPrefix string = '10.3.0.0/16'

@description('Log Analytics workspace resource ID for diagnostics (Australia East workspace)')
param logAnalyticsWorkspaceId string

@description('Checkpoint admin username')
param checkpointAdminUsername string = 'azureadmin'

@secure()
@description('Checkpoint admin password')
param checkpointAdminPassword string

@description('Checkpoint licence SKU: sg-byol | sg-ngtp | sg-ngtx')
@allowed(['sg-byol', 'sg-ngtp', 'sg-ngtx'])
param checkpointSku string = 'sg-byol'

@description('DD22: ER Gateway SKU for PEZ. Must NOT use AZ-suffix SKUs (ErGw1AZ etc.) — PEZ has a single fault domain.')
@allowed(['ErGw1', 'ErGw2', 'ErGw3'])
param erGatewaySku string = 'ErGw1'

@description('DDoS Protection Plan resource ID — reuse the Australia East plan (DD34). Output ddosProtectionPlanId from platform/connectivity/main.bicep.')
param ddosProtectionPlanId string

@description('Resource tags')
param tags object = {
  environment: 'connectivity'
  managedBy  : 'platform-team'
  createdBy  : 'alz-bicep'
  location   : 'pez-perth'
}

// ============================================================
// Resource Group
// ============================================================
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name    : 'rg-connectivity-hub-pez-001'
  location: location
  tags    : tags
}

// ============================================================
// Public IPs
//
// DD22: PEZ does not support Availability Zones.
//       No zones: [] property on any PIP in this file.
//       Use AVM module with zones omitted (defaults to no zones).
// ============================================================

// Checkpoint external NIC — public IP for internet egress
module checkpointExternalPip 'br/public:avm/res/network/public-ip-address:0.7.1' = {
  name : 'deploy-pip-checkpoint-external-pez'
  scope: rg
  params: {
    name                   : 'pip-checkpoint-external-pez-001'
    location               : location
    skuName                : 'Standard'
    publicIPAllocationMethod: 'Static'
    // DD22: NO zones property — PEZ is single fault domain, AZs not supported
    tags                   : tags
    diagnosticSettings     : [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ExpressRoute Gateway PIP
// DD22: Standard SKU without zones (ErGw1 non-AZ)
module erGatewayPip 'br/public:avm/res/network/public-ip-address:0.7.1' = {
  name : 'deploy-pip-ergw-pez'
  scope: rg
  params: {
    name                   : 'pip-ergw-pez-001'
    location               : location
    skuName                : 'Standard'
    publicIPAllocationMethod: 'Static'
    // DD22: NO zones property — required for ErGw1 (non-AZ) in PEZ
    tags                   : tags
    diagnosticSettings     : [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// Network Security Groups
// ============================================================

module nsgCheckpointExternal 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name : 'deploy-nsg-checkpoint-external-pez'
  scope: rg
  params: {
    name    : 'nsg-checkpoint-external-pez-001'
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
  name : 'deploy-nsg-checkpoint-internal-pez'
  scope: rg
  params: {
    name    : 'nsg-checkpoint-internal-pez-001'
    location: location
    tags    : tags
    securityRules: []
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

module nsgIngressDmz 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name : 'deploy-nsg-ingress-dmz-pez'
  scope: rg
  params: {
    name    : 'nsg-ingress-dmz-pez-001'
    location: location
    tags    : tags
    securityRules: []
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// Route Table — force spoke default traffic via Checkpoint
// ============================================================
module routeTableSpoke 'br/public:avm/res/network/route-table:0.4.0' = {
  name : 'deploy-udr-to-checkpoint-pez'
  scope: rg
  params: {
    name    : 'udr-to-checkpoint-pez-001'
    location: location
    tags    : tags
    routes  : [
      {
        name: 'route-default-to-checkpoint'
        properties: {
          addressPrefix   : '0.0.0.0/0'
          nextHopType     : 'VirtualAppliance'
          nextHopIpAddress: '10.2.1.4'   // PEZ Internal LB frontend static IP
        }
      }
    ]
  }
}

// ============================================================
// Hub Virtual Network — egress / hybrid (PEZ)
//
// extendedLocation places this VNet resource in the Perth
// Extended Zone rather than the parent Australia East region.
// ============================================================
resource hubVnetResource 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name    : 'vnet-hub-pez-001'
  location: location
  tags    : tags
  // DD17/DD22: Extended Zone placement
  extendedLocation: {
    name: edgeZone
    type: 'EdgeZone'
  }
  properties: {
    addressSpace: {
      addressPrefixes: [hubVnetAddressPrefix]
    }
    // DDoS Protection Standard — reuse Australia East plan (DD34)
    ddosProtectionPlan: {
      id: ddosProtectionPlanId
    }
    enableDdosProtection: true
    subnets: [
      {
        name: 'snet-checkpoint-internal'
        properties: {
          addressPrefix: '10.2.1.0/28'
          networkSecurityGroup: {
            id: nsgCheckpointInternal.outputs.resourceId
          }
        }
      }
      {
        name: 'snet-management'
        properties: {
          addressPrefix: '10.2.2.0/24'
          routeTable: {
            id: routeTableSpoke.outputs.resourceId
          }
        }
      }
      {
        // Reserved for ER Gateway — no NSG or UDR
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: '10.2.3.0/27'
        }
      }
    ]
  }
}

// Diagnostics for hub VNet (inline — AVM VNet module doesn't support extendedLocation)
resource hubVnetDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name : 'diag-vnet-hub-pez-001'
  scope: hubVnetResource
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
  }
}

// ============================================================
// Ingress Virtual Network — internet-facing / DMZ (PEZ)
// ============================================================
resource ingressVnetResource 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name    : 'vnet-ingress-pez-001'
  location: location
  tags    : tags
  // DD17/DD22: Extended Zone placement
  extendedLocation: {
    name: edgeZone
    type: 'EdgeZone'
  }
  properties: {
    addressSpace: {
      addressPrefixes: [ingressVnetAddressPrefix]
    }
    // DDoS Protection Standard — reuse Australia East plan (DD34)
    ddosProtectionPlan: {
      id: ddosProtectionPlanId
    }
    enableDdosProtection: true
    subnets: [
      {
        name: 'snet-checkpoint-external'
        properties: {
          addressPrefix: '10.3.0.0/28'
          networkSecurityGroup: {
            id: nsgCheckpointExternal.outputs.resourceId
          }
        }
      }
      {
        name: 'snet-ingress-dmz'
        properties: {
          addressPrefix: '10.3.1.0/24'
          networkSecurityGroup: {
            id: nsgIngressDmz.outputs.resourceId
          }
          routeTable: {
            id: routeTableSpoke.outputs.resourceId
          }
        }
      }
    ]
    // VNet peering: ingress → hub (defined inline on the ingress VNet)
    virtualNetworkPeerings: [
      {
        name: 'peer-ingress-to-hub-pez'
        properties: {
          remoteVirtualNetwork        : { id: hubVnetResource.id }
          allowVirtualNetworkAccess   : true
          allowForwardedTraffic       : true
          allowGatewayTransit         : false
          useRemoteGateways           : true   // ingress VNet uses hub ER gateway
        }
      }
    ]
  }
  dependsOn: [hubVnetResource]
}

resource ingressVnetDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name : 'diag-vnet-ingress-pez-001'
  scope: ingressVnetResource
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
  }
}

// VNet peering: hub → ingress (reverse peering, allow gateway transit)
resource hubToIngressPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name      : 'peer-hub-to-ingress-pez'
  parent    : hubVnetResource
  properties: {
    remoteVirtualNetwork        : { id: ingressVnetResource.id }
    allowVirtualNetworkAccess   : true
    allowForwardedTraffic       : true
    allowGatewayTransit         : true    // hub shares ER gateway with ingress
    useRemoteGateways           : false
  }
  dependsOn: [ingressVnetResource]
}

// ============================================================
// ExpressRoute Virtual Network Gateway (PEZ)
//
// DD22 — Single Fault Domain:
//   Use ErGw1 (NOT ErGw1AZ). The AZ-suffix SKUs require Availability
//   Zones which are not available in Perth Extended Zone.
//   The gateway is placed in the Extended Zone via extendedLocation.
//
// DD17 — Secondary location:
//   This PEZ gateway provides secondary WAN connectivity.
//   Primary connectivity is via Australia East (ergw-hub-australiaeast-001).
//
// NOTE — Active/Active not applicable for PEZ (single gateway, single FD).
//
// Inline ARM resource used here because the AVM
// virtual-network-gateway module does not support extendedLocation.
// ============================================================
resource erGatewayPipRef 'Microsoft.Network/publicIPAddresses@2023-09-01' existing = {
  name : 'pip-ergw-pez-001'
  scope: rg
  dependsOn: [erGatewayPip]
}

resource erGateway 'Microsoft.Network/virtualNetworkGateways@2023-09-01' = {
  name    : 'ergw-hub-pez-001'
  location: location
  tags    : tags
  // DD22: Extended Zone placement — single fault domain, non-AZ SKU
  extendedLocation: {
    name: edgeZone
    type: 'EdgeZone'
  }
  properties: {
    gatewayType: 'ExpressRoute'
    sku: {
      name: erGatewaySku   // ErGw1 — NOT zone-redundant (DD22)
      tier: erGatewaySku
    }
    ipConfigurations: [
      {
        name: 'gwipconfig'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: erGatewayPipRef.id
          }
          subnet: {
            // GatewaySubnet ID within the PEZ hub VNet
            id: '${hubVnetResource.id}/subnets/GatewaySubnet'
          }
        }
      }
    ]
  }
  dependsOn: [erGatewayPip, hubVnetResource]
}

resource erGatewayDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name : 'diag-ergw-hub-pez-001'
  scope: erGateway
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
    logs: [
      { category: 'GatewayDiagnosticLog';    enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'TunnelDiagnosticLog';     enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'RouteDiagnosticLog';      enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'IKEDiagnosticLog';        enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
  }
}

// ============================================================
// Checkpoint CloudGuard NVA — VM Scale Set (DD30, PEZ)
//
// PEZ uses instanceCount = 1 (reduced footprint for secondary site).
// The VMSS module handles its own Internal and External LBs.
// Internal LB frontend IP: 10.2.1.4 (matches UDR next-hop above).
//
// NOTE: The checkpoint-vmss module uses resourceId() calls that
//       assume the Internal LB name pattern. The internalSubnetId
//       drives the frontend IP subnet — ensure it resolves to 10.2.1.x.
// ============================================================
module checkpointVmss '../modules/checkpoint-vmss.bicep' = {
  name : 'deploy-checkpoint-vmss-pez'
  scope: rg
  params: {
    location               : location
    vmssName               : 'vmss-checkpoint-pez-001'
    vmSize                 : 'Standard_D3_v2'
    adminUsername          : checkpointAdminUsername
    adminPassword          : checkpointAdminPassword
    checkpointSku          : checkpointSku
    // eth0 — external NIC in ingress VNet
    externalSubnetId       : '${ingressVnetResource.id}/subnets/snet-checkpoint-external'
    // eth1 — internal NIC in hub VNet
    internalSubnetId       : '${hubVnetResource.id}/subnets/snet-checkpoint-internal'
    externalPublicIpId     : checkpointExternalPip.outputs.resourceId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    // DD17: PEZ is secondary — reduced footprint, 1 instance minimum
    instanceCount          : 1
    tags                   : tags
  }
}

// ============================================================
// Outputs
// ============================================================
output hubVnetId              string = hubVnetResource.id
output hubVnetName            string = hubVnetResource.name
output ingressVnetId          string = ingressVnetResource.id
output ingressVnetName        string = ingressVnetResource.name
output checkpointInternalIp   string = checkpointVmss.outputs.internalLoadBalancerFrontendIp
output erGatewayId            string = erGateway.id
output erGatewayName          string = erGateway.name
output routeTableId           string = routeTableSpoke.outputs.resourceId
output resourceGroupId        string = rg.id
// NOTE: erCircuitId is NOT output here — PEZ circuit is created manually.
// After manual creation, copy the circuit resource ID and use it in
// the 03b-platform-er-connection workflow (pass this erGatewayId).
