targetScope = 'subscription'

// ============================================================
// Azure Landing Zone — Platform Security
// Region: Australia East
// Compliance: APRA CPS 234, Australian ISM, Essential Eight ML2
//
// Deploys:
//   • Platform Key Vault (Premium / HSM-backed) with private endpoint
//   • Diagnostic Storage Account (immutable WORM — 365-day retention)
//   • Resource lock (CanNotDelete) on the security resource group
//
// Run AFTER: 02-logging (need LAW ID), 03-connectivity (need VNet/subnet IDs)
// ============================================================

// ============================================================
// Parameters
// ============================================================

@description('Azure region for all resources')
param location string = 'australiaeast'

@description('Hub VNet resource ID — used for private endpoint placement and network ACL allow-list')
param hubVnetId string

@description('Management subnet resource ID — private endpoint NICs will be placed here')
param managementSubnetId string

@description('Log Analytics workspace resource ID for diagnostic settings')
param logAnalyticsWorkspaceId string

@description('Azure AD tenant ID for Key Vault')
param tenantId string = tenant().tenantId

@description('Enable CanNotDelete resource locks on critical platform resources')
param enableResourceLocks bool = true

@description('Resource tags applied to all resources')
param tags object

// ============================================================
// Variables
// ============================================================

var rgName                   = 'rg-security-platform-001'
var keyVaultName             = 'kv-platform-sec-aue-001'
// Storage account names must be <=24 chars, lowercase, alphanumeric only.
// uniqueString returns 13 hex chars; prefix 'stplatlogimm' = 13 chars → 26 — trim prefix to 11.
var storageAccountName       = 'stplatlogimm${take(uniqueString(subscription().subscriptionId), 11)}'
var kvPrivateEndpointName    = 'pe-kv-platform-sec-aue-001'
var stPrivateEndpointName    = 'pe-st-platform-sec-aue-001'

// ============================================================
// Resource Group
// ============================================================

resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: rgName
  location: location
  tags: tags
}

// ============================================================
// 1. Platform Key Vault
//    SKU: Premium (HSM-backed keys)
//    RBAC authorisation, soft-delete 90 days, purge-protection ON
//    Network ACLs: default Deny — bypass AzureServices, private endpoint only
// ============================================================

module keyVault 'br/public:avm/res/key-vault/vault:0.9.0' = {
  name: 'deploy-platform-keyvault'
  scope: rg
  params: {
    name: keyVaultName
    location: location
    tags: tags
    sku: 'premium'
    tenantId: tenantId

    // Soft-delete and purge protection (APRA CPS 234 — data recovery)
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true

    // Use RBAC, not legacy access policies (Essential Eight — least privilege)
    enableRbacAuthorization: true

    // Network ACLs — default Deny; allow Azure platform services; data plane
    // access via private endpoint only (Australian ISM — network segmentation)
    networkAcls: {
      defaultAction: 'Deny'
      bypass: 'AzureServices'
      ipRules: []
      virtualNetworkRules: []
    }

    // Diagnostic settings → central Log Analytics workspace
    diagnosticSettings: [
      {
        name: 'diag-kv-platform-sec'
        workspaceResourceId: logAnalyticsWorkspaceId
        logCategoriesAndGroups: [
          { categoryGroup: 'audit'   }
          { categoryGroup: 'allLogs' }
        ]
        metricCategories: [
          { category: 'AllMetrics' }
        ]
      }
    ]

    // Private endpoint — places NIC in management subnet of hub VNet
    privateEndpoints: [
      {
        name: kvPrivateEndpointName
        subnetResourceId: managementSubnetId
        groupIds: [ 'vault' ]
        service: 'vault'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              // Zone must already exist — deployed by 03-connectivity private-dns module
              privateDnsZoneResourceId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/rg-connectivity-hub-001/providers/Microsoft.Network/privateDnsZones/privatelink.vaultcore.azure.net'
            }
          ]
        }
        tags: tags
      }
    ]
  }
}

