using '../main.bicep'

// ============================================================
// Sentinel Parameters — Australia East / Management Subscription
// ============================================================

param location                    = 'australiaeast'
param logAnalyticsWorkspaceName   = 'law-management-australiaeast-001'
param logAnalyticsResourceGroupName = 'rg-management-logging-001'

param dailyQuotaGb     = -1    // No cap — adjust for cost control if needed
param retentionInDays  = 365

param enableUeba       = true
param uebaDataSources  = ['AuditLogs', 'AzureActivity', 'SecurityEvent', 'SigninLogs']

param enableHealthDiagnostics = true

// Set via GitHub Actions secret: SENTINEL_SECURITY_CONTACT
param securityContactEmail = ''

param tags = {
  environment : 'management'
  workload    : 'sentinel-soc'
  region      : 'australiaeast'
  managedBy   : 'soc-team'
  createdBy   : 'alz-bicep'
}
