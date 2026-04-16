targetScope = 'subscription'

// ============================================================
// Azure Landing Zone - Connectivity / Hub Networking
// Region        : Australia East
// Topology      : Hub & Spoke (Dual-VNet Security pattern)
// NVA           : Checkpoint CloudGuard — MANUAL DEPLOYMENT
// WAN Edge      : ExpressRoute
//
// Design decisions implemented:
//   DD31 — Dual Security VNet (hub/egress + ingress/DMZ VNets)
//   DD23 — BGP Active/Active note (see ER Gateway section)
//   DD34 — DDoS Protection Standard on both VNets
//
// VNet layout (default CIDRs — all subnets derived from params):
//   vnet-hub-australiaeast-001     hubVnetAddressPrefix (/16)  — egress / hybrid
//     snet-checkpoint-internal      cidrSubnet(/16, 12, 16)    — Checkpoint eth1 e.g. 10.0.1.0/28
//     snet-management               cidrSubnet(/16,  8,  2)    — jump hosts       e.g. 10.0.2.0/24
//     GatewaySubnet                 cidrSubnet(/16, 11, 24)    — ER Gateway        e.g. 10.0.3.0/27
//
//   vnet-ingress-australiaeast-001  ingressVnetAddressPrefix (/16)  — internet-facing / DMZ
//     snet-checkpoint-external      cidrSubnet(/16, 12,  0)    — Checkpoint eth0  e.g. 10.1.0.0/28
//     snet-ingress-dmz              cidrSubnet(/16,  8,  1)    — DMZ workloads    e.g. 10.1.1.0/24
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
//      into the pre-created subnets:
//        eth0 → snet-checkpoint-external  (vnet-ingress-australiaeast-001)
//        eth1 → snet-checkpoint-internal  (vnet-hub-australiaeast-001)
//   2. Assign the static Internal LB frontend IP = checkpointInternalIp output
//      (cidrHost of snet-checkpoint-internal, index 4)
//   3. Update the UDR (rt-to-checkpoint-hub-001) next-hop if the
//      actual NVA IP differs from the derived default.
//   4. Complete SmartConsole cluster configuration.
//      See: docs/checkpoint-first-boot.md
//
// NOTE — ExpressRoute circuit lifecycle:
//   The ER circuit itself is created MANUALLY by the network
//   team via Azure Portal or CLI (see docs/expressroute-setup.md).
//   This template deploys only the Azure-side infrastructure:
//     • Hub VNet + subnets + NSGs
//     • Ingress VNet + subnets + NSGs + VNet peering
//     • ExpressRoute Virtual Network Gateway (ErGw1AZ)
//     • Route Tables
//     • DDoS Protection Plan (Standard)
//   Once the circuit is manually created and the provider has
//   provisioned it, run the separate workflow:
//     03b-platform-er-connection  (links gateway → circuit)
// ============================================================

@description('Azure region')
param location string = 'australiaeast'

@description('Hub VNet address prefix (RFC1918 /16 recommended)')
@pattern('^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)[0-9.]+/[0-9]{1,2}$')
param hubVnetAddressPrefix string = '10.0.0.0/16'

@description('Ingress VNet address prefix (must not overlap with hub)')
@pattern('^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)[0-9.]+/[0-9]{1,2}$')
param ingressVnetAddressPrefix string = '10.1.0.0/16'

