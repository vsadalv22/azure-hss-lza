// =============================================================
// Private DNS Zones — Hub Connectivity Subscription
// Centralised Private DNS for all spokes
// Zones cover all major Azure PaaS services used in Australia
// =============================================================

@description('Hub VNet resource ID — all zones linked to hub, spokes resolve via peering')
param hubVnetId string

@description('Log Analytics workspace ID for diagnostics')
param logAnalyticsWorkspaceId string

@description('Resource tags')
param tags object = {}

// =============================================================
// Private DNS zones for major Azure PaaS services
// =============================================================
var privateDnsZones = [
  // Storage
  'privatelink.blob.core.windows.net'
  'privatelink.file.core.windows.net'
  'privatelink.queue.core.windows.net'
  'privatelink.table.core.windows.net'
  'privatelink.dfs.core.windows.net'
  // Key Vault
  'privatelink.vaultcore.azure.net'
  // SQL / Database
  'privatelink.database.windows.net'
  'privatelink.mysql.database.azure.com'
  'privatelink.postgres.database.azure.com'
  'privatelink.mariadb.database.azure.com'
  // Cosmos DB
  'privatelink.documents.azure.com'
  'privatelink.mongo.cosmos.azure.com'
  // App Services / Functions
  'privatelink.azurewebsites.net'
  'privatelink.scm.azurewebsites.net'
  // Container Registry
  'privatelink.azurecr.io'
  // Service Bus / Event Hub
  'privatelink.servicebus.windows.net'
  'privatelink.eventhub.windows.net'
  // Azure Monitor / Log Analytics
  'privatelink.monitor.azure.com'
  'privatelink.oms.opinsights.azure.com'
  'privatelink.ods.opinsights.azure.com'
  'privatelink.agentsvc.azure-automation.net'
  // Backup
  'privatelink.australiaeast.backup.windowsazure.com'
  // Cognitive Services / AI
  'privatelink.cognitiveservices.azure.com'
  'privatelink.openai.azure.com'
  // Azure ML
  'privatelink.api.azureml.ms'
  'privatelink.notebooks.azure.net'
  // ACR / AKS
  'privatelink.australiaeast.azmk8s.io'
  // Graph / Management
  'privatelink.azure-api.net'
]

// =============================================================
// Deploy all private DNS zones + link to hub VNet
// =============================================================
resource privateDnsZoneResources 'Microsoft.Network/privateDnsZones@2020-06-01' = [for zone in privateDnsZones: {
  name: zone
  location: 'global'
  tags: tags
}]

resource privateDnsVnetLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2020-06-01' = [for (zone, i) in privateDnsZones: {
  name: 'link-hub'
  parent: privateDnsZoneResources[i]
  location: 'global'
  tags: tags
  properties: {
    virtualNetwork: {
      id: hubVnetId
    }
    registrationEnabled: false   // Private endpoints use manual registration
  }
}]

// =============================================================
// Outputs — zone IDs for spoke subscriptions to reference
// =============================================================
output privateDnsZoneIds object = reduce(
  map(range(0, length(privateDnsZones)), i => {
    key:   privateDnsZones[i]
    value: privateDnsZoneResources[i].id
  }),
  {},
  (cur, next) => union(cur, { '${next.key}': next.value })
)
