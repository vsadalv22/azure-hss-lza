using '../main.bicep'

// =============================================================
// Example: Vend a Corp Landing Zone subscription
// Copy and customise for each new subscription request.
// Run scripts/new-subscription.ps1 to scaffold automatically.
// =============================================================

// ── Subscription identity ──────────────────────────────────────
param subscriptionDisplayName  = 'MyApp Production — Payments'
param subscriptionAlias        = 'sub-myapp-prod'           // Must match: sub-<app>-<env>
param targetManagementGroupId  = 'alz-landingzones-corp'
param subscriptionWorkload     = 'Production'

// ── EA Billing (overridden by pipeline secrets) ────────────────
param eaBillingAccountName     = '<SET_BY_PIPELINE_SECRET>'
param eaEnrollmentAccountName  = '<SET_BY_PIPELINE_SECRET>'

// ── Networking ─────────────────────────────────────────────────
param location                 = 'australiaeast'
param hubVnetId                = '<SET_BY_PIPELINE_SECRET>'  // HUB_VNET_ID
param spokeVnetAddressPrefix   = '10.100.0.0/16'             // Corp range: 10.100-199.x.x
param spokeSubnets = [
  { name: 'snet-app',  addressPrefix: '10.100.0.0/24' }
  { name: 'snet-data', addressPrefix: '10.100.1.0/24' }
  { name: 'snet-web',  addressPrefix: '10.100.2.0/24' }
]
param routeTableId             = '<SET_BY_PIPELINE_SECRET>'  // ROUTE_TABLE_ID

// ── Observability ──────────────────────────────────────────────
param logAnalyticsWorkspaceId  = '<SET_BY_PIPELINE_SECRET>'  // LOG_ANALYTICS_WORKSPACE_ID

// ── Ownership ──────────────────────────────────────────────────
param ownerEmail               = 'payments-team@company.com.au'
param ownerGroupObjectId       = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
param readerGroupObjectId      = ''    // Optional: read-only group (e.g. auditors)

// ── Cost Management ────────────────────────────────────────────
param budgetAmountAUD          = 8000  // AUD/month — alerts at 80%, 100%, 120%
param budgetAlertEmail         = 'payments-team@company.com.au'

// ── Security ───────────────────────────────────────────────────
param dataClassification       = 'CONFIDENTIAL'
param enableDefenderServers    = true
param enableDefenderStorage    = true
param enableDefenderKeyVault   = true
param enableDefenderSql        = true        // Payments workload uses SQL
param enableDefenderContainers = false

// ── Compliance ─────────────────────────────────────────────────
param complianceFrameworks     = 'APRA-CPS234,PCI-DSS'

// ── Tags ───────────────────────────────────────────────────────
param tags = {
  environment          : 'production'
  application          : 'payments'
  businessUnit         : 'finance'
  costCenter           : 'CC-1234'
  dataClassification   : 'CONFIDENTIAL'
  complianceFrameworks : 'APRA-CPS234,PCI-DSS'
  managedBy            : 'platform-team'
  createdBy            : 'subscription-vending'
  ownerEmail           : 'payments-team@company.com.au'
}
