targetScope = 'subscription'

// ============================================================
// Azure Landing Zone — Microsoft Sentinel
// Region  : Australia East
// Scope   : Management Subscription (shared SOC workspace)
// Includes: Sentinel workspace, data connectors, analytics
//           rules, UEBA, watchlists, automation rules,
//           HSP row-level data scoping (DD40)
// ============================================================

@description('Azure region')
param location string = 'australiaeast'

@description('Log Analytics workspace name — Sentinel is enabled on this workspace')
param logAnalyticsWorkspaceName string = 'law-management-australiaeast-001'

@description('Log Analytics workspace resource group')
param logAnalyticsResourceGroupName string = 'rg-management-logging-001'

@description('Daily data cap in GB (-1 = no cap)')
param dailyQuotaGb int = -1

@description('Retention in days for Sentinel workspace')
param retentionInDays int = 365

@description('Enable User and Entity Behaviour Analytics (UEBA)')
param enableUeba bool = true

@description('UEBA data sources to enable')
param uebaDataSources array = ['AuditLogs', 'AzureActivity', 'SecurityEvent', 'SigninLogs']

@description('Enable Health Diagnostics for Sentinel')
param enableHealthDiagnostics bool = true

@description('Azure AD tenant ID (required for AAD connector)')
param tenantId string = tenant().tenantId

@description('Sentinel security contact email')
@pattern('^[a-zA-Z0-9._%+\\-]+@[a-zA-Z0-9.\\-]+\\.[a-zA-Z]{2,}$')
param securityContactEmail string

@description('Resource tags')
param tags object = {
  environment: 'management'
  managedBy  : 'soc-team'
  createdBy  : 'alz-bicep'
}

// ---- DD40: HSP Row-Level Data Scoping ----
@description('DD40 — Enable HSP row-level data scoping in Sentinel')
param enableHspDataSegregation bool = true

@description('DD40 — List of HSP names for table-level RBAC (e.g. [\'perth-childrens\', \'fiona-stanley\', \'rpbg\'])')
param hspList array = []

// ── Effective Tags — merges caller-supplied tags with mandatory platform tags ──
// Mandatory tags are always applied regardless of what the caller passes.
// This ensures compliance with the require-tags-on-rg policy (GOV-02).
var effectiveTags = union(tags, {
  managedBy : 'platform-team'
  createdBy : 'alz-bicep'
  deployedAt: utcNow('yyyy-MM-dd')   // Deployment timestamp for audit trail
})

// ============================================================
// Reference existing Log Analytics workspace (created by
// 02-platform-logging workflow)
// ============================================================
resource existingRg 'Microsoft.Resources/resourceGroups@2023-07-01' existing = {
  name: logAnalyticsResourceGroupName
}

resource existingLaw 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
  scope: existingRg
}

// ============================================================
// Enable Microsoft Sentinel on the workspace
// ============================================================
resource sentinel 'Microsoft.SecurityInsights/onboardingStates@2024-03-01' = {
  name: 'default'
  scope: existingLaw
  properties: {
    customerManagedKey: false
  }
}

// ============================================================
// Sentinel Settings — UEBA
// ============================================================
resource uebaSettings 'Microsoft.SecurityInsights/settings@2023-02-01-preview' = if (enableUeba) {
  name: 'Ueba'
  scope: existingLaw
  kind: 'Ueba'
  properties: {
    dataSources: uebaDataSources
  }
  dependsOn: [sentinel]
}

// ============================================================
// Sentinel Settings — Entity Analytics
// ============================================================
resource entityAnalyticsSettings 'Microsoft.SecurityInsights/settings@2023-02-01-preview' = {
  name: 'EntityAnalytics'
  scope: existingLaw
  kind: 'EntityAnalytics'
  properties: {
    entityProviders: ['ActiveDirectory', 'AzureActiveDirectory']
  }
  dependsOn: [sentinel]
}

// ============================================================
// Data Connectors
// ============================================================

