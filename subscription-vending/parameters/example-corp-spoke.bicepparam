using '../main.bicep'

// ============================================================
// Example: Vend a new Corp Landing Zone subscription
// Copy and customise this file for each new subscription request
// ============================================================

// ---- Subscription details ----
param subscriptionDisplayName = 'sub-contoso-retail-prod'
param subscriptionAlias       = 'sub-contoso-retail-prod'
param targetManagementGroupId = 'alz-landingzones-corp'
param subscriptionWorkload    = 'Production'

// ---- EA Billing ----
param eaBillingAccountName    = '<YOUR_EA_BILLING_ACCOUNT_ID>'
param eaEnrollmentAccountName = '<YOUR_EA_ENROLLMENT_ACCOUNT_ID>'

// ---- Networking ----
param location                = 'australiaeast'
param hubVnetId               = '/subscriptions/<CONNECTIVITY_SUB_ID>/resourceGroups/rg-connectivity-hub-australiaeast-001/providers/Microsoft.Network/virtualNetworks/vnet-hub-australiaeast-001'
param spokeVnetAddressPrefix  = '10.100.0.0/16'   // Must not overlap with other spokes or hub
param spokeSubnets = [
  {
    name: 'snet-app'
    addressPrefix: '10.100.0.0/24'
  }
  {
    name: 'snet-data'
    addressPrefix: '10.100.1.0/24'
  }
  {
    name: 'snet-web'
    addressPrefix: '10.100.2.0/24'
  }
]

// Route table (UDR) in hub pointing default route -> Checkpoint internal IP
param routeTableId            = '/subscriptions/<CONNECTIVITY_SUB_ID>/resourceGroups/rg-connectivity-hub-australiaeast-001/providers/Microsoft.Network/routeTables/udr-to-checkpoint-001'
param logAnalyticsWorkspaceId = '/subscriptions/<MANAGEMENT_SUB_ID>/resourceGroups/rg-management-logging-001/providers/Microsoft.OperationalInsights/workspaces/law-management-australiaeast-001'

// ---- Ownership ----
param ownerEmail        = 'team@contoso.com'
param ownerGroupObjectId = '<AAD_GROUP_OBJECT_ID>'

// ---- Tags ----
param tags = {
  environment: 'production'
  application: 'retail'
  businessUnit: 'contoso'
  costCenter: 'retail-001'
  managedBy: 'platform-team'
  createdBy: 'subscription-vending'
}
