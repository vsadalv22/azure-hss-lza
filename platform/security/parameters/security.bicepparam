using '../main.bicep'

// ============================================================
// Platform Security Parameters
// Deploys: Key Vault (Premium/HSM), immutable audit storage,
//          resource locks, private endpoints
//
// Run AFTER: 02-logging (need LAW ID), 03-connectivity (need VNet/subnet IDs)
//
// Pipeline variable group: alz-platform-secrets
// Required secrets/variables to populate before running:
//   LOG_ANALYTICS_WORKSPACE_ID  — output from pipeline 02-logging
//   HUB_VNET_ID                 — output from pipeline 03-connectivity
//   MANAGEMENT_SUBNET_ID        — output from pipeline 03-connectivity
//
// Post-deploy (manual):
//   1. Create Key Vault secrets: checkpoint-admin-password, automation-account-key
//   2. Pipeline 06 post-deploy step grants Key Vault Crypto User role to
//      the LAW managed identity (id-law-cmk-aue-001).
//   3. Re-run pipeline 02-logging with keyVaultResourceId and
//      immutableStorageAccountId to activate CMK + WORM export.
// ============================================================

param location = 'australiaeast'

// Set via pipeline output from 02-logging: LOG_ANALYTICS_WORKSPACE_ID
param logAnalyticsWorkspaceId = ''

// Set via pipeline output from 03-connectivity: HUB_VNET_ID
param hubVnetId = ''

// Set via pipeline output from 03-connectivity: MANAGEMENT_SUBNET_ID
param managementSubnetId = ''

param enableResourceLocks = true

param tags = {
  environment : 'security'
  managedBy   : 'platform-team'
  createdBy   : 'alz-bicep'
  costCenter  : 'platform'
  dataClass   : 'confidential'
}