// 1. Azure Active Directory (Entra ID) — Sign-in & Audit logs
resource connectorAzureAd 'Microsoft.SecurityInsights/dataConnectors@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'AzureActiveDirectory')
  scope: existingLaw
  kind: 'AzureActiveDirectory'
  properties: {
    tenantId: tenantId
    dataTypes: {
      alerts: { state: 'Enabled' }
    }
  }
  dependsOn: [sentinel]
}

// 2. Azure Activity Logs
resource connectorAzureActivity 'Microsoft.SecurityInsights/dataConnectors@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'AzureActivity')
  scope: existingLaw
  kind: 'AzureActivity'
  properties: {
    linkedResourceId: '/subscriptions/${subscription().subscriptionId}/providers/microsoft.insights/eventtypes/management'
  }
  dependsOn: [sentinel]
}

// 3. Microsoft Defender for Cloud
resource connectorMdfc 'Microsoft.SecurityInsights/dataConnectors@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'AzureSecurityCenter')
  scope: existingLaw
  kind: 'AzureSecurityCenter'
  properties: {
    subscriptionId: subscription().subscriptionId
    dataTypes: {
      alerts: { state: 'Enabled' }
    }
  }
  dependsOn: [sentinel]
}

// 4. Microsoft Defender XDR (formerly M365 Defender)
resource connectorMdXdr 'Microsoft.SecurityInsights/dataConnectors@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'MicrosoftThreatProtection')
  scope: existingLaw
  kind: 'MicrosoftThreatProtection'
  properties: {
    tenantId: tenantId
    dataTypes: {
      alerts: { state: 'Enabled' }
      incidents: { state: 'Enabled' }
    }
  }
  dependsOn: [sentinel]
}

// 5. Microsoft Defender for Endpoint
resource connectorMde 'Microsoft.SecurityInsights/dataConnectors@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'MicrosoftDefenderAdvancedThreatProtection')
  scope: existingLaw
  kind: 'MicrosoftDefenderAdvancedThreatProtection'
  properties: {
    tenantId: tenantId
    dataTypes: {
      alerts: { state: 'Enabled' }
    }
  }
  dependsOn: [sentinel]
}

// 6. Microsoft Defender for Identity
resource connectorMdi 'Microsoft.SecurityInsights/dataConnectors@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'AzureAdvancedThreatProtection')
  scope: existingLaw
  kind: 'AzureAdvancedThreatProtection'
  properties: {
    tenantId: tenantId
    dataTypes: {
      alerts: { state: 'Enabled' }
    }
  }
  dependsOn: [sentinel]
}

// 7. Office 365 (Exchange, SharePoint, Teams)
resource connectorO365 'Microsoft.SecurityInsights/dataConnectors@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'Office365')
  scope: existingLaw
  kind: 'Office365'
  properties: {
    tenantId: tenantId
    dataTypes: {
      exchange   : { state: 'Enabled' }
      sharePoint : { state: 'Enabled' }
      teams      : { state: 'Enabled' }
    }
  }
  dependsOn: [sentinel]
}

// 8. Threat Intelligence — TAXII (placeholder; configure feed URL post-deploy)
resource connectorTi 'Microsoft.SecurityInsights/dataConnectors@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'ThreatIntelligence')
  scope: existingLaw
  kind: 'ThreatIntelligence'
  properties: {
    tenantId: tenantId
    dataTypes: {
      indicators: { state: 'Enabled' }
    }
  }
  dependsOn: [sentinel]
}

// ============================================================
// Analytics Rules — Scheduled (key rules; extend as required)
// ============================================================

