// ============================================================
// Checkpoint CloudGuard NVA — VM Scale Set (DD30)
//
// Replaces single-instance checkpoint-nva.bicep with a
// clustered VMSS deployment.
//
// Design decisions implemented:
//   DD30 — Checkpoint VMSS with 2+ instances
//
// Architecture:
//   • External LB  — outbound internet traffic (uses existing PIP)
//   • Internal LB  — inbound/spoke traffic, static frontend IP
//                    10.0.1.4 (matches UDR next-hop convention)
//   • VMSS         — dual-NIC, IP forwarding, Manual upgrade policy
//
// NIC layout:
//   nic-0  (eth0) → externalSubnet  → External LB backend pool
//   nic-1  (eth1) → internalSubnet  → Internal LB backend pool
//
// IMPORTANT: Checkpoint CloudGuard requires Manual upgrade policy.
//            Never set Automatic or Rolling — the NVA handles its
//            own software updates via SmartConsole / CPUSE.
// ============================================================

@description('Azure region')
param location string

@description('VM Scale Set name')
param vmssName string = 'vmss-checkpoint-hub-001'

@description('VM size — D3_v2 is Checkpoint-certified minimum for CloudGuard')
param vmSize string = 'Standard_D3_v2'

@description('Admin username')
param adminUsername string = 'azureadmin'

@secure()
@description('Admin password')
param adminPassword string

@description('Checkpoint marketplace SKU: sg-byol | sg-ngtp | sg-ngtx')
@allowed(['sg-byol', 'sg-ngtp', 'sg-ngtx'])
param checkpointSku string = 'sg-byol'

@description('External subnet resource ID — Checkpoint eth0 (internet-facing)')
param externalSubnetId string

@description('Internal subnet resource ID — Checkpoint eth1 (trusted/spoke side)')
param internalSubnetId string

@description('External public IP resource ID — attached to External LB for outbound SNAT')
param externalPublicIpId string

@description('Log Analytics workspace resource ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('Number of Checkpoint instances. Minimum 2 for HA (use 1 for PEZ reduced footprint).')
@minValue(1)
param instanceCount int = 2

@description('Resource tags')
param tags object = {}

// ============================================================
// Boot Diagnostics Storage Account
// ============================================================
resource bootDiagStorageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'st${replace(vmssName, '-', '')}${uniqueString(resourceGroup().id)}'
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  tags: tags
}

// ============================================================
// Internal Load Balancer
// Frontend: static IP 10.0.1.4 on the internal subnet
// This IP matches the UDR next-hop used by spoke route tables.
// ============================================================
resource internalLb 'Microsoft.Network/loadBalancers@2023-09-01' = {
  name: 'lbi-checkpoint-internal-001'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe-checkpoint-internal'
        properties: {
          // Static IP — must match nextHopIpAddress in spoke UDRs
          privateIPAddress: '10.0.1.4'
          privateIPAllocationMethod: 'Static'
          subnet: {
            id: internalSubnetId
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'be-checkpoint-internal'
      }
    ]
    loadBalancingRules: [
      {
        name: 'rule-all-traffic'
        properties: {
          // HA Ports rule — forward ALL TCP/UDP ports to NVA cluster
          protocol: 'All'
          frontendPort: 0
          backendPort: 0
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations',
                            'lbi-checkpoint-internal-001', 'fe-checkpoint-internal')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools',
                            'lbi-checkpoint-internal-001', 'be-checkpoint-internal')
          }
          probe: {
            id: resourceId('Microsoft.Network/loadBalancers/probes',
                            'lbi-checkpoint-internal-001', 'probe-checkpoint-health')
          }
          enableFloatingIP: true
          idleTimeoutInMinutes: 4
          disableOutboundSnat: true
        }
      }
    ]
    probes: [
      {
        name: 'probe-checkpoint-health'
        properties: {
          // Port 8117 — Checkpoint management health probe port
          protocol: 'Tcp'
          port: 8117
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
  }
}

// Diagnostics for Internal LB
resource internalLbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-lbi-checkpoint-internal-001'
  scope: internalLb
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
  }
}

// ============================================================
// External Load Balancer
// Frontend: existing public IP (outbound internet SNAT for VMSS)
// VMSS instances have no direct PIP — all outbound goes via LBe.
// ============================================================
resource externalLb 'Microsoft.Network/loadBalancers@2023-09-01' = {
  name: 'lbe-checkpoint-external-001'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
    tier: 'Regional'
  }
  properties: {
    frontendIPConfigurations: [
      {
        name: 'fe-checkpoint-external'
        properties: {
          publicIPAddress: {
            id: externalPublicIpId
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'be-checkpoint-external'
      }
    ]
    // No inbound LB rules — external LB is for outbound SNAT only.
    // Inbound internet traffic is handled by Checkpoint firewall policy.
    loadBalancingRules: []
    probes: [
      {
        name: 'probe-checkpoint-external-health'
        properties: {
          protocol: 'Tcp'
          port: 8117
          intervalInSeconds: 5
          numberOfProbes: 2
        }
      }
    ]
    outboundRules: [
      {
        name: 'outbound-checkpoint-snat'
        properties: {
          protocol: 'All'
          idleTimeoutInMinutes: 4
          allocatedOutboundPorts: 0    // 0 = automatic port allocation
          frontendIPConfigurations: [
            {
              id: resourceId('Microsoft.Network/loadBalancers/frontendIPConfigurations',
                              'lbe-checkpoint-external-001', 'fe-checkpoint-external')
            }
          ]
          backendAddressPool: {
            id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools',
                            'lbe-checkpoint-external-001', 'be-checkpoint-external')
          }
        }
      }
    ]
  }
}

