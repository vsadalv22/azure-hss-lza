targetScope = 'managementGroup'

// ============================================================
// Platform RBAC Assignments — Least Privilege Model
// Aligned with: APRA CPS 234, Essential Eight ML2 (Restrict Admin)
//
// Principal Types: Group (from Entra ID) or ManagedIdentity
// All assignments use built-in roles — no custom roles permitted
// at root MG scope per policy (policyNoCustomOwner)
// ============================================================

@description('Object ID of the Platform Engineering Entra group')
param platformEngineerGroupId string

@description('Object ID of the Network Engineering Entra group')
param networkEngineerGroupId string

@description('Object ID of the Security Operations (SOC) Entra group')
param socGroupId string

@description('Object ID of the Subscription Requestor Entra group (read-only vending requests)')
param subscriptionRequestorGroupId string

// Built-in Role IDs
var roles = {
  reader                    : '/providers/Microsoft.Authorization/roleDefinitions/acdd72a7-3385-48ef-bd42-f606fba81ae7'
  contributor               : '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c'
  networkContributor        : '/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7'
  securityReader            : '/providers/Microsoft.Authorization/roleDefinitions/39bc4728-0917-49c7-9d2c-d95423bc2eb4'
  securityAdmin             : '/providers/Microsoft.Authorization/roleDefinitions/fb1c8493-542b-48eb-b624-b4c8fea62acd'
  monitoringReader          : '/providers/Microsoft.Authorization/roleDefinitions/43d0d8ad-25c7-4714-9337-8ba259a9fe05'
  managementGroupContributor: '/providers/Microsoft.Authorization/roleDefinitions/5d58bcaf-24a5-4b20-bdb6-eed9f69fbe4c'
}

// Platform Engineers — Contributor at Platform MG, Reader at root
resource platformEngineerRootReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, platformEngineerGroupId, roles.reader)
  properties: {
    roleDefinitionId: roles.reader
    principalId: platformEngineerGroupId
    principalType: 'Group'
    description: 'Platform Engineering team — read-only at root MG for visibility'
  }
}

// Network Engineers — Network Contributor scoped to Connectivity MG (set in child assignment)
resource networkEngineerReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, networkEngineerGroupId, roles.reader)
  properties: {
    roleDefinitionId: roles.reader
    principalId: networkEngineerGroupId
    principalType: 'Group'
    description: 'Network Engineering team — reader at root, Network Contributor applied at Connectivity MG'
  }
}

// SOC team — Security Reader at root (Sentinel access granted separately at workspace level)
resource socSecurityReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, socGroupId, roles.securityReader)
  properties: {
    roleDefinitionId: roles.securityReader
    principalId: socGroupId
    principalType: 'Group'
    description: 'SOC team — Security Reader at root MG for Defender for Cloud visibility'
  }
}

// Subscription Requestors — Reader at root (can see subscriptions via portal)
resource subscriptionRequestorReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(managementGroup().id, subscriptionRequestorGroupId, roles.reader)
  properties: {
    roleDefinitionId: roles.reader
    principalId: subscriptionRequestorGroupId
    principalType: 'Group'
    description: 'Subscription requestors — read-only access to verify their subscription vending status'
  }
}

output rbacAssignmentCount int = 4
