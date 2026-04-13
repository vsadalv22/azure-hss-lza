targetScope = 'subscription'

// ============================================================
// Azure Landing Zone - Connectivity / Hub Networking
// Region        : Australia East
// Topology      : Hub & Spoke (Dual-VNet Security pattern)
// NVA           : Checkpoint CloudGuard (VMSS cluster)
// WAN Edge      : ExpressRoute
//
// Design decisions implemented:
//   DD30 — Checkpoint VMSS (replaces single NVA)
//   DD31 — Dual Security VNet (hub/egress + ingress/DMZ VNets)
//   DD23 — BGP Active/Active note (see ER Gateway section)
//   DD34 — DDoS Protection Standard on both VNets
//
// VNet layout (default CIDRs — all subnets derived from hubVnetAddressPrefix/ingressVnetAddressPrefix):
//   vnet-hub-australiaeast-001     hubVnetAddressPrefix (/16)  — egress / hybrid
//     snet-checkpoint-internal      cidrSubnet(/16, 12, 16)    — Checkpoint eth1 e.g. 10.0.1.0/28
//     snet-management               cidrSubnet(/16,  8,  2)    — jump hosts       e.g. 10.0.2.0/24
//     GatewaySubnet                 cidrSubnet(/16, 11, 24)    — ER Gateway        e.g. 10.0.3.0/27
//
//   vnet-ingress-australiaeast-001  ingressVnetAddressPrefix (/16)  — internet-facing / DMZ
//     snet-checkpoint-external      cidrSubnet(/16, 12,  0)    — Checkpoint eth0  e.g. 10.1.0.0/28
//     snet-ingress-dmz              cidrSubnet(/16,  8,  1)    — DMZ workloads    e.g. 10.1.1.0/24
//
// NOTE — ExpressRoute circuit lifecycle:
//   The ER circuit itself is created MANUALLY by the network
//   team via Azure Portal or CLI (see docs/expressroute-setup.md).
//   This template deploys only the Azure-side infrastructure:
//     • Hub VNet + subnets
//     • Ingress VNet + subnets + VNet peering
//     • ExpressRoute Virtual Network Gateway (ErGw1AZ)
//     • Checkpoint CloudGuard NVA (VMSS, dual NIC)
//     • NSGs, Route Tables, Public IPs
//     • DDoS Protection Plan (Standard)
//   Once the circuit is manually created and the provider has
//   provisioned it, run the separate workflow:
//     03b-platform-er-connection  (links gateway → circuit)
// ============================================================

@description('Azure region')
param location string = 'australiaeast'

@description('Hub VNet address space (egress / hybrid VNet)')
param hubVnetAddressPrefix string = '10.0.0.0/16'

@description('Ingress VNet address space (internet-facing / DMZ VNet - DD31)')
param ingressVnetAddressPrefix string = '10.1.0.0/16'

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

@description('Number of Checkpoint VMSS instances (DD30 minimum 2)')
@minValue(2)
param checkpointInstanceCount int = 2

@description('ExpressRoute Gateway SKU. ErGw1AZ = zone-redundant 1 Gbps. Upgrade to ErGw2AZ for 10 Gbps.')
@allowed(['ErGw1AZ', 'ErGw2AZ', 'ErGw3AZ'])
param erGatewaySku string = 'ErGw1AZ'

@description('On-premises network CIDR — restricts management subnet NSG inbound rules to on-prem only')
param onPremAddressSpace string = '10.0.0.0/8'

@description('Resource tags')
param tags object = {
  environment: 'connectivity'
  managedBy  : 'platform-team'
  createdBy  : 'alz-bicep'
}

@description('Apply CanNotDelete resource lock to the hub connectivity resource group. Prevents accidental deletion of the hub VNet, ER Gateway, and Checkpoint VMSS.')
param enableResourceLocks bool = true

// ── Derived Subnet CIDRs (from hubVnetAddressPrefix) ──────────────────
// cidrSubnet(prefix, newbits, index) — all derived from /16 base:
//   hubSubnetExternal : /16 + 12 bits = /28, block 0  → e.g. 10.0.0.0/28
//   hubSubnetInternal : /16 + 12 bits = /28, block 16 → e.g. 10.0.1.0/28
//   hubSubnetMgmt     : /16 +  8 bits = /24, block 2  → e.g. 10.0.2.0/24
//   hubSubnetGateway  : /16 + 11 bits = /27, block 24 → e.g. 10.0.3.0/27
var hubSubnetExternal  = cidrSubnet(hubVnetAddressPrefix, 12, 0)
var hubSubnetInternal  = cidrSubnet(hubVnetAddressPrefix, 12, 16)
var hubSubnetMgmt      = cidrSubnet(hubVnetAddressPrefix, 8,  2)
var hubSubnetGateway   = cidrSubnet(hubVnetAddressPrefix, 11, 24)