// Diagnostics for External LB
resource externalLbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-lbe-checkpoint-external-001'
  scope: externalLb
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
  }
}

// ============================================================
// Checkpoint CloudGuard VM Scale Set
//
// Key NVA-specific settings:
//   overprovision: false    — NVAs must not overprovision; extra
//                             instances would create asymmetric routing
//   upgradePolicy: Manual   — Checkpoint manages its own software via
//                             CPUSE / SmartConsole; never auto-upgrade
//   singlePlacementGroup: false — allows >100 instance scale-out
//   platformFaultDomainCount: 1 — spread across update domains within
//                             the single placement group (AZ handles FD)
// ============================================================
resource checkpointVmss 'Microsoft.Compute/virtualMachineScaleSets@2023-07-01' = {
  name: vmssName
  location: location
  tags: tags
  plan: {
    name     : checkpointSku
    publisher: 'checkpoint'
    product  : 'check-point-cg-r8110'
  }
  sku: {
    name    : vmSize
    tier    : 'Standard'
    capacity: instanceCount
  }
  properties: {
    overprovision      : false   // NVA requirement — see header comment
    singlePlacementGroup: false  // allows scale beyond 100 instances
    upgradePolicy: {
      mode: 'Manual'             // Checkpoint CPUSE manages its own upgrades
    }
    // Platform fault domains — use 1 to co-locate with AZ selection
    // When deployed in AZ-enabled regions, the AZ parameter on each
    // instance provides fault isolation.
    platformFaultDomainCount: 1
    virtualMachineProfile: {
      priority: 'Regular'
      osProfile: {
        computerNamePrefix: take(replace(vmssName, '-', ''), 9)
        adminUsername: adminUsername
        adminPassword: adminPassword
        linuxConfiguration: {
          disablePasswordAuthentication: false
          provisionVMAgent: true
        }
        // Checkpoint CloudGuard cloud-init — complete configuration via
        // SmartConsole or management API after deployment
        customData: base64('''
#cloud-config
# Checkpoint CloudGuard VMSS initial configuration
# After all instances are healthy:
#   1. Connect to SmartConsole and add each gateway
#   2. Configure ClusterXL (Active/Standby or Load Sharing)
#   3. Push policy
''')
      }
      storageProfile: {
        imageReference: {
          publisher: 'checkpoint'
          offer    : 'check-point-cg-r8110'
          sku      : checkpointSku
          version  : 'latest'
        }
        osDisk: {
          caching      : 'ReadWrite'
          createOption : 'FromImage'
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
          diskSizeGB: 100
        }
      }
      // Dual-NIC layout:
      //   networkInterfaceConfigurations[0] = eth0 (external, primary)
      //   networkInterfaceConfigurations[1] = eth1 (internal)
      networkProfile: {
        networkInterfaceConfigurations: [
          {
            // eth0 — External NIC (internet-facing)
            name: '${vmssName}-nic-external'
            properties: {
              primary                    : true
              enableIPForwarding         : true   // Required for NVA routing
              enableAcceleratedNetworking: true
              ipConfigurations: [
                {
                  name: 'ipconfig-external'
                  properties: {
                    primary: true
                    privateIPAddressVersion: 'IPv4'
                    subnet: {
                      id: externalSubnetId
                    }
                    // No direct PIP on instances — outbound via External LB SNAT rule
                    loadBalancerBackendAddressPools: [
                      {
                        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools',
                                        'lbe-checkpoint-external-001', 'be-checkpoint-external')
                      }
                    ]
                  }
                }
              ]
            }
          }
          {
            // eth1 — Internal NIC (trusted/spoke side)
            name: '${vmssName}-nic-internal'
            properties: {
              primary                    : false
              enableIPForwarding         : true   // Required for NVA routing
              enableAcceleratedNetworking: true
              ipConfigurations: [
                {
                  name: 'ipconfig-internal'
                  properties: {
                    primary: true
                    privateIPAddressVersion: 'IPv4'
                    subnet: {
                      id: internalSubnetId
                    }
                    loadBalancerBackendAddressPools: [
                      {
                        id: resourceId('Microsoft.Network/loadBalancers/backendAddressPools',
                                        'lbi-checkpoint-internal-001', 'be-checkpoint-internal')
                      }
                    ]
                  }
                }
              ]
            }
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled   : true
          storageUri: bootDiagStorageAccount.properties.primaryEndpoints.blob
        }
      }
      extensionProfile: {
        extensions: []
      }
    }
  }
  dependsOn: [
    internalLb
    externalLb
  ]
}

// Diagnostics for VMSS
resource vmssDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'diag-${vmssName}'
  scope: checkpointVmss
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
@description('Static frontend IP of the Internal Load Balancer — always 10.0.1.4. Use this as the UDR next-hop in spoke route tables.')
output internalLoadBalancerFrontendIp string = '10.0.1.4'

@description('VM Scale Set resource ID')
output vmssId string = checkpointVmss.id

@description('VM Scale Set name')
output vmssName string = checkpointVmss.name

@description('Internal Load Balancer resource ID')
output internalLbId string = internalLb.id

@description('External Load Balancer resource ID')
output externalLbId string = externalLb.id