@description('Log Analytics workspace resource ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('ExpressRoute Gateway SKU. ErGw1AZ = zone-redundant 1 Gbps. Upgrade to ErGw2AZ for 10 Gbps.')
@allowed(['ErGw1AZ', 'ErGw2AZ', 'ErGw3AZ'])
param erGatewaySku string = 'ErGw1AZ'

@description('On-premises address space for NSG allow rules')
@pattern('^(10\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.|192\\.168\\.)[0-9.]+/[0-9]{1,2}$')
param onPremAddressSpace string = '10.0.0.0/8'

@description('Resource tags')
param tags object = {
  environment: 'connectivity'
  managedBy  : 'platform-team'
  createdBy  : 'alz-bicep'
}

@description('Apply CanNotDelete resource lock to the hub connectivity resource group.')
param enableResourceLocks bool = true

@description('Deploy Private DNS zones for PaaS services. Required when workloads use private endpoints.')
param deployPrivateDnsZones bool = true

// ── Effective Tags ────────────────────────────────────────────────────────────
var effectiveTags = union(tags, {
  managedBy : 'platform-team'
  createdBy : 'alz-bicep'
  deployedAt: utcNow('yyyy-MM-dd')
})

// ── Derived Subnet CIDRs (from hubVnetAddressPrefix) ──────────────────────────
// cidrSubnet(prefix, newbits, index) — all derived from /16 base:
//   hubSubnetInternal : /16 + 12 bits = /28, block 16 → e.g. 10.0.1.0/28
//   hubSubnetMgmt     : /16 +  8 bits = /24, block 2  → e.g. 10.0.2.0/24
//   hubSubnetGateway  : /16 + 11 bits = /27, block 24 → e.g. 10.0.3.0/27
var hubSubnetInternal  = cidrSubnet(hubVnetAddressPrefix, 12, 16)
var hubSubnetMgmt      = cidrSubnet(hubVnetAddressPrefix, 8,  2)
var hubSubnetGateway   = cidrSubnet(hubVnetAddressPrefix, 11, 24)

// ── Derived Subnet CIDRs (from ingressVnetAddressPrefix) ─────────────────────
//   ingressSubnetExternal: /16 + 12 bits = /28, block 0 → e.g. 10.1.0.0/28
//   ingressSubnetDmz     : /16 +  8 bits = /24, block 1 → e.g. 10.1.1.0/24
var ingressSubnetExternal = cidrSubnet(ingressVnetAddressPrefix, 12, 0)
var ingressSubnetDmz      = cidrSubnet(ingressVnetAddressPrefix, 8,  1)

// ── Reserved NVA IP — published as output for manual Checkpoint deployment ───
// Azure reserves .0–.3 in every subnet; first usable host = index 4.
// The network team should assign this IP to the Checkpoint Internal LB
// frontend when deploying the NVA manually.
var checkpointInternalIp = cidrHost(hubSubnetInternal, 4)

// ============================================================
// Resource Group
// ============================================================
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-connectivity-hub-australiaeast-001'
  location: location
  tags: effectiveTags
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
  tags    : effectiveTags
  scope   : rg
  properties: {}
}