// ── Derived Subnet CIDRs (from ingressVnetAddressPrefix) ──────────────
//   ingressSubnetExternal: /16 + 12 bits = /28, block 0 → e.g. 10.1.0.0/28
//   ingressSubnetDmz     : /16 +  8 bits = /24, block 1 → e.g. 10.1.1.0/24
var ingressSubnetExternal = cidrSubnet(ingressVnetAddressPrefix, 12, 0)
var ingressSubnetDmz      = cidrSubnet(ingressVnetAddressPrefix, 8,  1)

// ── Derived Static Host IPs ──────────────────────────────────────────
// Azure reserves .0–.3 in every subnet; first usable host = index 4
var checkpointInternalIp = cidrHost(hubSubnetInternal, 4)
var checkpointExternalIp = cidrHost(hubSubnetExternal, 4)

// ============================================================
// Resource Group
// ============================================================
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-connectivity-hub-australiaeast-001'
  location: location
  tags: tags
}

// ============================================================
// DDoS Protection Plan — Standard (DD34)
//
// A single DDoS Protection Plan is shared across both VNets.
// Cost note: DDoS Protection Standard is billed per plan per month
// plus per protected public IP. One plan can cover all VNets in
// the subscription.
// ============================================================
resource ddosProtectionPlan 'Microsoft.Network/ddosProtectionPlans@2023-09-01' = {
  name    : 'ddos-hub-australiaeast-001'
  location: location
  tags    : tags
  scope   : rg
  properties: {}
}

// ============================================================
// Public IPs
// ============================================================

// Checkpoint external NIC — public IP for internet egress via External LB
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