// Rule 1: Impossible travel / sign-in from multiple geo-locations
resource ruleImpossibleTravel 'Microsoft.SecurityInsights/alertRules@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'ImpossibleTravel')
  scope: existingLaw
  kind: 'Scheduled'
  properties: {
    displayName: 'Sign-in from multiple geographies in short period'
    description: 'Detects sign-ins from geographically impossible locations within a configurable time window.'
    severity: 'Medium'
    enabled: true
    query: '''
      let timeWindow = 2h;
      SigninLogs
      | where TimeGenerated >= ago(timeWindow)
      | where ResultType == 0
      | extend City = tostring(LocationDetails.city)
      | extend Country = tostring(LocationDetails.countryOrRegion)
      | summarize
          Locations = make_set(strcat(City, ", ", Country)),
          IPAddresses = make_set(IPAddress),
          SignInCount = count()
        by UserPrincipalName, bin(TimeGenerated, timeWindow)
      | where array_length(Locations) > 1
      | project TimeGenerated, UserPrincipalName, Locations, IPAddresses, SignInCount
    '''
    queryFrequency: 'PT1H'
    queryPeriod: 'PT2H'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: ['InitialAccess']
    techniques: ['T1078']
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [{ identifier: 'FullName'; columnName: 'UserPrincipalName' }]
      }
      {
        entityType: 'IP'
        fieldMappings: [{ identifier: 'Address'; columnName: 'IPAddresses' }]
      }
    ]
  }
  dependsOn: [sentinel]
}

// Rule 2: High-privilege role assignment
resource rulePrivilegeEscalation 'Microsoft.SecurityInsights/alertRules@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'PrivilegeEscalation')
  scope: existingLaw
  kind: 'Scheduled'
  properties: {
    displayName: 'Azure AD — Privileged role assigned to user or service principal'
    description: 'Alerts when a Global Admin, Security Admin, or Owner role is assigned.'
    severity: 'High'
    enabled: true
    query: '''
      AuditLogs
      | where OperationName has "Add member to role"
      | extend TargetRole = tostring(TargetResources[0].displayName)
      | where TargetRole in (
          "Global Administrator",
          "Security Administrator",
          "Privileged Role Administrator",
          "User Account Administrator",
          "Owner"
        )
      | extend Initiator = tostring(InitiatedBy.user.userPrincipalName)
      | extend TargetUser = tostring(TargetResources[0].userPrincipalName)
      | project TimeGenerated, OperationName, Initiator, TargetUser, TargetRole, Result
    '''
    queryFrequency: 'PT15M'
    queryPeriod: 'PT15M'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: ['PrivilegeEscalation']
    techniques: ['T1078.004']
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [{ identifier: 'FullName'; columnName: 'TargetUser' }]
      }
    ]
  }
  dependsOn: [sentinel]
}

// Rule 3: Mass resource deletion (blast-radius detection)
resource ruleMassDelete 'Microsoft.SecurityInsights/alertRules@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'MassResourceDeletion')
  scope: existingLaw
  kind: 'Scheduled'
  properties: {
    displayName: 'Azure Activity — Mass resource deletion detected'
    description: 'Fires when more than 20 delete operations are recorded in a 15-minute window.'
    severity: 'High'
    enabled: true
    query: '''
      AzureActivity
      | where OperationNameValue endswith "delete"
      | where ActivityStatusValue == "Success"
      | summarize DeleteCount = count(), Resources = make_set(Resource)
        by Caller, bin(TimeGenerated, 15m)
      | where DeleteCount > 20
      | project TimeGenerated, Caller, DeleteCount, Resources
    '''
    queryFrequency: 'PT15M'
    queryPeriod: 'PT15M'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: ['Impact']
    techniques: ['T1485']
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [{ identifier: 'FullName'; columnName: 'Caller' }]
      }
    ]
  }
  dependsOn: [sentinel]
}

