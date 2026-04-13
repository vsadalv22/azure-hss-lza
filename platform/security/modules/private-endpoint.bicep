// ============================================================
// Reusable Module: Private Endpoint
// Scope: resourceGroup (caller must set scope: <rg> on the module)
//
// Creates a private endpoint NIC in the target subnet and
// optionally registers in one or more Private DNS zones.
//
// Usage:
//   module kvPe 'modules/private-endpoint.bicep' = {
//     name: 'deploy-pe-keyvault'
//     scope: rg
//     params: {
//       name: 'pe-kv-platform-sec-aue-001'
//       location: location
//       serviceResourceId: keyVault.outputs.resourceId
//       groupIds: [ 'vault' ]
//       subnetId: managementSubnetId
//       privateDnsZoneIds: [ kvPrivateDnsZoneId ]
//       tags: tags
//     }
//   }
// ============================================================

targetScope = 'resourceGroup'

@description('Private endpoint resource name')
param name string

@description('Azure region where the private endpoint NIC will be created')
param location string

@description('Resource ID of the PaaS service to connect to via Private Link')
param serviceResourceId string

@description('Private Link group IDs for the target service (e.g. [\'vault\'] for Key Vault, [\'blob\'] for Storage blob)')
param groupIds array

@description('Subnet resource ID where the private endpoint NIC will be placed. The subnet must have privateEndpointNetworkPolicies = Disabled.')
param subnetId string

@description('List of Private DNS zone resource IDs to register the endpoint in. Leave empty to skip DNS registration.')
param privateDnsZoneIds array = []

@description('Resource tags')
param tags object = {}

// ============================================================
// Private Endpoint
// ============================================================

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2023-09-01' = {
  name: name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: subnetId
    }
    privateLinkServiceConnections: [
      {
        name: name
        properties: {
          privateLinkServiceId: serviceResourceId
          groupIds: groupIds
        }
      }
    ]
  }
}

// ============================================================
// Private DNS Zone Group
// Registers the private endpoint IP with the supplied DNS zones
// so FQDNs resolve to the private IP inside the VNet.
// Only deployed when at least one zone ID is provided.
// ============================================================

resource privateDnsZoneGroups 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2023-09-01' = if (!empty(privateDnsZoneIds)) {
  name: 'default'
  parent: privateEndpoint
  properties: {
    privateDnsZoneConfigs: [for (zoneId, i) in privateDnsZoneIds: {
      name: 'config-${i}'
      properties: {
        privateDnsZoneId: zoneId
      }
    }]
  }
}

// ============================================================
// Outputs
// ============================================================

output privateEndpointId string = privateEndpoint.id
// The NIC is provisioned asynchronously; the array access is safe
// because Azure always creates exactly one NIC per private endpoint.
output privateEndpointNicId string = privateEndpoint.properties.networkInterfaces[0].id
