targetScope = 'subscription'

// ============================================================
// Azure Landing Zone - Logging & Monitoring (Management Subscription)
// Region: Australia East
// Compliance: APRA CPS 234, Australian ISM, Essential Eight ML2
// ============================================================

@description('Azure region for all resources')
param location string = 'australiaeast'

@description('Log Analytics workspace name')
param logAnalyticsWorkspaceName string = 'law-management-australiaeast-001'

@description('Log Analytics SKU')
param logAnalyticsSku string = 'PerGB2018'

@description('Automation account name')
param automationAccountName string = 'aa-management-australiaeast-001'

@description('Resource tags')
param tags object = {
  environment: 'management'
  managedBy: 'platform-team'
  createdBy: 'alz-bicep'
}

// ---- CMK / Immutability params (populated post security module deploy) ----

@description('Key Vault URI for Customer-Managed Key encryption of Log Analytics workspace')
param keyVaultUri string = ''

@description('Key Vault resource ID for Customer-Managed Key encryption of Log Analytics workspace')
param keyVaultResourceId string = ''

@description('Customer-Managed Key name in Key Vault for Log Analytics encryption')
param cmkKeyName string = 'law-cmk-key'

@description('Enable immutable log retention (WORM) via data export to the platform immutable storage account')
param enableImmutableLogs bool = true

@description('Immutable storage account resource ID (from platform/security module output)')
param immutableStorageAccountId string = ''

@description('Log retention period in days (minimum 365 for APRA CPS 234 / ISM compliance)')
@minValue(365)
param retentionInDays int = 365

// ── Effective Tags — merges caller-supplied tags with mandatory platform tags ──
// Mandatory tags are always applied regardless of what the caller passes.
// This ensures compliance with the require-tags-on-rg policy (GOV-02).
var effectiveTags = union(tags, {
  managedBy : 'platform-team'
  createdBy : 'alz-bicep'
  deployedAt: utcNow('yyyy-MM-dd')   // Deployment timestamp for audit trail
})

// ---- Resource Group ----
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-management-logging-001'
  location: location
  tags: effectiveTags
}

// ============================================================
// Managed Identity for Log Analytics → Key Vault CMK access
// The identity is granted 'Key Vault Crypto User' role on the
// platform Key Vault by the 06-platform-security pipeline
// post-deploy step (az role assignment create).
// ============================================================
resource lawManagedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-law-cmk-aue-001'
  location: location
  tags: effectiveTags
}

// ---- Log Analytics Workspace ----
module logAnalytics 'br/public:avm/res/operational-insights/workspace:0.9.0' = {
  name: 'deploy-law'
  scope: rg
  params: {
    name: logAnalyticsWorkspaceName
    location: location
    skuName: logAnalyticsSku
    dataRetention: retentionInDays
    tags: effectiveTags
    linkedStorageAccounts: []

    // Workspace-level access control — require explicit table/resource permissions.
    // Prevents broad workspace-reader access from seeing all table data.
    // (Essential Eight ML2 — restrict administrative privileges)
    features: {
      enableLogAccessUsingOnlyResourcePermissions: true
    }

    // Customer-Managed Key — only applied once keyVaultResourceId is supplied
    // (post security module deploy). When empty the workspace uses
    // Microsoft-managed keys during initial bootstrap.
    customerManagedKey: empty(keyVaultResourceId) ? null : {
      keyVaultResourceId: keyVaultResourceId
      keyName: cmkKeyName
      userAssignedIdentityResourceId: lawManagedIdentity.id
    }

    gallerySolutions: [
      {
        name: 'SecurityInsights'
        plan: {
          name: 'SecurityInsights(${logAnalyticsWorkspaceName})'
          product: 'OMSGallery/SecurityInsights'
          publisher: 'Microsoft'
        }
      }
      {
        name: 'Updates'
        plan: {
          name: 'Updates(${logAnalyticsWorkspaceName})'
          product: 'OMSGallery/Updates'
          publisher: 'Microsoft'
        }
      }
      {
        name: 'ChangeTracking'
        plan: {
          name: 'ChangeTracking(${logAnalyticsWorkspaceName})'
          product: 'OMSGallery/ChangeTracking'
          publisher: 'Microsoft'
        }
      }
    ]
  }
}

// ============================================================
// Log Analytics Data Export → Immutable Storage (WORM)
// Exports security-critical tables to the geo-redundant immutable
// storage account deployed by the platform/security module.
// APRA CPS 234 s.47: audit records must be tamper-evident.
// Only activated when enableImmutableLogs = true AND
// immutableStorageAccountId is supplied (post security deploy).
// ============================================================
resource lawDataExport 'Microsoft.OperationalInsights/workspaces/dataExports@2020-08-01' = if (enableImmutableLogs && !empty(immutableStorageAccountId)) {
  name: '${logAnalyticsWorkspaceName}/export-to-immutable-storage'
  dependsOn: [ logAnalytics ]
  properties: {
    destination: {
      resourceId: immutableStorageAccountId
    }
    tableNames: [
      'SecurityEvent'
      'AzureActivity'
      'SigninLogs'
      'AuditLogs'
      'CommonSecurityLog'
    ]
    enabled: true
  }
}

// ---- Automation Account ----
module automationAccount 'br/public:avm/res/automation/automation-account:0.11.0' = {
  name: 'deploy-automation-account'
  scope: rg
  params: {
    name: automationAccountName
    location: location
    skuName: 'Basic'
    tags: effectiveTags
    linkedWorkspace: {
      id: logAnalytics.outputs.resourceId
    }
    // Security hardening — system-assigned managed identity replaces RunAs accounts.
    // No service principal secrets stored in the Automation Account.
    // (Essential Eight ML2 — restrict administrative privileges / no standing secrets)
    managedIdentities: {
      systemAssigned: true
    }
    // Disable public network access — management plane access via private endpoint only.
    // Runbook workers communicate over the private link service.
    publicNetworkAccess: 'Disabled'
    // Diagnostic settings — route job logs, DSC node status and audit events to
    // the central Log Analytics workspace for Sentinel ingestion.
    diagnosticSettings: [
      {
        name: 'diag-aa-to-law'
        workspaceResourceId: logAnalytics.outputs.resourceId
        logCategoriesAndGroups: [
          { categoryGroup: 'allLogs' }
        ]
        metricCategories: [
          { category: 'AllMetrics' }
        ]
      }
    ]
  }
}

// ---- Outputs ----
output logAnalyticsWorkspaceId string = logAnalytics.outputs.resourceId
output logAnalyticsWorkspaceName string = logAnalytics.outputs.name
output automationAccountId string = automationAccount.outputs.resourceId
output resourceGroupId string = rg.id
// Managed identity outputs — consumed by 06-platform-security post-deploy step
// to grant 'Key Vault Crypto User' role assignment.
output lawManagedIdentityId string = lawManagedIdentity.id
output lawManagedIdentityPrincipalId string = lawManagedIdentity.properties.principalId
// Automation Account system-assigned MI principal — grant runbook permissions post-deploy
output automationAccountPrincipalId string = automationAccount.outputs.systemAssignedMIPrincipalId
