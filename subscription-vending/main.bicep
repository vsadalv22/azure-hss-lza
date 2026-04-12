targetScope = 'managementGroup'

// ============================================================
// Azure Landing Zone - Subscription Vending Machine
// Automatically creates and configures new EA subscriptions
// Uses: lz-vending AVM module
// ============================================================

@description('Subscription display name')
param subscriptionDisplayName string

@description('Subscription alias (unique identifier)')
param subscriptionAlias string

@description('Management group ID to place subscription under')
@allowed([
  'alz-landingzones-corp'
  'alz-landingzones-online'
  'alz-sandbox'
])
param targetManagementGroupId string

@description('EA Billing Account ID')
param eaBillingAccountName string

@description('EA Enrollment Account Name')
param eaEnrollmentAccountName string

@description('Workload type')
@allowed(['Production', 'DevTest'])
param subscriptionWorkload string = 'Production'

@description('Hub VNet resource ID for spoke peering')
param hubVnetId string

@description('Azure region for spoke resources')
param location string = 'australiaeast'

@description('Spoke VNet address prefix (must be unique, non-overlapping)')
param spokeVnetAddressPrefix string

@description('Spoke subnets')
param spokeSubnets array = [
  {
    name: 'snet-app'
    addressPrefix: ''   // Set in .bicepparam file
  }
  {
    name: 'snet-data'
    addressPrefix: ''
  }
]

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Route table resource ID (points default route to Checkpoint NVA)')
param routeTableId string

@description('Application team owner email for RBAC')
param ownerEmail string

@description('Azure AD group object ID for subscription owner role')
param ownerGroupObjectId string

@description('Resource tags to apply to the subscription')
param tags object = {
  managedBy: 'platform-team'
  createdBy: 'subscription-vending'
}

// ============================================================
// Subscription Vending - AVM lz-vending module
// https://aka.ms/lz-vending
// ============================================================
module subscriptionVending 'br/public:avm/ptn/lz/sub-vending:0.4.1' = {
  name: 'vend-${subscriptionAlias}'
  params: {
    // ---- Subscription ----
    subscriptionAliasEnabled: true
    subscriptionAliasName: subscriptionAlias
    subscriptionDisplayName: subscriptionDisplayName
    subscriptionWorkload: subscriptionWorkload
    subscriptionBillingScope: '/providers/Microsoft.Billing/billingAccounts/${eaBillingAccountName}/enrollmentAccounts/${eaEnrollmentAccountName}'

    // ---- Management Group placement ----
    subscriptionManagementGroupAssociationEnabled: true
    subscriptionManagementGroupId: targetManagementGroupId

    // ---- Spoke Virtual Network ----
    virtualNetworkEnabled: true
    virtualNetworkName: 'vnet-spoke-${subscriptionAlias}-001'
    virtualNetworkAddressSpace: [spokeVnetAddressPrefix]
    virtualNetworkLocation: location
    virtualNetworkResourceGroupName: 'rg-network-${subscriptionAlias}-001'
    virtualNetworkResourceGroupLockEnabled: true

    // Subnets with UDR to force traffic through Checkpoint NVA
    virtualNetworkSubnets: [for subnet in spokeSubnets: {
      name: subnet.name
      addressPrefix: subnet.addressPrefix
      routeTableResourceId: routeTableId
    }]

    // ---- Hub Peering ----
    virtualNetworkPeeringEnabled: true
    hubNetworkResourceId: hubVnetId
    virtualNetworkUseRemoteGateways: true

    // ---- Role Assignments ----
    roleAssignmentEnabled: true
    roleAssignments: [
      {
        principalId: ownerGroupObjectId
        roleDefinitionIdOrName: 'Contributor'
        principalType: 'Group'
        relativeScope: ''   // subscription scope
      }
    ]

    // ---- Tags ----
    tags: union(tags, {
      subscriptionAlias: subscriptionAlias
      ownerEmail: ownerEmail
    })
  }
}

// ---- Outputs ----
output subscriptionId string = subscriptionVending.outputs.subscriptionId
output spokeVnetResourceId string = subscriptionVending.outputs.virtualNetworkResourceId
