targetScope = 'subscription'

// ============================================================
// Azure Landing Zone - Connectivity / Perth Extended Zone (PEZ)
// Region        : Australia East (PEZ is an Extended Zone of AustEast)
// Extended Zone : Perth
// Topology      : Hub & Spoke (Dual-VNet Security pattern)
// NVA           : Checkpoint CloudGuard — MANUAL DEPLOYMENT
// WAN Edge      : ExpressRoute
//
// Design decisions implemented:
//   DD17 — PEZ as secondary location alongside Australia East
//   DD22 — Single fault domain (no AZ support in PEZ)
//            → ErGw1  (NOT ErGw1AZ — no zone-redundant SKUs in PEZ)
//            → No zones: [] on PIPs (PEZ does not support AZs)
//
// VNet layout (PEZ — default CIDRs derived from params):
//   vnet-hub-pez-001              hubVnetAddressPrefix (/16)  — egress / hybrid
//     snet-checkpoint-internal    cidrSubnet(/16, 12, 16)     — Checkpoint eth1 e.g. 10.2.1.0/28
//     snet-management             cidrSubnet(/16,  8,  2)     — jump hosts       e.g. 10.2.2.0/24
//     GatewaySubnet               cidrSubnet(/16, 11, 24)     — ER Gateway        e.g. 10.2.3.0/27
//
//   vnet-ingress-pez-001          ingressVnetAddressPrefix (/16)  — internet-facing / DMZ
//     snet-checkpoint-external    cidrSubnet(/16, 12,  0)     — Checkpoint eth0  e.g. 10.3.0.0/28
//     snet-ingress-dmz            cidrSubnet(/16,  8,  1)     — DMZ workloads    e.g. 10.3.1.0/24
//
// ──────────────────────────────────────────────────────────────
// CHECKPOINT DEPLOYMENT — MANUAL ACTIVITY
// ──────────────────────────────────────────────────────────────
// This template intentionally does NOT deploy Checkpoint VMs or
// VMSS. The VNets and subnets below are pre-created as the
// network foundation. The Checkpoint NVA must be deployed
// manually by the network team after the VNets are provisioned:
//
//   1. Deploy Checkpoint CloudGuard R81.10 from Azure Marketplace
//      into the pre-created PEZ subnets:
//        eth0 → snet-checkpoint-external  (vnet-ingress-pez-001)
//        eth1 → snet-checkpoint-internal  (vnet-hub-pez-001)
//   2. Assign the static Internal LB frontend IP = checkpointInternalIp output
//      (cidrHost of snet-checkpoint-internal, index 4)
//   3. DD22: PEZ is a single fault domain — deploy at least 1 instance;
//      2 instances recommended for HA within the Extended Zone.
//   4. See: docs/checkpoint-first-boot.md
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
//   workflow (pass this gateway's resource ID).
//
// NOTE — DDoS Protection Plan (DD34):
//   PEZ reuses the Australia East DDoS Protection Plan. Pass the plan
//   resource ID from the Australia East deployment as ddosProtectionPlanId.
// ============================================================

@description('Azure region — PEZ is an Extended Zone of Australia East; location stays australiaeast')
param location string = 'australiaeast'

@description('Perth Extended Zone edge zone name. Retrieve with: az edge-zones list --query "[?location==\'australiaeast\'].name" -o tsv')
param edgeZone string = 'perth'

@description('Hub VNet address space (egress / hybrid VNet)')
param hubVnetAddressPrefix string = '10.2.0.0/16'

@description('Ingress VNet address space (internet-facing / DMZ VNet)')
param ingressVnetAddressPrefix string = '10.3.0.0/16'

@description('Log Analytics workspace resource ID for diagnostics (Australia East workspace)')
param logAnalyticsWorkspaceId string

@description('DD22: ER Gateway SKU for PEZ. Must NOT use AZ-suffix SKUs — PEZ has a single fault domain.')
@allowed(['ErGw1', 'ErGw2', 'ErGw3'])
param erGatewaySku string = 'ErGw1'

