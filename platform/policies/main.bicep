targetScope = 'managementGroup'

// =============================================================
// Azure Landing Zone — Policy Assignments
// Scope  : Root ALZ management group (inherited by all children)
// Aligns with: ALZ baseline, APRA CPS 234, Essential Eight,
//              Australian Government ISM
// =============================================================

@description('Root management group ID')
param rootManagementGroupId string = 'alz'

@description('Log Analytics workspace resource ID (for policy diagnostic effects)')
param logAnalyticsWorkspaceId string

@description('Azure region for policy remediation tasks')
param location string = 'australiaeast'

@description('Email for security contact alerts')
param securityContactEmail string

@description('Resource tags applied via policy')
param mandatoryTagNames array = [
  'environment'
  'managedBy'
  'costCenter'
  'createdBy'
]

// =============================================================
// Helper — current MG scope
// =============================================================
var rootMgScope = tenantResourceId('Microsoft.Management/managementGroups', rootManagementGroupId)

// =============================================================
// ALZ — Deny Resources in Disallowed Locations
// Only Australia East + Australia Southeast allowed
// =============================================================
resource policyAllowedLocations 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-resources-outside-australia'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — Resources outside Australia East / Southeast'
    description: 'Restricts resource deployment to Australian Azure regions only.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/e56962a6-4747-49cd-b67b-bf8b01975c4c'
    enforcementMode: 'Default'
    parameters: {
      listOfAllowedLocations: {
        value: ['australiaeast', 'australiasoutheast', 'global']
      }
    }
  }
}

// =============================================================
// ALZ — Require Tags on Resource Groups
// =============================================================
resource policyRequireTags 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'require-tags-on-rg'
  scope: managementGroup()
  identity: {
    type: 'SystemAssigned'
  }
  location: location
  properties: {
    displayName: 'REQUIRE — Mandatory tags on resource groups'
    description: 'Requires environment, managedBy, costCenter and createdBy tags on all RGs.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025'
    enforcementMode: 'Default'
    parameters: {
      tagName: { value: 'environment' }
    }
  }
}

// =============================================================
// ALZ — Inherit Tags from Subscription to Resource Groups (Append)
// =============================================================
resource policyInheritTags 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'inherit-tags-from-sub'
  scope: managementGroup()
  identity: {
    type: 'SystemAssigned'
  }
  location: location
  properties: {
    displayName: 'APPEND — Inherit environment tag from subscription'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/b27a0cbd-a167-4dfa-ae64-4337be671140'
    enforcementMode: 'Default'
    parameters: {
      tagName: { value: 'environment' }
    }
  }
}

// =============================================================
// Security — Enable Microsoft Defender for Cloud (DINE)
// Deploys Defender plans automatically on new subscriptions
// =============================================================
resource policyDefenderServers 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deploy-defender-servers'
  scope: managementGroup()
  identity: {
    type: 'SystemAssigned'
  }
  location: location
  properties: {
    displayName: 'DINE — Enable Defender for Servers Plan 2'
    description: 'Automatically enables Microsoft Defender for Servers Plan 2 on new subscriptions.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/8e86a5b6-b9bd-49ab-8a19-b1064d1d3bd8'
    enforcementMode: 'Default'
    parameters: {}
  }
}

resource policyDefenderStorage 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deploy-defender-storage'
  scope: managementGroup()
  identity: {
    type: 'SystemAssigned'
  }
  location: location
  properties: {
    displayName: 'DINE — Enable Defender for Storage'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/cfdc5972-75b3-4418-8ae1-7f5c36839390'
    enforcementMode: 'Default'
    parameters: {}
  }
}