// ============================================================
// Public IPs
// ============================================================

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
    tags                   : effectiveTags
    diagnosticSettings     : [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// ============================================================
// Network Security Groups
// ============================================================

// NSG for Checkpoint external subnet (ingress VNet — DD31)
// Permits internet HTTPS/HTTP inbound and on-prem Checkpoint management ports.
// Deny-All-Inbound at priority 4096 ensures no implicit permit.
// NOTE: Tighten or replace these rules once Checkpoint is deployed
//       and the actual traffic profile is known.
module nsgCheckpointExternal 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'deploy-nsg-checkpoint-external'
  scope: rg
  params: {
    name    : 'nsg-checkpoint-external-001'
    location: location
    tags    : effectiveTags
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
          sourceAddressPrefixes    : [onPremAddressSpace]   // On-prem only
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
  name: 'deploy-nsg-checkpoint-internal'
  scope: rg
  params: {
    name    : 'nsg-checkpoint-internal-001'
    location: location
    tags    : effectiveTags
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

// NSG for DMZ subnet in ingress VNet — permissive placeholder; tighten post-deployment
module nsgIngressDmz 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'deploy-nsg-ingress-dmz'
  scope: rg
  params: {
    name    : 'nsg-ingress-dmz-001'
    location: location
    tags    : effectiveTags
    securityRules: []
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
  }
}

// NSG for management subnet — RDP/SSH from on-premises only; all other inbound denied
module nsgManagement 'br/public:avm/res/network/network-security-group:0.5.0' = {
  name: 'deploy-nsg-management'
  scope: rg
  params: {
    name: 'nsg-management-001'
    location: location
    tags: effectiveTags
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
// Route Table — default route via Checkpoint NVA
//
// Next-hop IP = checkpointInternalIp (cidrHost of snet-checkpoint-internal, index 4).
// This is a PLACEHOLDER until Checkpoint is manually deployed.
// If the network team assigns a different Internal LB frontend IP,
// update the nextHopIpAddress value and re-run this pipeline.
// ============================================================
module routeTableSpoke 'br/public:avm/res/network/route-table:0.4.0' = {
  name: 'deploy-rt-to-checkpoint'
  scope: rg
  params: {
    name    : 'rt-to-checkpoint-hub-001'
    location: location
    tags    : effectiveTags
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
// Hub Virtual Network — egress / hybrid (DD31)
//
// Hosts Checkpoint eth1 (internal NIC) and the ER Gateway.
// Checkpoint VMs are deployed MANUALLY into snet-checkpoint-internal.
// ============================================================
module hubVnet 'br/public:avm/res/network/virtual-network:0.5.2' = {
  name: 'deploy-hub-vnet'
  scope: rg
  params: {
    name           : 'vnet-hub-australiaeast-001'
    location       : location
    addressPrefixes: [hubVnetAddressPrefix]
    tags           : effectiveTags
    ddosProtectionPlanResourceId: ddosProtectionPlan.id
    subnets: [
      {
        // Checkpoint eth1 — internal / trusted.
        // MANUAL: Deploy Checkpoint NVA into this subnet after pipeline completes.
        // Reserved Internal LB IP: see output 'checkpointInternalIp'.
        name                          : 'snet-checkpoint-internal'
        addressPrefix                 : hubSubnetInternal
        networkSecurityGroupResourceId: nsgCheckpointInternal.outputs.resourceId
      }
      {
        // Management jump hosts — reachable from on-prem via ER (no Bastion).
        // UDR intentionally omitted: management traffic must not traverse the NVA.
        name                          : 'snet-management'
        addressPrefix                 : hubSubnetMgmt
        networkSecurityGroupResourceId: nsgManagement.outputs.resourceId
      }
      {
        // Reserved for ExpressRoute Gateway — no NSG or UDR permitted by Azure.
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
// Hosts Checkpoint eth0 (external NIC) and DMZ workloads.
// Checkpoint VMs are deployed MANUALLY into snet-checkpoint-external.
// ============================================================
module ingressVnet 'br/public:avm/res/network/virtual-network:0.5.2' = {
  name: 'deploy-ingress-vnet'
  scope: rg
  params: {
    name           : 'vnet-ingress-australiaeast-001'
    location       : location
    addressPrefixes: [ingressVnetAddressPrefix]
    tags           : effectiveTags
    ddosProtectionPlanResourceId: ddosProtectionPlan.id
    subnets: [
      {
        // Checkpoint eth0 — external / internet-facing.
        // MANUAL: Deploy Checkpoint NVA into this subnet after pipeline completes.
        name                          : 'snet-checkpoint-external'
        addressPrefix                 : ingressSubnetExternal
        networkSecurityGroupResourceId: nsgCheckpointExternal.outputs.resourceId
      }
      {
        // DMZ workloads — internet-facing applications behind Checkpoint.
        // UDR forces egress through Checkpoint once the NVA is deployed.
        name                          : 'snet-ingress-dmz'
        addressPrefix                 : ingressSubnetDmz
        networkSecurityGroupResourceId: nsgIngressDmz.outputs.resourceId
        routeTableResourceId          : routeTableSpoke.outputs.resourceId
      }
    ]
    diagnosticSettings: [{ workspaceResourceId: logAnalyticsWorkspaceId }]
    peerings: [
      {
        name                           : 'peer-ingress-to-hub'
        remoteVirtualNetworkResourceId : hubVnet.outputs.resourceId
        allowForwardedTraffic          : true
        allowVirtualNetworkAccess      : true
        allowGatewayTransit            : false
        useRemoteGateways              : true   // ingress VNet uses hub ER gateway
      }
    ]
  }
  dependsOn: [ddosProtectionPlan, hubVnet]
}

// VNet peering: hub → ingress (separate resource required for gateway transit)
resource hubToIngressPeering 'Microsoft.Network/virtualNetworks/virtualNetworkPeerings@2023-09-01' = {
  name: 'vnet-hub-australiaeast-001/peer-hub-to-ingress'
  scope: rg
  dependsOn: [hubVnet, ingressVnet]
  properties: {
    remoteVirtualNetwork     : { id: ingressVnet.outputs.resourceId }
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
//   The AVM module does not expose an 'activeActive' parameter.
//   To enable Active/Active mode after deployment:
//     1. Add a second PIP (pip-ergw-hub-002)
//     2. Enable via CLI:
//        az network vnet-gateway update \
//          --name ergw-hub-australiaeast-001 \
//          --resource-group rg-connectivity-hub-australiaeast-001 \
//          --set activeActive=true \
//          --public-ip-address pip-ergw-hub-001 pip-ergw-hub-002
//   Coordinate with the network team — Active/Active requires two
//   BGP peers on the on-premises CE router.
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
    tags              : effectiveTags
    diagnosticSettings: [
      {
        workspaceResourceId: logAnalyticsWorkspaceId
        name               : 'diag-ergw-hub'
      }
    ]
  }
}

// ============================================================
// Private DNS Zones — 28 zones for PaaS private endpoints
// ============================================================
module privateDns './modules/private-dns.bicep' = if (deployPrivateDnsZones) {
  name: 'deploy-private-dns-zones'
  scope: rg
  params: {
    hubVnetId: hubVnet.outputs.resourceId
    location : location
    tags     : effectiveTags
  }
}

// ============================================================
// Resource Lock — Hub Connectivity (CanNotDelete)
// Protects the hub VNet, ER Gateway, and networking resources
// from accidental deletion.
// ============================================================
resource hubConnectivityLock 'Microsoft.Authorization/locks@2020-05-01' = if (enableResourceLocks) {
  name: 'lock-hub-connectivity-cannotdelete'
  scope: rg
  properties: {
    level: 'CanNotDelete'
    notes: 'Hub connectivity resources — deletion requires Platform Architecture Board approval. Raise an RFC before removing this lock.'
  }
  dependsOn: [hubVnet, ingressVnet, erGateway]
}

// ============================================================
// Outputs
// ============================================================
output hubVnetId          string = hubVnet.outputs.resourceId
output hubVnetName        string = hubVnet.outputs.name
output ingressVnetId      string = ingressVnet.outputs.resourceId
output ingressVnetName    string = ingressVnet.outputs.name
output erGatewayId        string = erGateway.outputs.resourceId
output erGatewayName      string = 'ergw-hub-australiaeast-001'
output routeTableId       string = routeTableSpoke.outputs.resourceId
output resourceGroupId    string = rg.id
output ddosProtectionPlanId string = ddosProtectionPlan.id
output resourceGroupName  string = rg.name
output resourceLockId     string = enableResourceLocks ? hubConnectivityLock.id : ''

// Subnet resource IDs — needed by downstream modules (security private endpoints, identity peering)
output managementSubnetId    string = '${hubVnet.outputs.resourceId}/subnets/snet-management'
output gatewaySubnetId       string = '${hubVnet.outputs.resourceId}/subnets/GatewaySubnet'
output internalSubnetId      string = '${hubVnet.outputs.resourceId}/subnets/snet-checkpoint-internal'
output externalSubnetId      string = '${ingressVnet.outputs.resourceId}/subnets/snet-checkpoint-external'
output ingressDmzSubnetId    string = '${ingressVnet.outputs.resourceId}/subnets/snet-ingress-dmz'

// Reserved NVA IP — network team should assign this to the Checkpoint Internal LB frontend
// when deploying the NVA manually. Matches the UDR next-hop in rt-to-checkpoint-hub-001.
output checkpointInternalIp  string = checkpointInternalIp

// NOTE: erCircuitId is NOT output here — the circuit is created manually.
// After manual creation, copy the circuit resource ID and use it in
// the 03b-platform-er-connection workflow.
