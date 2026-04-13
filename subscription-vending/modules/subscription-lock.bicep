targetScope = 'subscription'

// ============================================================
// Subscription CanNotDelete Lock
//
// Applied to all EA subscriptions created via the vending
// machine to prevent accidental deletion.
//
// EA subscription deletion is IRREVERSIBLE — the subscription
// and all its resources are permanently removed from the tenant.
//
// To remove this lock (e.g. for decommissioning):
//   1. Raise an RFC with Platform Architecture Board approval
//   2. Remove lock: az lock delete --name <lock-name> --subscription <id>
//   3. Proceed with decommission checklist
// ============================================================

@description('Lock display name')
param lockName string = 'lock-subscription-cannotdelete'

@description('Justification note recorded with the lock')
param notes string = 'EA subscription provisioned via HSS Landing Zone vending machine. Deletion is irreversible and requires Platform Architecture Board approval. Remove this lock only after completing the subscription decommission checklist.'

resource subLock 'Microsoft.Authorization/locks@2020-05-01' = {
  name: lockName
  properties: {
    level: 'CanNotDelete'
    notes: notes
  }
}

// ---- Outputs ----
output lockId   string = subLock.id
output lockName string = subLock.name