@description('DDoS Protection Plan resource ID — reuse the Australia East plan (DD34). Output ddosProtectionPlanId from platform/connectivity/main.bicep.')
param ddosProtectionPlanId string

@description('On-premises network CIDR — restricts management subnet NSG inbound rules to on-prem only')
param onPremAddressSpace string = '10.0.0.0/8'

@description('Resource tags')
param tags object = {
  environment: 'connectivity'
  managedBy  : 'platform-team'
  createdBy  : 'alz-bicep'
  location   : 'pez-perth'
}

// ── Derived Subnet CIDRs (from hubVnetAddressPrefix) ─────────────────────────
var hubSubnetInternal  = cidrSubnet(hubVnetAddressPrefix, 12, 16)
var hubSubnetMgmt      = cidrSubnet(hubVnetAddressPrefix, 8,  2)
var hubSubnetGateway   = cidrSubnet(hubVnetAddressPrefix, 11, 24)

// ── Derived Subnet CIDRs (from ingressVnetAddressPrefix) ─────────────────────
var ingressSubnetExternal = cidrSubnet(ingressVnetAddressPrefix, 12, 0)
var ingressSubnetDmz      = cidrSubnet(ingressVnetAddressPrefix, 8,  1)

// ── Reserved NVA IP — published as output for manual Checkpoint deployment ───
// Azure reserves .0–.3; first usable host = index 4.
var checkpointInternalIp = cidrHost(hubSubnetInternal, 4)

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
// ============================================================

// ExpressRoute Gateway PIP — Standard SKU, no zones (ErGw1 non-AZ)
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
          priority                 : 100
          protocol                 : 'Tcp'
          access                   : 'Allow'
          direction                : 'Inbound'
          sourceAddressPrefix      : '*'
          sourcePortRange          : '*'
          destinationAddressPrefix : '*'
          destinationPortRange     : '443'
        }
      }
      {
        name: 'Allow-HTTP-Inbound'
        properties: {
          priority                 : 110
          protocol                 : 'Tcp'
          access                   : 'Allow'
          direction                : 'Inbound'
          sourceAddressPrefix      : '*'
          sourcePortRange          : '*'
          destinationAddressPrefix : '*'
          destinationPortRange     : '80'
        }
      }
      {
        name: 'Allow-CheckpointMgmt-Inbound'
        properties: {
          priority                 : 120
          protocol                 : 'Tcp'
          access                   : 'Allow'
          direction                : 'Inbound'
          sourceAddressPrefixes    : [onPremAddressSpace]
          sourcePortRange          : '*'
          destinationAddressPrefix : '*'
          destinationPortRanges    : ['18190', '19009', '257', '8211']
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority                 : 4096
          protocol                 : '*'
          access                   : 'Deny'
          direction                : 'Inbound'
          sourceAddressPrefix      : '*'
          sourcePortRange          : '*'
          destinationAddressPrefix : '*'
          destinationPortRange     : '*'
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
    securityRules: [
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority                 : 4096
          protocol                 : '*'
          access                   : 'Deny'
          direction                : 'Inbound'
          sourceAddressPrefix      : '*'
          sourcePortRange          : '*'
          destinationAddressPrefix : '*'
          destinationPortRange     : '*'
        }
      }
    ]
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