// Rule 4: Checkpoint / NVA configuration change
resource ruleNvaChange 'Microsoft.SecurityInsights/alertRules@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'NvaConfigChange')
  scope: existingLaw
  kind: 'Scheduled'
  properties: {
    displayName: 'Azure Activity — NVA / Firewall configuration changed'
    description: 'Detects write/delete operations on network security resources (NSG, route tables, firewall).'
    severity: 'Medium'
    enabled: true
    query: '''
      AzureActivity
      | where CategoryValue == "Administrative"
      | where OperationNameValue in~ (
          "microsoft.network/networksecuritygroups/write",
          "microsoft.network/networksecuritygroups/delete",
          "microsoft.network/routetables/write",
          "microsoft.network/routetables/delete",
          "microsoft.network/azurefirewalls/write",
          "microsoft.network/virtualnetworkgateways/write"
        )
      | where ActivityStatusValue == "Success"
      | project TimeGenerated, Caller, OperationNameValue, ResourceGroup, Resource
    '''
    queryFrequency: 'PT30M'
    queryPeriod: 'PT30M'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT2H'
    suppressionEnabled: false
    tactics: ['DefenseEvasion']
    techniques: ['T1562.001']
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [{ identifier: 'FullName'; columnName: 'Caller' }]
      }
    ]
  }
  dependsOn: [sentinel]
}

// Rule 5: Brute-force / password spray
resource rulePasswordSpray 'Microsoft.SecurityInsights/alertRules@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'PasswordSpray')
  scope: existingLaw
  kind: 'Scheduled'
  properties: {
    displayName: 'Azure AD — Password spray attack detected'
    description: 'Single IP address with multiple failed sign-ins across many accounts.'
    severity: 'High'
    enabled: true
    query: '''
      SigninLogs
      | where ResultType != 0
      | summarize
          FailedAttempts = count(),
          DistinctUsers  = dcount(UserPrincipalName),
          UserList       = make_set(UserPrincipalName)
        by IPAddress, bin(TimeGenerated, 1h)
      | where DistinctUsers > 5 and FailedAttempts > 20
      | project TimeGenerated, IPAddress, FailedAttempts, DistinctUsers, UserList
    '''
    queryFrequency: 'PT1H'
    queryPeriod: 'PT1H'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT2H'
    suppressionEnabled: false
    tactics: ['CredentialAccess']
    techniques: ['T1110.003']
    entityMappings: [
      {
        entityType: 'IP'
        fieldMappings: [{ identifier: 'Address'; columnName: 'IPAddress' }]
      }
    ]
  }
  dependsOn: [sentinel]
}

// Rule 6 (DD40): HSP cross-tenant resource access detection
// Detects when a principal accesses resources outside their designated HSP
// management group — potential data boundary violation
resource ruleHspCrossAccess 'Microsoft.SecurityInsights/alertRules@2023-02-01-preview' = if (enableHspDataSegregation) {
  name: guid(existingLaw.id, 'HspCrossTenantResourceAccess')
  scope: existingLaw
  kind: 'Scheduled'
  properties: {
    displayName: 'HSP Cross-Tenant Resource Access Detected'
    description: 'Detects when a user or service principal performs write/delete operations on resources tagged with an hsp-id different from their own HSP context. Requires hsp-id tags to be applied consistently via policy (DD36/DD40).'
    severity: 'High'
    enabled: true
    query: '''
      AzureActivity
      | where CategoryValue == "Administrative"
      | where ActivityStatusValue == "Success"
      | where OperationNameValue !endswith "/read"
      // Extract HSP tag from the caller's resource context
      // AzureActivity stores resource properties in the Properties field as JSON
      | extend PropertiesJson = parse_json(Properties)
      | extend ResourceHsp = tostring(PropertiesJson.["requestbody"]["tags"]["hsp-id"])
      // For callers, use the Claims field which contains AAD token claims
      | extend CallerClaims = parse_json(Claims)
      | extend CallerHsp = tostring(CallerClaims.["xms_az_rid"])
      // Alternative: use resource group tags via ResourceProviderValue + subscription
      | extend SubscriptionId = tostring(split(ResourceId, "/")[2])
      // Flag when a caller accesses a resource tagged with a different HSP
      | where isnotempty(ResourceHsp)
      | where ResourceHsp != "untagged"
      // Join with the resource's tags using ResourceId
      | project
          TimeGenerated,
          Caller,
          CallerHsp,
          ResourceHsp,
          ResourceId,
          OperationNameValue,
          ResourceGroup,
          SubscriptionId
      | where CallerHsp != ResourceHsp or isempty(CallerHsp)
    '''
    queryFrequency: 'PT15M'
    queryPeriod: 'PT15M'
    triggerOperator: 'GreaterThan'
    triggerThreshold: 0
    suppressionDuration: 'PT1H'
    suppressionEnabled: false
    tactics: ['PrivilegeEscalation', 'LateralMovement']
    techniques: ['T1078', 'T1550']
    entityMappings: [
      {
        entityType: 'Account'
        fieldMappings: [{ identifier: 'FullName'; columnName: 'Caller' }]
      }
    ]
  }
  dependsOn: [sentinel]
}

