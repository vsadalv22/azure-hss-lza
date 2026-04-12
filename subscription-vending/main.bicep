targetScope = 'managementGroup'

// =============================================================
// Azure Landing Zone — Subscription Vending Machine
// Best Practices: EA vending, spoke networking, Defender,
//   diagnostic settings, resource locks, budget alerts,
//   tagging, RBAC least-privilege
// =============================================================

// ── Identity & Display ────────────────────────────────────────
@description('Subscription display name (shown in Azure Portal)')
param subscriptionDisplayName string

@description('Subscription alias — must be unique, lowercase, hyphens only: sub-<app>-<env>')
@minLength(3)
@maxLength(64)
param subscriptionAlias string

@description('Target management group')
@allowed([
  'alz-landingzones-corp'
  'alz-landingzones-online'
  'alz-sandbox'
])
param targetManagementGroupId string

@description('Workload type')
@allowed(['Production', 'DevTest'])
param subscriptionWorkload string = 'Production'

// ── EA Billing ────────────────────────────────────────────────
@description('EA Billing Account ID')
param eaBillingAccountName string

@description('EA Enrollment Account Name')
param eaEnrollmentAccountName string

// ── Networking ────────────────────────────────────────────────
@description('Hub VNet resource ID')
param hubVnetId string

@description('Azure region')
param location string = 'australiaeast'

@description('Spoke VNet address prefix — must be a /16, non-overlapping')
param spokeVnetAddressPrefix string

@description('Spoke subnets')
param spokeSubnets array

@description('Route table resource ID — routes 0.0.0.0/0 to Checkpoint internal IP')
param routeTableId string

