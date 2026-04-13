targetScope = 'subscription'

// =============================================================
// Azure Landing Zone — Platform Monitoring
// Region : Australia East | Management Subscription
// Covers : Azure Monitor action groups, metric alerts, activity
//          log alerts, Network Watcher, Service Health alerts
// =============================================================

@description('Azure region')
param location string = 'australiaeast'

@description('Log Analytics workspace resource ID')
param logAnalyticsWorkspaceId string

@description('Alert email — platform operations team')
param opsAlertEmail string

@description('Alert email — security / SOC team')
param secAlertEmail string

@description('Connectivity subscription ID (for ER / Checkpoint alerts)')
param connectivitySubscriptionId string

@description('ExpressRoute circuit resource ID')
param erCircuitResourceId string

@description('Checkpoint VM resource ID')
param checkpointVmResourceId string

@description('Internal Load Balancer resource ID for Checkpoint VMSS — used for health backend count alert')
param checkpointInternalLbId string = ''

@description('Resource tags')
param tags object = {
  environment: 'management'
  managedBy  : 'platform-team'
  createdBy  : 'alz-bicep'
}

// =============================================================
// Resource Group
// =============================================================
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'rg-management-monitoring-001'
  location: location
  tags: tags
}

// =============================================================
// Action Groups
// =============================================================

// Operations team — non-critical, informational
module agOps 'br/public:avm/res/insights/action-group:0.4.0' = {
  name: 'deploy-ag-ops'
  scope: rg
  params: {
    name: 'ag-platform-ops-001'
    groupShortName: 'PlatformOps'
    enabled: true
    emailReceivers: [
      {
        name: 'OpsTeam'
        emailAddress: opsAlertEmail
        useCommonAlertSchema: true
      }
    ]
    tags: tags
  }
}

// Security / SOC team — high severity security events
module agSec 'br/public:avm/res/insights/action-group:0.4.0' = {
  name: 'deploy-ag-sec'
  scope: rg
  params: {
    name: 'ag-platform-security-001'
    groupShortName: 'SOCSecurity'
    enabled: true
    emailReceivers: [
      {
        name: 'SOCTeam'
        emailAddress: secAlertEmail
        useCommonAlertSchema: true
      }
    ]
    tags: tags
  }
}

// =============================================================
// Activity Log Alerts — Platform Level
// =============================================================

// 1. Policy assignment deleted (governance risk)
resource alertPolicyDeleted 'microsoft.insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'alert-policy-assignment-deleted'
  location: 'global'
  tags: tags
  properties: {
    scopes: ['/subscriptions/${subscription().subscriptionId}']
    enabled: true
    description: 'Fires when an Azure Policy assignment is deleted — potential governance bypass.'
    condition: {
      allOf: [
        { field: 'category'; equals: 'Administrative' }
        { field: 'operationName'; equals: 'Microsoft.Authorization/policyAssignments/delete' }
        { field: 'status'; equals: 'Succeeded' }
      ]
    }
    actions: {
      actionGroups: [
        { actionGroupId: agSec.outputs.resourceId }
        { actionGroupId: agOps.outputs.resourceId }
      ]
    }
  }
}

// 2. Management group hierarchy change
resource alertMgChange 'microsoft.insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'alert-management-group-changed'
  location: 'global'
  tags: tags
  properties: {
    scopes: ['/subscriptions/${subscription().subscriptionId}']
    enabled: true
    description: 'Fires when a management group is created, updated, or deleted.'
    condition: {
      allOf: [
        { field: 'category'; equals: 'Administrative' }
        { field: 'resourceType'; equals: 'microsoft.management/managementgroups' }
        { field: 'status'; equals: 'Succeeded' }
      ]
    }
    actions: {
      actionGroups: [
        { actionGroupId: agSec.outputs.resourceId }
      ]
    }
  }
}

// 3. Security contact changed in Defender for Cloud
resource alertSecurityContactChanged 'microsoft.insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'alert-defender-security-contact-changed'
  location: 'global'
  tags: tags
  properties: {
    scopes: ['/subscriptions/${subscription().subscriptionId}']
    enabled: true
    description: 'Fires when Defender for Cloud security contact is modified.'
    condition: {
      allOf: [
        { field: 'category'; equals: 'Administrative' }
        { field: 'operationName'; equals: 'Microsoft.Security/securityContacts/write' }
      ]
    }
    actions: {
      actionGroups: [
        { actionGroupId: agSec.outputs.resourceId }
      ]
    }
  }
}

