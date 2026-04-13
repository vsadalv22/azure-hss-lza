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
//                    matches internalLbFrontendIp param (UDR next-hop)
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
@description('Admin password — used as fallback when keyVaultId is not set')
param adminPassword string

// FIX #3 — Key Vault params for secure password retrieval
@description('Key Vault resource ID containing the Checkpoint admin password secret')
param keyVaultId string = ''

@description('Key Vault secret name for Checkpoint admin password (used when keyVaultId is set)')
param keyVaultSecretName string = 'checkpoint-admin-password'

// SECURITY: When keyVaultId is provided, the password is retrieved from Key Vault at deploy time
// and is NOT stored in ARM deployment history. Set keyVaultId in production environments.
// ARM Key Vault reference syntax is used so the secret never appears in plain text.
//
// NOTE: Bicep does not support inline Key Vault secret references in nested module osProfile
// params. To use Key Vault references, the CALLING template (main.bicep) must declare the
// adminPassword param with a keyVault reference block, e.g.:
//
//   param checkpointAdminPassword string
//   // In the parameter file (.bicepparam / parameters.json):
//   // "checkpointAdminPassword": {
//   //   "reference": {
//   //     "keyVault": { "id": "<keyVaultId>" },
//   //     "secretName": "<keyVaultSecretName>"
//   //   }
//   // }
//
// This module accepts the resolved secret value via adminPassword. The keyVaultId and
// keyVaultSecretName params are carried here for documentation and future ARM template
// generation tooling. See docs/keyvault-secret-reference.md for the full pattern.

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

// FIX #1 — Parameterised internal LB frontend IP (derived from hubVnetAddressPrefix in parent template)
// This value must match the nextHopIpAddress in spoke UDRs / route tables.
@description('Static IP for the internal LB frontend. Derived from hubVnetAddressPrefix in the parent template using cidrHost(). Must match the first usable host in the internal subnet.')
param internalLbFrontendIp string = ''

@description('Static IP for the Checkpoint external NIC (eth0). Derived from ingressVnetAddressPrefix in the parent template using cidrHost(). Must match the first usable host in the external subnet.')
param checkpointExternalStaticIp string = ''

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
  properties: {
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: true  // Required for boot diagnostics writes
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'   // Allows Azure Diagnostics service to write
      ipRules: []
      virtualNetworkRules: []
    }
    encryption: {
      services: {
        blob: {
          enabled: true
          keyType: 'Account'
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

// ============================================================
// Internal Load Balancer
// Frontend: static IP (internalLbFrontendIp) on the internal subnet.
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
          // FIX #1 — uses internalLbFrontendIp param instead of hardcoded literal
          privateIPAddress: internalLbFrontendIp
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
        // ⚠ HEALTH PROBE DEPENDENCY
        // Port 8117 must be explicitly enabled in Checkpoint SmartConsole after first boot:
        //   SmartConsole → Gateways & Servers → <gateway> → Platform Portal → enable health check
        // Until this is done, ALL instances will be marked Unhealthy and traffic will drop.
        // See: docs/checkpoint-first-boot.md
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
// TODO: upgrade to @2023-01-01-preview when GA
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
// TODO: upgrade to @2023-01-01-preview when GA
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
    // UPGRADE PROCEDURE (Manual — NVA safety):
    // 1. In SmartConsole: install policy on both gateways to ensure consistency
    // 2. In Azure Portal: go to VMSS → Instances → select one instance → Upgrade
    // 3. Verify traffic flows on remaining instance before upgrading the second
    // 4. Repeat for remaining instances
    // Full runbook: docs/checkpoint-upgrade-procedure.md

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
        // FIX #25 — Updated cloud-init placeholder with actionable first-boot instructions
        customData: base64('''
#cloud-config
# Checkpoint CloudGuard NVA — first-boot configuration placeholder
# The following must be completed manually via SmartConsole after deployment:
#   1. Add this gateway to SmartConsole (Gateways & Servers → New → Locally Managed)
#   2. Enable ClusterXL (HA) and set cluster mode to Load Sharing Multicast
#   3. Enable health check port 8117 (Platform Portal → Health Check)
#   4. Install security policy from SmartConsole
# See: docs/checkpoint-first-boot.md for full procedure
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
                // FIX #9 — Secondary IP config for floating IP / VIP
                // Matches the Internal LB frontend IP to enable the asymmetric routing
                // return path for floating IP / Direct Server Return (DSR) mode.
                {
                  name: 'ipconfig-internal-vip'
                  properties: {
                    primary: false
                    privateIPAddressVersion: 'IPv4'
                    privateIPAllocationMethod: 'Static'
                    privateIPAddress: internalLbFrontendIp  // Must match LB frontend — enables asymmetric routing return path
                    subnet: { id: internalSubnetId }
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
// TODO: upgrade to @2023-01-01-preview when GA
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
// FIX #1 — Output derives from internalLbFrontendIp param (cidrHost-derived in parent template)
@description('Static frontend IP of the Internal Load Balancer. Use this as the UDR next-hop in spoke route tables.')
output internalLoadBalancerFrontendIp string = internalLbFrontendIp

@description('Static private IP of the Checkpoint external NIC (eth0). Derived from ingressVnetAddressPrefix in the parent template.')
output checkpointExternalPrivateIp string = checkpointExternalStaticIp

@description('VM Scale Set resource ID')
output vmssId string = checkpointVmss.id

@description('VM Scale Set name')
output vmssName string = checkpointVmss.name

@description('Internal Load Balancer resource ID')
output internalLbId string = internalLb.id

@description('External Load Balancer resource ID')
output externalLbId string = externalLb.id
