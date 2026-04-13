// ============================================================
// Reusable Module: CanNotDelete Resource Lock
// Scope: resourceGroup (caller must set scope: <rg> on the module)
//
// Usage:
//   module rgLock 'modules/resource-lock.bicep' = {
//     name: 'deploy-rg-lock'
//     scope: myResourceGroup
//     params: {
//       lockName: 'lock-rg-myworkload-cannotdelete'
//       notes: 'Production resource — see change management runbook'
//     }
//   }
// ============================================================

targetScope = 'resourceGroup'

@description('Name for the resource lock resource')
param lockName string = 'lock-cannotdelete'

@description('Human-readable notes explaining the lock purpose and removal process')
param notes string = 'Platform resource — do not delete without Platform Architecture Board approval'

// CanNotDelete — resources can still be modified but not removed.
// DeleteLock is preferred over ReadOnly for production workloads as ReadOnly
// blocks operations such as listing storage keys (breaks Azure services).
resource resourceLock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: lockName
  properties: {
    level: 'CanNotDelete'
    notes: notes
  }
}

output lockId string = resourceLock.id
