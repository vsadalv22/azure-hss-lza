targetScope = 'resourceGroup'

// ============================================================
// ExpressRoute Connection — Gateway <--> Manually-created Circuit
//
// Run this ONLY after:
//   1. ER circuit has been created manually (Portal / CLI)
//   2. Service key has been sent to the provider
//   3. Provider has set circuit status to "Provisioned"
//
// Triggered via workflow: 03b-platform-er-connection
//
// Design decisions implemented:
//   DD18 — ExpressRoute Direct with MACsec (configuration note)
//   DD23 — BFD Fast Failover (always-on in Azure, documented below)
// ============================================================

@description('ExpressRoute Gateway resource ID (output from workflow 03)')
param erGatewayId string

@description('ExpressRoute circuit resource ID (from manually-created circuit)')
param erCircuitResourceId string

@description('Connection name')
param connectionName string = 'con-ergw-to-circuit-001'

@description('Azure region')
param location string = 'australiaeast'

@description('Routing weight — leave at 0 for default BGP preference')
param routingWeight int = 0

@description('Log Analytics workspace resource ID for diagnostics')
param logAnalyticsWorkspaceId string

// ---- DD23: BFD Fast Failover ----
// BFD (Bidirectional Forwarding Detection) is ALWAYS ENABLED by default
// on Azure ExpressRoute connections and cannot be disabled via ARM/Bicep.
// Azure automatically negotiates BFD with the CE router during BGP session
// establishment. No explicit ARM property is required.
// Reference: https://docs.microsoft.com/azure/expressroute/expressroute-bfd
//
// The param below is informational / for documentation purposes.
// Setting expressRouteGatewayBypass: false (see connection properties)
// ensures traffic flows through the gateway (not FastPath bypass) which
// is required for BFD to function correctly end-to-end.
@description('DD23: Ensure traffic flows through the ER gateway (required for BFD). Set false to disable FastPath bypass.')
param enableBgpFastFailover bool = true

// ⚠ MACsec NOTE (DD18):
// MACsec encryption applies to ExpressRoute DIRECT port pairs (physical layer).
// It is configured on Microsoft.Network/expressRoutePorts — NOT on this connection resource.
// The ExpressRoute circuit and port are created MANUALLY by the network team.
// To configure MACsec on the port after manual circuit creation, run:
//
//   az network express-route port update \
//     --resource-group <rg> \
//     --name <port-name> \
//     --macsec-cipher GcmAes256 \
//     --macsec-cak-secret-identifier <keyvault-uri> \
//     --macsec-ckn-secret-identifier <keyvault-uri>
//
// The params below are retained to document the intended configuration in code.
// They do NOT affect the ARM deployment of this connection resource.
@description('DD18: MACsec applicable to ExpressRoute Direct ports only. Set true to document intent; actual config is on the port resource (manual). (INFORMATIONAL: MACsec is configured on the ExpressRoute Direct port resource, not this connection. This param is used only for runbook documentation.)')
param enableMacsec bool = false

@description('DD18: Key Vault secret URI for MACsec CKN (Connectivity Association Key Name). ExpressRoute Direct ports only.')
param macsecCknSecretIdentifier string = ''

@description('DD18: Key Vault secret URI for MACsec CAK (Connectivity Association Key). ExpressRoute Direct ports only.')
param macsecCakSecretIdentifier string = ''

@description('DD18: MACsec cipher suite. GcmAes128 | GcmAes256. GcmAes256 recommended for TS classification levels.')
@allowed(['GcmAes128', 'GcmAes256'])
param macsecCipher string = 'GcmAes256'

// ---- Custom BGP routing configuration ----
// Provide custom BGP community tags or specific route filters.
// Leave empty ({}) for default routing behaviour.
// Example:
//   routingConfiguration: {
//     associatedRouteTable: { id: '/subscriptions/.../routeTables/rt-er-001' }
//     propagatedRouteTables: { ids: [...] }
//     vnetRoutes: { staticRoutes: [] }
//   }
@description('Custom BGP routing configuration for the connection. Leave empty for default.')
param routingConfiguration object = {}

@description('Resource tags')
param tags object = {
  environment: 'connectivity'
  managedBy  : 'platform-team'
  createdBy  : 'alz-bicep'
}

// ============================================================
// ExpressRoute Connection
// ============================================================
resource erConnection 'Microsoft.Network/connections@2023-09-01' = {
  name: connectionName
  location: location
  tags: tags
  properties: {
    connectionType: 'ExpressRoute'
    virtualNetworkGateway1: {
      id        : erGatewayId
      properties: {}
    }
    peer: {
      id: erCircuitResourceId
    }
    routingWeight: routingWeight

    // DD23 — BFD Fast Failover
    // expressRouteGatewayBypass: false ensures all traffic flows through
    // the ER gateway (not FastPath). FastPath bypass would short-circuit
    // the gateway, preventing BFD echo packets from being processed.
    // BFD itself is always-on in Azure; no ARM property needed.
    expressRouteGatewayBypass: !enableBgpFastFailover

    // Custom BGP routing configuration (optional)
    // Conditionally included only when caller provides a non-empty object.
    routingConfiguration: empty(routingConfiguration) ? null : routingConfiguration
  }
}

// ---- Diagnostics on the connection ----
resource erConnectionDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name  : 'diag-${connectionName}'
  scope : erConnection
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    metrics: [
      { category: 'AllMetrics'; enabled: true; retentionPolicy: { days: 365; enabled: true } }
    ]
  }
}

// ============================================================
// MACsec documentation output (DD18)
// The following output surfaces MACsec intent for the ops runbook.
// Actual MACsec config is on the ExpressRoute Direct port (manual step).
// ============================================================
output macsecConfigured     bool   = enableMacsec
output macsecCipher         string = enableMacsec ? macsecCipher : 'N/A - MACsec not enabled or not ExpressRoute Direct'
// Intentionally NOT outputting secret identifiers to avoid exposure in deployment history.

// ============================================================
// Outputs
// ============================================================
output erConnectionId   string = erConnection.id
output erConnectionName string = erConnection.name