// ============================================================
// POST-DEPLOY: Create these secrets manually in the Key Vault
// after this pipeline completes and RBAC assignments are in place:
//
//   checkpoint-admin-password  — Checkpoint CloudGuard NVA admin password
//   automation-account-key     — Automation account webhook key (if needed)
//
// Access: grant 'Key Vault Secrets User' role to the relevant
//         managed identities via RBAC (not access policies).
// ============================================================

// ============================================================
// 2. Diagnostic Storage Account
//    Geo-redundant (Standard_GRS), immutable WORM blob policy (365 days)
//    No public access, HTTPS only, TLS 1.2 minimum
//    Private endpoint in management subnet
// ============================================================

module diagnosticStorage 'br/public:avm/res/storage/storage-account:0.14.0' = {
  name: 'deploy-platform-diag-storage'
  scope: rg
  params: {
    name: storageAccountName
    location: location
    tags: tags
    skuName: 'Standard_GRS'
    kind: 'StorageV2'

    // Security hardening (Australian ISM control: data-in-transit encryption)
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    minimumTlsVersion: 'TLS1_2'

    // Disable anonymous access at account level
    allowSharedKeyAccess: false

    blobServices: {
      // Immutability policy on the container is applied below via
      // Microsoft.Storage/storageAccounts/immutabilityPolicies.
      // The AVM module wires up the service-level properties here.
      deleteRetentionPolicyEnabled: true
      deleteRetentionPolicyDays: 365
      containerDeleteRetentionPolicyEnabled: true
      containerDeleteRetentionPolicyDays: 365
    }

    // Diagnostic settings for the storage account itself
    diagnosticSettings: [
      {
        name: 'diag-st-platform-sec'
        workspaceResourceId: logAnalyticsWorkspaceId
        logCategoriesAndGroups: [
          { categoryGroup: 'audit' }
        ]
        metricCategories: [
          { category: 'Transaction' }
        ]
      }
    ]

    // Private endpoint — blob sub-resource only (audit logs are blobs)
    privateEndpoints: [
      {
        name: stPrivateEndpointName
        subnetResourceId: managementSubnetId
        groupIds: [ 'blob' ]
        service: 'blob'
        privateDnsZoneGroup: {
          privateDnsZoneGroupConfigs: [
            {
              privateDnsZoneResourceId: '/subscriptions/${subscription().subscriptionId}/resourceGroups/rg-connectivity-hub-001/providers/Microsoft.Network/privateDnsZones/privatelink.blob.core.windows.net'
            }
          ]
        }
        tags: tags
      }
    ]
  }
}

// ============================================================
// Blob immutability policy — WORM (Write Once Read Many)
// APRA CPS 234 s.47: audit records must not be modifiable.
// 365 days, no protected append writes → fully locked after lock.
// ============================================================

resource immutabilityPolicy 'Microsoft.Storage/storageAccounts/immutabilityPolicies@2023-05-01' = {
  // Implicit dependency — storage account must exist first
  name: '${storageAccountName}/default'
  dependsOn: [ diagnosticStorage ]
  properties: {
    immutabilityPeriodSinceCreationInDays: 365
    allowProtectedAppendWrites: false
  }
}

// ============================================================
// 3. Resource Locks — CanNotDelete
//    Protect the security resource group from accidental deletion.
//    (Australian ISM control: system resilience / change management)
// ============================================================

module rgLock 'modules/resource-lock.bicep' = if (enableResourceLocks) {
  name: 'deploy-rg-security-lock'
  scope: rg
  params: {
    lockName: 'lock-rg-security-platform-cannotdelete'
    notes: 'Platform Security resource group — CanNotDelete lock applied by ALZ Bicep pipeline. Removal requires Platform Architecture Board approval.'
  }
  dependsOn: [
    keyVault
    diagnosticStorage
  ]
}

// ============================================================
// Outputs — consumed by downstream pipelines (06 → 02-logging CMK)
// ============================================================

output keyVaultId string = keyVault.outputs.resourceId
output keyVaultName string = keyVault.outputs.name
output keyVaultUri string = keyVault.outputs.uri
output immutableStorageAccountId string = diagnosticStorage.outputs.resourceId
output securityResourceGroupId string = rg.id
