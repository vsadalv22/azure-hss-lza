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
// VNet layout:
//   vnet-hub-australiaeast-001     10.0.0.0/16  — egress / hybrid
//     snet-checkpoint-internal      10.0.1.0/28  — Checkpoint eth1
//     snet-management               10.0.2.0/24  — jump hosts
//     GatewaySubnet                 10.0.3.0/27  — ER Gateway
//
//   vnet-ingress-australiaeast-001  10.1.0.0/16  — internet-facing / DMZ
//     snet-checkpoint-external      10.1.0.0/28  — Checkpoint eth0
//     snet-ingress-dmz              10.1.1.0/24  — DMZ workloads
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

// ============================================================
// Route Table — force all spoke default traffic via Checkpoint
// Next-hop 10.0.1.4 = Internal LB frontend IP (VMSS backend)
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
          nextHopIpAddress: '10.0.1.4'   // Internal LB frontend static IP (VMSS cluster)
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
        // Static IP 10.0.1.4 is assigned to the Internal LB frontend.
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
        addressPrefix                : '10.1.0.0/28'
        networkSecurityGroupResourceId: nsgCheckpointExternal.outputs.resourceId
      }
      {
        // DMZ workloads — internet-facing applications behind Checkpoint
        name                         : 'snet-ingress-dmz'
        addressPrefix                : '10.1.1.0/24'
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
    externalPublicIpId     : checkpointExternalPip.outputs.resourceId
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    instanceCount          : checkpointInstanceCount
    tags                   : tags
  }
}

// ============================================================
// Outputs
// ============================================================
output hubVnetId              string = hubVnet.outputs.resourceId
output hubVnetName            string = hubVnet.outputs.name
output ingressVnetId          string = ingressVnet.outputs.resourceId
output ingressVnetName        string = ingressVnet.outputs.name
output checkpointInternalIp   string = checkpointVmss.outputs.internalLoadBalancerFrontendIp
output erGatewayId            string = erGateway.outputs.resourceId
output erGatewayName          string = 'ergw-hub-australiaeast-001'
output routeTableId           string = routeTableSpoke.outputs.resourceId
output resourceGroupId        string = rg.id
output ddosProtectionPlanId   string = ddosProtectionPlan.id
// NOTE: erCircuitId is NOT output here — the circuit is created manually.
// After manual creation, copy the circuit resource ID and use it in
// the 03b-platform-er-connection workflow.
