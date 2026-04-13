// NOTE: This is the LEGACY single-VM module. Use checkpoint-vmss.bicep for production deployments (DD30).
// ============================================================
// Checkpoint CloudGuard Network Security - Hub NVA Module
// Deploys Checkpoint CloudGuard as NVA in the hub network
// ============================================================

@description('Azure region')
param location string

@description('Checkpoint VM name')
param vmName string = 'vm-checkpoint-hub-001'

@description('VM size - D3_v2 recommended for CloudGuard')
param vmSize string = 'Standard_D3_v2'

@description('Admin username')
param adminUsername string = 'azureadmin'

@secure()
@description('Admin password')
param adminPassword string

@description('Checkpoint marketplace SKU: sg-byol | sg-ngtp | sg-ngtx')
@allowed(['sg-byol', 'sg-ngtp', 'sg-ngtx'])
param checkpointSku string = 'sg-byol'

@description('External subnet resource ID')
param externalSubnetId string

@description('Internal subnet resource ID')
param internalSubnetId string

@description('External public IP resource ID')
param externalPublicIpId string

@description('Static private IP for the external NIC (eth0). Derived from ingressVnetAddressPrefix in the parent template using cidrHost(). Caller must provide — no default.')
param externalStaticIp string

@description('Static private IP for the internal NIC (eth1). Derived from hubVnetAddressPrefix in the parent template using cidrHost(). Caller must provide — no default.')
param internalStaticIp string

@description('Log Analytics workspace ID for boot diagnostics storage')
param logAnalyticsWorkspaceId string

@description('Resource tags')
param tags object = {}

// ---- Storage Account for Boot Diagnostics ----
resource bootDiagStorageAccount 'Microsoft.Storage/storageAccounts@2023-01-01' = {
  name: 'stchkpdiag${uniqueString(resourceGroup().id)}'
  location: location
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  tags: tags
}

// ---- Availability Set ----
resource availabilitySet 'Microsoft.Compute/availabilitySets@2023-07-01' = {
  name: 'avset-checkpoint-001'
  location: location
  tags: tags
  sku: {
    name: 'Aligned'
  }
  properties: {
    platformFaultDomainCount: 2
    platformUpdateDomainCount: 5
  }
}

// ---- External NIC (eth0) ----
resource externalNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${vmName}-nic-external'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig-external'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Static'
          privateIPAddress: externalStaticIp
          subnet: {
            id: externalSubnetId
          }
          publicIPAddress: {
            id: externalPublicIpId
          }
        }
      }
    ]
  }
}

// ---- Internal NIC (eth1) ----
resource internalNic 'Microsoft.Network/networkInterfaces@2023-09-01' = {
  name: '${vmName}-nic-internal'
  location: location
  tags: tags
  properties: {
    enableIPForwarding: true
    enableAcceleratedNetworking: true
    ipConfigurations: [
      {
        name: 'ipconfig-internal'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Static'
          privateIPAddress: internalStaticIp
          subnet: {
            id: internalSubnetId
          }
        }
      }
    ]
  }
}

// ---- Checkpoint CloudGuard VM ----
resource checkpointVm 'Microsoft.Compute/virtualMachines@2023-07-01' = {
  name: vmName
  location: location
  tags: tags
  plan: {
    name: checkpointSku
    publisher: 'checkpoint'
    product: 'check-point-cg-r8110'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    availabilitySet: {
      id: availabilitySet.id
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      linuxConfiguration: {
        disablePasswordAuthentication: false
        provisionVMAgent: true
      }
      // Checkpoint first-time boot configuration
      customData: base64('''
#cloud-config
# Checkpoint CloudGuard initial configuration
# Complete setup via SmartConsole or management API after deployment
''')
    }
    storageProfile: {
      imageReference: {
        publisher: 'checkpoint'
        offer: 'check-point-cg-r8110'
        sku: checkpointSku
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        caching: 'ReadWrite'
        createOption: 'FromImage'
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
        diskSizeGB: 100
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: externalNic.id
          properties: {
            primary: true
          }
        }
        {
          id: internalNic.id
          properties: {
            primary: false
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
        storageUri: bootDiagStorageAccount.properties.primaryEndpoints.blob
      }
    }
  }
}

// ---- Outputs ----
output checkpointVmId string = checkpointVm.id
output checkpointVmName string = checkpointVm.name
output externalNicId string = externalNic.id
output internalNicId string = internalNic.id
output checkpointInternalPrivateIp string = internalStaticIp
output checkpointExternalPrivateIp string = externalStaticIp
