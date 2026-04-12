targetScope = 'subscription'

// ============================================================
// Azure Landing Zone - Logging & Monitoring (Management Subscription)
// Region: Australia East
// ============================================================

@description('Azure region for all resources')
param location string = 'australiaeast'

@description('Log Analytics workspace name')
param logAnalyticsWorkspaceName string = 'law-management-australiaeast-001'

@description('Log Analytics SKU')
param logAnalyticsSku string = 'PerGB2018'

@description('Retention in days')
param retentionInDays int = 365

@description('Automation account name')
param automationAccountName string = 'aa-management-australiaeast-001'

@description('Resource tags')
param tags object = {
  environment: 'management'
  managedBy: 'platform-team'
  createdBy: 'alz-bicep'
}

// ---- Resource Group ----
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-management-logging-001'
  location: location
  tags: tags
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
    tags: tags
    linkedStorageAccounts: []
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

// ---- Automation Account ----
module automationAccount 'br/public:avm/res/automation/automation-account:0.11.0' = {
  name: 'deploy-automation-account'
  scope: rg
  params: {
    name: automationAccountName
    location: location
    skuName: 'Basic'
    tags: tags
    linkedWorkspace: {
      id: logAnalytics.outputs.resourceId
    }
  }
}

// ---- Outputs ----
output logAnalyticsWorkspaceId string = logAnalytics.outputs.resourceId
output logAnalyticsWorkspaceName string = logAnalytics.outputs.name
output automationAccountId string = automationAccount.outputs.resourceId
output resourceGroupId string = rg.id
