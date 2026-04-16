// ============================================================
// Subnet Configuration — User-Defined Types
// Import these types in parent modules for type-safe subnet
// configuration.
// ============================================================

@export()
type SubnetConfig = {
  @description('Subnet name')
  name: string

  @description('Subnet address prefix (derived via cidrSubnet() in parent)')
  addressPrefix: string

  @description('NSG resource ID — leave empty for GatewaySubnet (not permitted)')
  networkSecurityGroupResourceId: string?

  @description('Route table resource ID — leave empty for GatewaySubnet')
  routeTableResourceId: string?

  @description('Service endpoints (e.g. Microsoft.Storage, Microsoft.KeyVault)')
  serviceEndpoints: string[]?

  @description('Private endpoint network policies — Disabled required for private endpoints')
  privateEndpointNetworkPolicies: 'Disabled' | 'Enabled' | 'NetworkSecurityGroupEnabled' | 'RouteTableEnabled'?

  @description('Private link service network policies')
  privateLinkServiceNetworkPolicies: 'Disabled' | 'Enabled'?
}