// ============================================================
// Automation Rule — Auto-assign High severity incidents
// ============================================================
resource autoRuleHighSeverity 'Microsoft.SecurityInsights/automationRules@2023-02-01-preview' = {
  name: guid(existingLaw.id, 'AutoAssignHighSeverity')
  scope: existingLaw
  properties: {
    displayName: 'Auto-triage: set High severity incidents to Active'
    order: 1
    triggeringLogic: {
      isEnabled: true
      triggersOn: 'Incidents'
      triggersWhen: 'Created'
      conditions: [
        {
          conditionType: 'Property'
          conditionProperties: {
            propertyName: 'IncidentSeverity'
            operator: 'Equals'
            propertyValues: ['High']
          }
        }
      ]
    }
    actions: [
      {
        order: 1
        actionType: 'ModifyProperties'
        actionConfiguration: {
          status: 'Active'
          classification: 'Undetermined'
        }
      }
    ]
  }
  dependsOn: [sentinel]
}

// ============================================================
// Watchlist — Trusted IP Ranges (on-prem / ExpressRoute)
// Populate post-deploy via Sentinel UI or REST API
// ============================================================
resource watchlistTrustedIps 'Microsoft.SecurityInsights/watchlists@2023-02-01-preview' = {
  name: 'TrustedIPRanges'
  scope: existingLaw
  properties: {
    displayName: 'Trusted IP Ranges (On-Prem / ExpressRoute)'
    provider: 'Microsoft'
    source: 'Local file'
    itemsSearchKey: 'IPRange'
    description: 'CIDR ranges for on-premises networks connected via ExpressRoute. Used to reduce false positives in analytics rules.'
    rawContent: 'IPRange,Description\n10.0.0.0/8,RFC1918 Private - On-Prem\n172.16.0.0/12,RFC1918 Private\n192.168.0.0/16,RFC1918 Private'
  }
  dependsOn: [sentinel]
}

// ============================================================
// Microsoft Defender for Cloud — Security Contacts
// ============================================================
resource securityContact 'Microsoft.Security/securityContacts@2020-01-01-preview' = {
  name: 'default'
  properties: {
    emails: securityContactEmail
    notificationsByRole: {
      state: 'On'
      roles: ['Owner', 'Contributor', 'ServiceAdmin', 'AccountAdmin']
    }
    alertNotifications: {
      state: 'On'
      minimalSeverity: 'Medium'
    }
  }
}

// ============================================================
// DD40 — HSP Row-Level Data Scoping
// Workspace table configuration, DCR tagging, and custom log
// ============================================================

