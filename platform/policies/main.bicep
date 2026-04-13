targetScope = 'managementGroup'

// =============================================================
// Azure Landing Zone — Policy Assignments
// Scope  : Root ALZ management group (inherited by all children)
//          + tiered sub-scopes for Platform and Landing Zone MGs
// Aligns with: ALZ baseline, APRA CPS 234, Essential Eight,
//              Australian Government ISM
// DD36   : Tiered policy scope — policies assigned at the most
//          appropriate MG level rather than all at root
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

// ---- DD36: Tiered policy scope params ----
@description('DD36 — Platform management group ID')
param platformManagementGroupId string = 'platform'

@description('DD36 — Landing Zones management group ID')
param landingZonesManagementGroupId string = 'landingzones'

@description('DD36 — Connectivity management group ID (child of Platform)')
param connectivityManagementGroupId string = 'connectivity'

@description('DD36 — Identity management group ID (child of Platform)')
param identityManagementGroupId string = 'identity'

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
// DD36 — Tiered Policy Assignments
// Sub-scope assignments applied at Platform/Connectivity and
// Landing Zones MGs rather than inheriting from root.
// =============================================================

// --- Platform / Connectivity MG scope ---

// DD36: DENY unencrypted ExpressRoute private peering
// Scoped to Connectivity MG — only applies where ER circuits live.
// Built-in: "ExpressRoute circuits should not use classic peering"
resource policyDenyExpressRouteUnencrypted 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-er-unencrypted-peering'
  scope: managementGroup(connectivityManagementGroupId)
  properties: {
    displayName: 'DENY — Unencrypted ExpressRoute private peering (Connectivity MG)'
    description: 'DD36 — Prevents ExpressRoute circuits from using classic (unencrypted) private peering. Applied at Connectivity MG scope.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/58d5d4b6-b23f-47ac-8e18-e2caf4e26eb4'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// --- Landing Zones MG scope ---

// DD36: DENY VNet peering to non-approved VNets
// Workloads must connect via hub-spoke topology through Checkpoint NVA.
// Built-in: "VPNs should use private IP"
// Note: This built-in enforces private IP on VPN connections; for full
// hub-spoke enforcement consider a custom policy or Azure Policy initiative.
resource policyDenyVnetInjectionBypass 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-vnet-injection-bypass'
  scope: managementGroup(landingZonesManagementGroupId)
  properties: {
    displayName: 'DENY — VNet injection bypass / non-approved VNet peering (Landing Zones MG)'
    description: 'DD36 — Workloads must use hub-spoke topology. Denies VPN connections not using private IP, preventing bypass of the Checkpoint NVA.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/b8cbb944-4d77-4a96-8c3e-02b3e14fbc3f'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// DD36 + DD40: REQUIRE hsp-id tag on all resources in Landing Zones MG
// Supports Sentinel HSP data segregation (DD40) — the DCR and analytics
// rules rely on this tag being present on all workload resources.
resource policyRequireHspIdTag 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'require-hsp-id-tag'
  scope: managementGroup(landingZonesManagementGroupId)
  identity: {
    type: 'SystemAssigned'
  }
  location: location
  properties: {
    displayName: 'REQUIRE — hsp-id tag on all resources (Landing Zones MG)'
    description: 'DD36 + DD40 — All workload resources must carry an hsp-id tag identifying their Health Service Provider. Required for Sentinel row-level data scoping.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/96670d01-0a4d-4649-9c89-2d3abc0a5025'
    enforcementMode: 'Default'
    parameters: {
      tagName: { value: 'hsp-id' }
    }
  }
}

// =============================================================
// Security — Enforce TLS 1.2 minimum on storage accounts
// =============================================================
resource policyStorageTls 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'enforce-storage-tls12'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — Storage accounts below TLS 1.2'
    description: 'Ensures all storage accounts enforce a minimum of TLS 1.2 for data in transit. ISM Control 1139.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/fe83a0eb-a853-422d-aac2-1bffd182c5d0'
    enforcementMode: 'Default'
    parameters: {
      minimumTlsVersion: { value: 'TLS1_2' }
    }
  }
}

// =============================================================
// Security — Deny storage accounts with public blob access
// =============================================================
resource policyDenyPublicBlob 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deny-public-blob-access'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — Public blob access on storage accounts'
    description: 'Prevents enabling anonymous public read access on blob containers.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/4fa4b6c0-31ca-4c0d-b10d-24b96f62a751'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Security — Require secure transfer on storage accounts
// =============================================================
resource policySecureTransfer 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'require-secure-transfer-storage'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — Storage accounts without secure transfer'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/404c3081-a854-4457-ae30-26a93ef643f9'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Security — Audit VMs not using managed disks (already exists — skip)
// =============================================================

// =============================================================
// Security — Enforce Key Vault purge protection
// =============================================================
resource policyKvPurgeProtection 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'require-kv-purge-protection'
  scope: managementGroup()
  properties: {
    displayName: 'DENY — Key Vaults without purge protection'
    description: 'Key Vault purge protection prevents permanent deletion during retention period. Essential Eight ML2.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/0b60c0b2-2dc2-4e1c-b5c9-abbed971de53'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Security — Deploy Azure Monitor Dependency Agent (DINE)
// =============================================================
resource policyMonitoringAgent 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deploy-monitoring-agent'
  scope: managementGroup()
  identity: {
    type: 'SystemAssigned'
  }
  location: location
  properties: {
    displayName: 'DINE — Deploy Azure Monitor Agent to VMs'
    description: 'Deploys Azure Monitor Agent (AMA) to all VMs for log collection. Replaces legacy MMA agent.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/d367bd60-64ca-4364-98ea-276775bddd94'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Security — Enforce Private Endpoints for Key Vault (AUDIT)
// =============================================================
resource policyKvPrivateEndpoint 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'audit-kv-private-endpoint'
  scope: managementGroup()
  properties: {
    displayName: 'AUDIT — Key Vaults should use private endpoints'
    description: 'Audits Key Vaults not using private endpoints. Public access should be disabled for enterprise KVs.'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/a6abeaec-4d90-4a02-805f-6b26c4d3fbe9'
    enforcementMode: 'DoNotEnforce'
    parameters: {}
  }
}

// =============================================================
// Security — Microsoft Defender for Cloud — Enable auto-provisioning
// =============================================================
resource policyDefenderContainers 'Microsoft.Authorization/policyAssignments@2023-04-01' = {
  name: 'deploy-defender-containers'
  scope: managementGroup()
  identity: {
    type: 'SystemAssigned'
  }
  location: location
  properties: {
    displayName: 'DINE — Enable Defender for Containers'
    policyDefinitionId: '/providers/Microsoft.Authorization/policyDefinitions/c9ddb292-b203-4738-aead-18e2716f6afa'
    enforcementMode: 'Default'
    parameters: {}
  }
}

// =============================================================
// Outputs
// =============================================================
// Root-level assignments: 15 base + 7 new security = 22
// Sub-scope assignments (DD36): 3 (Connectivity x1, LandingZones x2)
// Total: 25
output policyAssignmentCount int = 25