// NSG for Checkpoint external subnet (now on ingress VNet - DD31)
// FIX #30 — Added explicit Deny-All-Inbound rule (priority 4096)
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
          sourceAddressPrefixes: [onPremAddressSpace]   // On-prem only
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRanges: ['18190', '19009', '257', '8211']
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// FIX #30 — Added explicit Deny-All-Inbound rule (priority 4096)
module nsgCheckpointInternal 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'deploy-nsg-checkpoint-internal'
  scope: rg
  params: {
    name    : 'nsg-checkpoint-internal-001'
    location: location
    tags    : tags
    securityRules: [
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// NSG for DMZ subnet in ingress VNet
module nsgIngressDmz 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'deploy-nsg-ingress-dmz'
  scope: rg
  params: {
    name    : 'nsg-ingress-dmz-001'
    location: location
    tags    : tags
    securityRules: []
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// FIX #8 — NSG for management subnet
// Management jump hosts require RDP/SSH access from on-premises only.
// All other inbound traffic is explicitly denied.
module nsgManagement 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'deploy-nsg-management'
  scope: rg
  params: {
    name: 'nsg-management-001'
    location: location
    tags: tags
    securityRules: [
      {
        name: 'Allow-RDP-from-OnPrem'
        properties: {
          priority: 100
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: onPremAddressSpace
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Allow-SSH-from-OnPrem'
        properties: {
          priority: 110
          protocol: 'Tcp'
          access: 'Allow'
          direction: 'Inbound'
          sourceAddressPrefix: onPremAddressSpace
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '22'
        }
      }
      {
        name: 'Deny-All-Inbound'
        properties: {
          priority: 4096
          protocol: '*'
          access: 'Deny'
          direction: 'Inbound'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// Route Table — force all spoke default traffic via Checkpoint
// Next-hop = checkpointInternalIp (cidrHost(hubSubnetInternal, 4)) = Internal LB frontend IP (VMSS backend)
// FIX #23 — Renamed from udr-to-checkpoint-001 to rt-to-checkpoint-hub-001
//            (rt- prefix aligns with CAF naming convention for route tables)
// ============================================================
module routeTableSpoke 'br/public:avm/res/network/route-table:0.4.0' = {
  name: 'deploy-udr-to-checkpoint'
  scope: rg
  params: {
    name    : 'rt-to-checkpoint-hub-001'
    location: location
    tags    : tags
    routes  : [
      {
        name: 'route-default-to-checkpoint'
        properties: {
          addressPrefix   : '0.0.0.0/0'
          nextHopType     : 'VirtualAppliance'
          nextHopIpAddress: checkpointInternalIp   // Internal LB frontend static IP (VMSS cluster)
        }
      }
    ]
  }
}

// ============================================================
// Hub Virtual Network — egress / hybrid (DD31)
//
// This VNet connects to on-premises via ExpressRoute.
// The Checkpoint internal NIC (eth1) is here.
// External NIC (eth0) has MOVED to vnet-ingress-australiaeast-001.
// ============================================================
module hubVnet 'br/public:avm/res/network/virtual-network:0.5.2' = {
  name: 'deploy-hub-vnet'
  scope: rg
  params: {
    name           : 'vnet-hub-australiaeast-001'
    location       : location
    addressPrefixes: [hubVnetAddressPrefix]
    tags           : tags
    // DDoS Protection Standard (DD34)
    ddosProtectionPlanResourceId: ddosProtectionPlan.id
    subnets: [
      {
        // Checkpoint eth1 — internal / trusted. All spoke traffic enters here.
        // Static IP is assigned to the Internal LB frontend (cidrHost(hubSubnetInternal, 4)).
        name                         : 'snet-checkpoint-internal'
        addressPrefix                : hubSubnetInternal
        networkSecurityGroupResourceId: nsgCheckpointInternal.outputs.resourceId
      }
      {
        // Management jump hosts — reachable from on-prem via ER (no Bastion)
        // FIX #7  — UDR removed: management traffic (Azure platform, diagnostics,
        //           update services) must NOT be forced through Checkpoint NVA.
        // FIX #8  — NSG attached: restricts inbound to RDP/SSH from on-prem only.
        name                          : 'snet-management'
        addressPrefix                 : hubSubnetMgmt
        networkSecurityGroupResourceId: nsgManagement.outputs.resourceId
      }
      {
        // Reserved for ExpressRoute Gateway — no NSG or UDR permitted
        name         : 'GatewaySubnet'
        addressPrefix: hubSubnetGateway
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
  dependsOn: [ddosProtectionPlan]
}

// ============================================================
// Ingress Virtual Network — internet-facing / DMZ (DD31)
//
// This VNet hosts internet-facing workloads and Checkpoint eth0.
// Peered to hub VNet for traffic to flow through the NVA cluster.
// ============================================================
module ingressVnet 'br/public:avm/res/network/virtual-network:0.5.2' = {
  name: 'deploy-ingress-vnet'
  scope: rg
  params: {
    name           : 'vnet-ingress-australiaeast-001'
    location       : location
    addressPrefixes: [ingressVnetAddressPrefix]
    tags           : tags
    // DDoS Protection Standard (DD34)
    ddosProtectionPlanResourceId: ddosProtectionPlan.id
    subnets: [
      {
        // Checkpoint eth0 — external / internet-facing (moved from hub VNet - DD31)
        name                         : 'snet-checkpoint-external'
        addressPrefix                : ingressSubnetExternal
        networkSecurityGroupResourceId: nsgCheckpointExternal.outputs.resourceId
      }
      {
        // DMZ workloads — internet-facing applications behind Checkpoint
        name                         : 'snet-ingress-dmz'
        addressPrefix                : ingressSubnetDmz
        networkSecurityGroupResourceId: nsgIngressDmz.outputs.resourceId
        routeTableResourceId         : routeTableSpoke.outputs.resourceId
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
    // VNet peering: ingress → hub
    // Allow forwarded traffic so Checkpoint can route between VNets.
    // Hub side peering (hub → ingress) is defined on hubVnet below via
    // a separate peering resource to allow gateway transit.
    peerings: [
      {
        name                    : 'peer-ingress-to-hub'
        remoteVirtualNetworkResourceId: hubVnet.outputs.resourceId
        allowForwardedTraffic   : true
        allowVirtualNetworkAccess: true
        allowGatewayTransit     : false
        useRemoteGateways       : true   // ingress VNet uses hub ER gateway
      }
    ]
  }
  dependsOn: [ddosProtectionPlan, hubVnet]
}

// VNet peering: hub → ingress (must be a separate resource for gateway transit)
// FIX #14 — dependsOn [hubVnet, ingressVnet] is explicit here. The remoteVirtualNetwork.id
//            also references ingressVnet.outputs.resourceId, making the dependency implicit
//            as well. Both are present for clarity and correctness.
resource hubToIngressPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name: 'vnet-hub-australiaeast-001/peer-hub-to-ingress'
  scope: rg
  dependsOn: [hubVnet, ingressVnet]
  properties: {
    remoteVirtualNetwork: {
      id: ingressVnet.outputs.resourceId
    }
    allowVirtualNetworkAccess: true
    allowForwardedTraffic    : true
    allowGatewayTransit      : true    // hub VNet shares its ER gateway with ingress VNet
    useRemoteGateways        : false
  }
}

// ============================================================
// ExpressRoute Virtual Network Gateway (Zone-Redundant)
//
// DD23 — Active/Active BGP:
//   The AVM module br/public:avm/res/network/virtual-network-gateway:0.5.0
//   does not expose an 'activeActive' parameter directly.
//   To enable Active/Active mode:
//     1. Provision this gateway (Active/Standby by default)
//     2. Add a second PIP (pip-ergw-hub-002)
//     3. Enable via Portal: Gateway → Configuration → Active-active mode
//        or via CLI: az network vnet-gateway update --name ergw-hub-australiaeast-001
//                       --resource-group rg-connectivity-hub-australiaeast-001
//                       --set activeActive=true
//                       --public-ip-address pip-ergw-hub-001 pip-ergw-hub-002
//   Active/Active requires TWO public IPs and two BGP peers on the
//   on-premises CE router. Coordinate with network team before enabling.
//
// This gateway is deployed by IaC and waits for the manually-
// created ER circuit to be linked via the separate
// 03b-platform-er-connection workflow once the provider has
// provisioned the circuit.
// ============================================================
// FIX #11 — diagnosticSettings verified present and updated to include explicit name
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
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceId
        name               : 'diag-ergw-hub'
      }
    ]
  }
}

// ============================================================
// Checkpoint CloudGuard NVA — VM Scale Set (DD30)
//
// External NIC (eth0) → vnet-ingress-australiaeast-001 / snet-checkpoint-external
// Internal NIC (eth1) → vnet-hub-australiaeast-001    / snet-checkpoint-internal
// ============================================================
module checkpointVmss './modules/checkpoint-vmss.bicep' = {
  name: 'deploy-checkpoint-vmss'
  scope: rg
  params: {
    location               : location
    vmssName               : 'vmss-checkpoint-hub-001'
    vmSize                 : checkpointVmSize
    adminUsername          : checkpointAdminUsername
    adminPassword          : checkpointAdminPassword
    checkpointSku          : checkpointSku
    // eth0 — external NIC in ingress VNet (DD31: external moved to ingress VNet)
    externalSubnetId       : '${ingressVnet.outputs.resourceId}/subnets/snet-checkpoint-external'
    // eth1 — internal NIC in hub VNet
    internalSubnetId       : '${hubVnet.outputs.resourceId}/subnets/snet-checkpoint-internal'
    externalPublicIpId       : checkpointExternalPip.outputs.resourceId
    logAnalyticsWorkspaceId  : logAnalyticsWorkspaceId
    instanceCount            : checkpointInstanceCount
    internalLbFrontendIp     : checkpointInternalIp
    checkpointExternalStaticIp: checkpointExternalIp
    tags                     : tags
  }
}

// ============================================================
// Outputs
// ============================================================
output hubVnetId              string = hubVnet.outputs.resourceId
output hubVnetName            string = hubVnet.outputs.name
output ingressVnetId          string = ingressVnet.outputs.resourceId
output ingressVnetName        string = ingressVnet.outputs.name
output checkpointInternalIp   string = checkpointInternalIp
output erGatewayId            string = erGateway.outputs.resourceId
output erGatewayName          string = 'ergw-hub-australiaeast-001'
// FIX #23 — routeTableId now reflects the renamed rt-to-checkpoint-hub-001 resource
output routeTableId           string = routeTableSpoke.outputs.resourceId
output resourceGroupId        string = rg.id
output ddosProtectionPlanId   string = ddosProtectionPlan.id
// NOTE: erCircuitId is NOT output here — the circuit is created manually.
// After manual creation, copy the circuit resource ID and use it in
// the 03b-platform-er-connection workflow.

// ============================================================
// Resource Lock — Hub Connectivity (CanNotDelete)
// Protects the hub VNet, ER Gateway, Checkpoint VMSS, and all
// associated networking resources from accidental deletion.
// ============================================================
resource hubConnectivityLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableResourceLocks) {
  name: 'lock-hub-connectivity-cannotdelete'
  scope: rg
  properties: {
    level: 'CanNotDelete'
    notes: 'Hub connectivity resources — deletion requires Platform Architecture Board approval. Raise an RFC before removing this lock.'
  }
  dependsOn: [hubVnet, ingressVnet, erGateway, checkpointVmss]
}

output resourceLockId string = enableResourceLocks ? hubConnectivityLock.id : ''