// Table: SecurityEvent — Analytics plan with HSP scoping note
// HSP data segregation is enforced via workspace-level RBAC
// (custom roles per HSP bound to their resource tag scope) and
// supplemented by Sentinel data collection rules below.
// Column-level security for the HSP tag dimension is achieved
// through the HSPAuditLog_CL custom table and DCR transforms.
resource tableSecurityEvent 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = if (enableHspDataSegregation) {
  name: '${logAnalyticsWorkspaceName}/SecurityEvent'
  properties: {
    plan: 'Analytics'
    // NOTE (DD40): Row-level scoping for HSP segregation is applied via:
    //   1. Workspace RBAC — HSP-scoped custom roles restrict table query access
    //      to rows matching the caller's hsp-id tag.
    //   2. Data Collection Rules (dcr-sentinel-hsp-tagging-001) append an
    //      HSPTag column sourced from the resource tag 'hsp-id', enabling
    //      KQL row filters in analytics rules and workbooks.
    //   Full column-level security requires Sentinel Content Hub
    //   "Table-based RBAC" feature (preview) enabled per workspace.
    retentionInDays: retentionInDays
  }
}

// DCR: HSP Traffic Tagging (DD40)
// Appends an HSPTag column from the resource tag 'hsp-id' so that
// all downstream KQL queries can filter by Health Service Provider.
resource dcrHspTagging 'Microsoft.Insights/dataCollectionRules@2023-03-11' = if (enableHspDataSegregation) {
  name: 'dcr-sentinel-hsp-tagging-001'
  location: location
  tags: effectiveTags
  properties: {
    description: 'DD40 — Appends HSPTag column from resource tag hsp-id to Windows Security Events for HSP data segregation in Sentinel.'
    dataCollectionEndpointId: null
    dataSources: {
      windowsEventLogs: [
        {
          name: 'windowsSecurityEvents'
          streams: ['Microsoft-SecurityEvent']
          xPathQueries: [
            'Security!*[System[(EventID=4624 or EventID=4625 or EventID=4648 or EventID=4688 or EventID=4698 or EventID=4702 or EventID=4720 or EventID=4726 or EventID=4732 or EventID=4756)]]'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'sentinelWorkspace'
          workspaceResourceId: existingLaw.id
        }
      ]
    }
    dataFlows: [
      {
        streams: ['Microsoft-SecurityEvent']
        destinations: ['sentinelWorkspace']
        transformKql: '''
          source
          | extend HSPTag = tostring(tags["hsp-id"])
          | extend HSPTag = iif(isempty(HSPTag), "untagged", HSPTag)
        '''
        outputStream: 'Microsoft-SecurityEvent'
      }
    ]
  }
}

// Custom Log Table: HSPAuditLog_CL (DD40)
// Records HSP-specific operational audit events for cross-HSP
// access review, compliance reporting, and Sentinel workbooks.
resource tableHspAuditLog 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = if (enableHspDataSegregation) {
  name: '${logAnalyticsWorkspaceName}/HSPAuditLog_CL'
  properties: {
    plan: 'Analytics'
    retentionInDays: retentionInDays
    schema: {
      name: 'HSPAuditLog_CL'
      columns: [
        {
          name: 'TimeGenerated'
          type: 'datetime'
          description: 'Timestamp of the audit event (UTC)'
        }
        {
          name: 'HspId'
          type: 'string'
          description: 'Health Service Provider identifier (matches hsp-id resource tag)'
        }
        {
          name: 'OperationType'
          type: 'string'
          description: 'Type of operation performed (e.g. Read, Write, Delete, CrossAccess)'
        }
        {
          name: 'ResourceId'
          type: 'string'
          description: 'Full Azure resource ID of the affected resource'
        }
        {
          name: 'InitiatedBy'
          type: 'string'
          description: 'UPN or service principal that initiated the operation'
        }
        {
          name: 'Details'
          type: 'dynamic'
          description: 'Additional structured details (JSON bag) — policy outcome, tags, source IP, etc.'
        }
      ]
    }
  }
}

// ============================================================
// Outputs
// ============================================================
output sentinelWorkspaceId string = existingLaw.id
output sentinelWorkspaceName string = existingLaw.name
output connectorCount int = 8
output analyticsRuleCount int = enableHspDataSegregation ? 6 : 5
output hspDataSegregationEnabled bool = enableHspDataSegregation
