// =============================================================
// Module: Subscription-level diagnostic settings
// Sends Azure Activity Log to central Log Analytics workspace
// =============================================================

@description('Subscription ID')
param subscriptionId string

@description('Central Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

resource subscriptionDiagSettings 'microsoft.insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'sub-diag-to-law'
  scope: subscription(subscriptionId)
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      { category: 'Administrative'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'Security';       enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'ServiceHealth';  enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'Alert';          enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'Recommendation'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'Policy';         enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'Autoscale';      enabled: true; retentionPolicy: { days: 365; enabled: true } }
      { category: 'ResourceHealth'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
  }
}

output diagnosticSettingsId string = subscriptionDiagSettings.id