// 4. Service Health — Australia East degradation
resource alertServiceHealth 'microsoft.insights/activityLogAlerts@2023-01-01-preview' = {
  name: 'alert-service-health-australiaeast'
  location: 'global'
  tags: tags
  properties: {
    scopes: ['/subscriptions/${subscription().subscriptionId}']
    enabled: true
    description: 'Azure Service Health incident or degradation in Australia East.'
    condition: {
      allOf: [
        { field: 'category'; equals: 'ServiceHealth' }
        {
          anyOf: [
            { field: 'properties.impactedServices[*].ServiceName'; containsAny: ['ExpressRoute', 'Virtual Network', 'Virtual Machines'] }
          ]
        }
      ]
    }
    actions: {
      actionGroups: [
        { actionGroupId: agOps.outputs.resourceId }
      ]
    }
  }
}

// =============================================================
// Network Watcher (one per region per subscription)
// =============================================================
resource networkWatcherRg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: 'NetworkWatcherRG'
  location: location
  tags: tags
}

resource networkWatcher 'Microsoft.Network/networkWatchers@2023-09-01' = {
  name: 'nw-australiaeast-001'
  location: location
  tags: tags
  // Deploying in NetworkWatcherRG as per Azure convention
}

// =============================================================
// Azure Monitor — Dashboard (Workbook) for Platform Health
// =============================================================
resource platformWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(subscription().subscriptionId, 'platform-health-workbook')
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: 'HSS Platform Health Dashboard'
    category: 'workbook'
    sourceId: logAnalyticsWorkspaceId
    serializedData: string({
      version: 'Notebook/1.0'
      items: [
        {
          type: 1
          content: {
            json: '## HSS Platform Health\nExpressRoute | Checkpoint NVA | Sentinel | Policy Compliance'
          }
        }
        {
          type: 9
          content: {
            version: 'KqlParameterItem/1.0'
            parameters: [
              {
                id: 'timeRange'
                version: 'KqlParameterItem/1.0'
                name: 'TimeRange'
                type: 4
                value: { durationMs: 86400000 }
                typeSettings: { selectableValues: [{ durationMs: 3600000 }, { durationMs: 86400000 }, { durationMs: 604800000 }] }
              }
            ]
          }
        }
      ]
    })
  }
}

// =============================================================
// Checkpoint VMSS Health — Internal LB Backend Count Alert
// Fires when fewer than 2 NVA instances are healthy (DipAvailability < 100%)
// =============================================================
resource alertCheckpointUnhealthyBackend 'Microsoft.Insights/metricAlerts@2018-03-01' = if (!empty(checkpointInternalLbId)) {
  name: 'alert-checkpoint-unhealthy-backend-001'
  location: 'global'
  tags: tags
  properties: {
    description: 'Fires when fewer than 2 Checkpoint VMSS instances are healthy in the internal LB backend pool. Indicates NVA cluster degradation — investigate immediately.'
    severity: 1   // Critical
    enabled: true
    scopes: [checkpointInternalLbId]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    targetResourceType: 'Microsoft.Network/loadBalancers'
    targetResourceRegion: 'australiaeast'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HealthyBackendCountLow'
          metricName: 'DipAvailability'
          metricNamespace: 'Microsoft.Network/loadBalancers'
          operator: 'LessThan'
          threshold: 100   // DipAvailability is a percentage — below 100% means at least one probe failing
          timeAggregation: 'Average'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [
      {
        actionGroupId: resourceId('Microsoft.Insights/actionGroups', 'ag-platform-ops-001')
      }
    ]
  }
}

// =============================================================
// Outputs
// =============================================================
output opsActionGroupId string     = agOps.outputs.resourceId
output secActionGroupId string     = agSec.outputs.resourceId
output networkWatcherId string     = networkWatcher.id
output platformWorkbookId string   = platformWorkbook.id
output checkpointHealthAlertId string = (!empty(checkpointInternalLbId)) ? alertCheckpointUnhealthyBackend.id : ''