module nsgManagement 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name : 'deploy-nsg-management-pez'
  scope: rg
  params: {
    name    : 'nsg-management-pez-001'
    location: location
    tags    : tags
    securityRules: [
      {
        name: 'Allow-RDP-from-OnPrem'
        properties: {
          priority                 : 100
          protocol                 : 'Tcp'
          access                   : 'Allow'
          direction                : 'Inbound'
          sourceAddressPrefix      : onPremAddressSpace
          sourcePortRange          : '*'
          destinationAddressPrefix : '*'
          destinationPortRange     : '3389'
        }
      }
      {
        name: 'Allow-SSH-from-OnPrem'
        properties: {
          priority                 : 110
          protocol                 : 'Tcp'
          access                   : 'Allow'
          direction                : 'Inbound'
          sourceAddressPrefix      : onPremAddressSpace
          sourcePortRange          : '*'
          destinationAddressPrefix : '*'
          destinationPortRange     : '22'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority                 : 4096
          protocol                 : '*'
          access                   : 'Deny'
          direction                : 'Inbound'
          sourceAddressPrefix      : '*'
          sourcePortRange          : '*'
          destinationAddressPrefix : '*'
          destinationPortRange     : '*'
        }
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// Route Table — default route via Checkpoint NVA (placeholder)
//
// Next-hop = checkpointInternalIp (first usable host in
// snet-checkpoint-internal). This is a placeholder until the
// network team manually deploys Checkpoint into that subnet.
// ============================================================
module routeTableSpoke 'br/public:avm/res/network/route-table:0.4.0' = {
  name : 'deploy-rt-to-checkpoint-pez'
  scope: rg
  params: {
    name    : 'rt-to-checkpoint-pez-001'
    location: location
    tags    : tags
    routes  : [
      {
        name: 'route-default-to-checkpoint'
        properties: {
          addressPrefix   : '0.0.0.0/0'
          nextHopType     : 'VirtualAppliance'
          nextHopIpAddress: checkpointInternalIp   // Reserved for manual Checkpoint Internal LB
        }
      }
    ]
  }
}

// ============================================================
// Hub Virtual Network — egress / hybrid (PEZ)
//
// extendedLocation places this VNet in the Perth Extended Zone.
// Checkpoint VMs are deployed MANUALLY into snet-checkpoint-internal.
// ============================================================
resource hubVnetResource 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name    : 'vnet-hub-pez-001'
  location: location
  tags    : tags
  extendedLocation: {
    name: edgeZone
    type: 'EdgeZone'
  }
  properties: {
    addressSpace: {
      addressPrefixes: [hubVnetAddressPrefix]
    }
    ddosProtectionPlan  : { id: ddosProtectionPlanId }
    enableDdosProtection: true
    subnets: [
      {
        // Checkpoint eth1 — internal / trusted.
        // MANUAL: Deploy Checkpoint NVA into this subnet after pipeline completes.
        name: 'snet-checkpoint-internal'
        properties: {
          addressPrefix       : hubSubnetInternal
          networkSecurityGroup: { id: nsgCheckpointInternal.outputs.resourceId }
        }
      }
      {
        // Management jump hosts — UDR intentionally omitted.
        name: 'snet-management'
        properties: {
          addressPrefix       : hubSubnetMgmt
          networkSecurityGroup: { id: nsgManagement.outputs.resourceId }
        }
      }
      {
        // Reserved for ER Gateway — no NSG or UDR.
        name: 'GatewaySubnet'
        properties: {
          addressPrefix: hubSubnetGateway
        }
      }
    ]
  }
  dependsOn: [nsgCheckpointInternal, nsgManagement]
}

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
//
// Hosts Checkpoint eth0 (external NIC) and DMZ workloads.
// Checkpoint VMs are deployed MANUALLY into snet-checkpoint-external.
// ============================================================
resource ingressVnetResource 'Microsoft.Network/virtualNetworks@2023-09-01' = {
  name    : 'vnet-ingress-pez-001'
  location: location
  tags    : tags
  extendedLocation: {
    name: edgeZone
    type: 'EdgeZone'
  }
  properties: {
    addressSpace: {
      addressPrefixes: [ingressVnetAddressPrefix]
    }
    ddosProtectionPlan  : { id: ddosProtectionPlanId }
    enableDdosProtection: true
    subnets: [
      {
        // Checkpoint eth0 — external / internet-facing.
        // MANUAL: Deploy Checkpoint NVA into this subnet after pipeline completes.
        name: 'snet-checkpoint-external'
        properties: {
          addressPrefix       : ingressSubnetExternal
          networkSecurityGroup: { id: nsgCheckpointExternal.outputs.resourceId }
        }
      }
      {
        // DMZ workloads — UDR forces egress through Checkpoint once NVA is deployed.
        name: 'snet-ingress-dmz'
        properties: {
          addressPrefix       : ingressSubnetDmz
          networkSecurityGroup: { id: nsgIngressDmz.outputs.resourceId }
          routeTable          : { id: routeTableSpoke.outputs.resourceId }
        }
      }
    ]
    virtualNetworkPeerings: [
      {
        name: 'peer-ingress-to-hub-pez'
        properties: {
          remoteVirtualNetwork     : { id: hubVnetResource.id }
          allowVirtualNetworkAccess: true
          allowForwardedTraffic    : true
          allowGatewayTransit      : false
          useRemoteGateways        : true   // ingress VNet uses hub ER gateway
        }
      }
    ]
  }
  dependsOn: [hubVnetResource, nsgCheckpointExternal, nsgIngressDmz, routeTableSpoke]
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
  name  : 'peer-hub-to-ingress-pez'
  parent: hubVnetResource
  properties: {
    remoteVirtualNetwork     : { id: ingressVnetResource.id }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic    : true
    allowGatewayTransit      : true    // hub shares ER gateway with ingress
    useRemoteGateways        : false
  }
  dependsOn: [ingressVnetResource]
}

// ============================================================
// ExpressRoute Virtual Network Gateway (PEZ)
//
// DD22 — Single Fault Domain:
//   Use ErGw1 (NOT ErGw1AZ). AZ-suffix SKUs are not available
//   in Perth Extended Zone.
//   Gateway is placed in the Extended Zone via extendedLocation.
//
// Inline ARM resource used because the AVM virtual-network-gateway
// module does not support extendedLocation.
// ============================================================
resource erGatewayPipRef 'Microsoft.Network/publicIPAddresses@2023-09-01' existing = {
  name     : 'pip-ergw-pez-001'
  scope    : rg
  dependsOn: [erGatewayPip]
}

resource erGateway 'Microsoft.Network/virtualNetworkGateways@2023-09-01' = {
  name    : 'ergw-hub-pez-001'
  location: location
  tags    : tags
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
          publicIPAddress          : { id: erGatewayPipRef.id }
          subnet                   : { id: '${hubVnetResource.id}/subnets/GatewaySubnet' }
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
      { category: 'GatewayDiagnosticLog'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'TunnelDiagnosticLog';  enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'RouteDiagnosticLog';   enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'IKEDiagnosticLog';     enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
  }
}

// ============================================================
// Outputs
// ============================================================
output hubVnetId          string = hubVnetResource.id
output hubVnetName        string = hubVnetResource.name
output ingressVnetId      string = ingressVnetResource.id
output ingressVnetName    string = ingressVnetResource.name
output erGatewayId        string = erGateway.id
output erGatewayName      string = erGateway.name
output routeTableId       string = routeTableSpoke.outputs.resourceId
output resourceGroupId    string = rg.id

// Subnet IDs — for downstream peering, security, and Checkpoint manual deployment reference
output internalSubnetId   string = '${hubVnetResource.id}/subnets/snet-checkpoint-internal'
output externalSubnetId   string = '${ingressVnetResource.id}/subnets/snet-checkpoint-external'
output managementSubnetId string = '${hubVnetResource.id}/subnets/snet-management'
output ingressDmzSubnetId string = '${ingressVnetResource.id}/subnets/snet-ingress-dmz'

// Reserved NVA IP — network team should assign this to the Checkpoint Internal LB frontend.
output checkpointInternalIp string = checkpointInternalIp

// NOTE: erCircuitId is NOT output here — PEZ circuit is created manually.