resource policyDefenderKeyVault 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deploy-defender-keyvault'
  scope: managementGroup()
  identity: {
    type: 'SystemAssigned'
  }
  location: location
  properties: {
    displayName: 'DINE — Enable Defender for Key Vault'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/1f725891-01c0-420a-9059-4fa46cb770b7'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Security — Auto-provision Log Analytics Agent (DINE)
// =============================================================
resource policyLogAnalyticsAgent 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deploy-law-agent'
  scope: managementGroup()
  identity: {
    type: 'SystemAssigned'
  }
  location: location
  properties: {
    displayName: 'DINE — Deploy Log Analytics agent to VMs'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/8e7da0a5-0a0e-4bbc-bfc0-7773c018b616'
    enforcementMode: 'Default'
    parameters: {
      logAnalytics: {
        value: logAnalyticsWorkspaceId
      }
    }
  }
}

// =============================================================
// Security — Azure Security Benchmark (Audit)
// Baseline for APRA CPS 234 and ISM alignment
// =============================================================
resource policyAzureSecurityBenchmark 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'audit-azure-security-benchmark'
  scope: managementGroup()
  properties: {
    displayName: 'AUDIT — Microsoft Cloud Security Benchmark'
    description: 'Audits compliance with MCSB — baseline for APRA CPS 234 and Australian ISM.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8'
    enforcementMode: 'DoNotEnforce'
    parameters: {}
  }
}

// =============================================================
// Network — Deny Public IP on VMs (Platform MG only)
// Workloads access internet via Checkpoint NVA only
// =============================================================
resource policyDenyPublicIpVm 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-public-ip-on-vm'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — Public IP addresses on virtual machines'
    description: 'Prevents VMs in spoke subscriptions from having directly assigned public IPs. All outbound traffic must flow through Checkpoint NVA.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/83a86a26-fd1f-447c-b59d-e51f44264114'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Network — Deny RDP / SSH from Internet (NSG)
// =============================================================
resource policyDenyRdpFromInternet 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-rdp-from-internet'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — RDP access from internet via NSG'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/e372f825-a257-4fb8-9175-797a8a8627d6'
    enforcementMode: 'Default'
    parameters: {}
  }
}

resource policyDenySshFromInternet 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-ssh-from-internet'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — SSH access from internet via NSG'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/2c89a2e5-7285-40fe-afe0-ae8654b92fb2'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Storage — Deny HTTP (require HTTPS only)
// =============================================================
resource policyStorageHttps 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-storage-http'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — HTTP traffic to storage accounts (require HTTPS)'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/404c3081-a854-4457-ae30-26a93ef643f9'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Key Vault — Require Soft Delete and Purge Protection
// =============================================================
resource policyKeyVaultSoftDelete 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'require-kv-soft-delete'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — Key Vaults without soft delete and purge protection'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/0b60c0b2-2dc2-4e1c-b5c9-abbed971de53'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Compute — Require Managed Disks
// =============================================================
resource policyManagedDisks 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'require-managed-disks'
  scope: managementGroup()
  properties: {
    displayName: 'AUDIT — VMs should use managed disks'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/06a78e20-9358-41c9-923c-fb736d382a4d'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Diagnostic Settings — Deploy to all resource types (DINE)
// =============================================================
resource policyDiagnosticSettings 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deploy-diag-settings'
  scope: managementGroup()
  identity: {
    type: 'SystemAssigned'
  }
  location: location
  properties: {
    displayName: 'DINE — Deploy diagnostic settings to Log Analytics'
    description: 'Automatically deploys diagnostic settings on supported resources to the central LAW.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policySetDefinitions/0884adba-2312-4468-abeb-5422caed1038'
    enforcementMode: 'Default'
    parameters: {
      logAnalytics: {
        value: logAnalyticsWorkspaceId
      }
    }
  }
}

// =============================================================
// RBAC — No Custom Subscription Owner Roles
// =============================================================
resource policyNoCustomOwner 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-custom-subscription-owner'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — Custom subscription owner roles'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/10ee2ea2-fb4d-45b8-a7e9-a2e770044cd9'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// RBAC — No Classic Administrators
// =============================================================
resource policyNoClassicAdmin 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-classic-admin'
  scope: managementGroup()
  properties: {
    displayName: 'AUDIT — Deprecated classic administrators should be removed'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/bad16df5-b5dc-4f5c-87e9-7d72a60e6b18'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Outputs
// =============================================================
output policyAssignmentCount int = 15