// ── Observability ─────────────────────────────────────────────
@description('Central Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

// ── Ownership & Access ────────────────────────────────────────
@description('Application owner / team email (distribution list)')
param ownerEmail string

@description('Azure AD group object ID — receives Contributor at subscription scope')
param ownerGroupObjectId string

@description('Azure AD group object ID — receives Reader at subscription scope (optional)')
param readerGroupObjectId string = ''

// ── Cost Management ───────────────────────────────────────────
@description('Monthly budget in AUD — triggers alert at 80% and 100%')
param budgetAmountAUD int = 5000

@description('Budget alert email (defaults to owner email if empty)')
param budgetAlertEmail string = ''

// ── Security ─────────────────────────────────────────────────
@description('Data classification — applied as a tag and drives Defender plan selection')
@allowed(['PUBLIC', 'INTERNAL', 'CONFIDENTIAL', 'HIGHLY_CONFIDENTIAL'])
param dataClassification string = 'INTERNAL'

@description('Enable Defender for Servers Plan 2 (recommended for CONFIDENTIAL+)')
param enableDefenderServers bool = true

@description('Enable Defender for Storage')
param enableDefenderStorage bool = true

@description('Enable Defender for Key Vault')
param enableDefenderKeyVault bool = true

@description('Enable Defender for SQL')
param enableDefenderSql bool = false

@description('Enable Defender for Containers')
param enableDefenderContainers bool = false

// ── Compliance Tagging ────────────────────────────────────────
@description('Applicable compliance frameworks (free text)')
param complianceFrameworks string = 'APRA-CPS234'

// ── Resource Tags ─────────────────────────────────────────────
@description('Tags applied to all resources in this subscription')
param tags object = {}

// =============================================================
// Variables
// =============================================================
var effectiveBudgetEmail     = empty(budgetAlertEmail) ? ownerEmail : budgetAlertEmail
var spokeName                = 'vnet-spoke-${subscriptionAlias}-001'
var networkRgName            = 'rg-network-${subscriptionAlias}-001'
var monitoringRgName         = 'rg-monitoring-${subscriptionAlias}-001'

var mandatoryTags = union(tags, {
  environment        : toLower(subscriptionWorkload)
  subscriptionAlias  : subscriptionAlias
  ownerEmail         : ownerEmail
  dataClassification : dataClassification
  complianceFrameworks: complianceFrameworks
  managedBy          : 'platform-team'
  createdBy          : 'subscription-vending'
  region             : location
})

// =============================================================
// 1. Subscription + Management Group + Spoke VNet
//    (lz-vending AVM module)
// =============================================================
module lzVending 'br/public:avm/ptn/lz/sub-vending:0.4.1' = {
  name: 'vend-${subscriptionAlias}'
  params: {
    // ── Subscription ──
    subscriptionAliasEnabled    : true
    subscriptionAliasName       : subscriptionAlias
    subscriptionDisplayName     : subscriptionDisplayName
    subscriptionWorkload        : subscriptionWorkload
    subscriptionBillingScope    : '/providers/Microsoft.Billing/billingAccounts/${eaBillingAccountName}/enrollmentAccounts/${eaEnrollmentAccountName}'

    // ── MG placement ──
    subscriptionManagementGroupAssociationEnabled: true
    subscriptionManagementGroupId               : targetManagementGroupId

    // ── Spoke VNet ──
    virtualNetworkEnabled           : true
    virtualNetworkName              : spokeName
    virtualNetworkAddressSpace      : [spokeVnetAddressPrefix]
    virtualNetworkLocation          : location
    virtualNetworkResourceGroupName : networkRgName
    virtualNetworkResourceGroupLockEnabled: true     // Protect network RG

    virtualNetworkSubnets: [for subnet in spokeSubnets: {
      name             : subnet.name
      addressPrefix    : subnet.addressPrefix
      routeTableResourceId: routeTableId    // Force all egress via Checkpoint
    }]

    // ── Hub peering ──
    virtualNetworkPeeringEnabled    : true
    hubNetworkResourceId            : hubVnetId
    virtualNetworkUseRemoteGateways : true    // Use ER Gateway in hub

    // ── RBAC ──
    roleAssignmentEnabled: true
    roleAssignments: union(
      [
        {
          principalId            : ownerGroupObjectId
          roleDefinitionIdOrName : 'Contributor'
          principalType          : 'Group'
          relativeScope          : ''
        }
      ],
      empty(readerGroupObjectId) ? [] : [
        {
          principalId            : readerGroupObjectId
          roleDefinitionIdOrName : 'Reader'
          principalType          : 'Group'
          relativeScope          : ''
        }
      ]
    )

    tags: mandatoryTags
  }
}

// =============================================================
// 2. Defender for Cloud Plans
//    Deployed at subscription scope after subscription is created
// =============================================================
module defenderServers 'modules/defender-plan.bicep' = if (enableDefenderServers) {
  name: 'defender-servers-${subscriptionAlias}'
  params: {
    subscriptionId : lzVending.outputs.subscriptionId
    planName       : 'VirtualMachines'
    pricingTier    : 'Standard'
    subPlanName    : 'P2'
  }
}

module defenderStorage 'modules/defender-plan.bicep' = if (enableDefenderStorage) {
  name: 'defender-storage-${subscriptionAlias}'
  params: {
    subscriptionId : lzVending.outputs.subscriptionId
    planName       : 'StorageAccounts'
    pricingTier    : 'Standard'
  }
}

module defenderKeyVault 'modules/defender-plan.bicep' = if (enableDefenderKeyVault) {
  name: 'defender-kv-${subscriptionAlias}'
  params: {
    subscriptionId : lzVending.outputs.subscriptionId
    planName       : 'KeyVaults'
    pricingTier    : 'Standard'
  }
}

module defenderSql 'modules/defender-plan.bicep' = if (enableDefenderSql) {
  name: 'defender-sql-${subscriptionAlias}'
  params: {
    subscriptionId : lzVending.outputs.subscriptionId
    planName       : 'SqlServers'
    pricingTier    : 'Standard'
  }
}

module defenderContainers 'modules/defender-plan.bicep' = if (enableDefenderContainers) {
  name: 'defender-containers-${subscriptionAlias}'
  params: {
    subscriptionId : lzVending.outputs.subscriptionId
    planName       : 'Containers'
    pricingTier    : 'Standard'
  }
}

// =============================================================
// 3. Budget Alert
// =============================================================
module budget 'modules/subscription-budget.bicep' = {
  name: 'budget-${subscriptionAlias}'
  params: {
    subscriptionId  : lzVending.outputs.subscriptionId
    budgetName      : 'budget-${subscriptionAlias}-monthly'
    amountAUD       : budgetAmountAUD
    contactEmail    : effectiveBudgetEmail
    subscriptionAlias: subscriptionAlias
  }
}

// =============================================================
// 4. Diagnostic Settings — subscription activity log
// =============================================================
module subscriptionDiagnostics 'modules/subscription-diagnostics.bicep' = {
  name: 'diag-${subscriptionAlias}'
  params: {
    subscriptionId          : lzVending.outputs.subscriptionId
    logAnalyticsWorkspaceId : logAnalyticsWorkspaceId
  }
}

// =============================================================
// Outputs
// =============================================================
output subscriptionId string       = lzVending.outputs.subscriptionId
output spokeVnetResourceId string  = lzVending.outputs.virtualNetworkResourceId
output subscriptionAlias string    = subscriptionAlias
output managementGroupId string    = targetManagementGroupId
