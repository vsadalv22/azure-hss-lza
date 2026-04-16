// ============================================================
// NSG Security Rule — User-Defined Type
// Import this type in parent modules for type-safe NSG rules
//
// Usage:
//   import { NsgRule } from './modules/nsg-rule.bicep'
//   param securityRules NsgRule[] = []
// ============================================================

@export()
type NsgRule = {
  @description('Rule name — unique within the NSG')
  name: string

  @description('Priority: 100–4096. Lower = higher priority.')
  priority: int

  @description('Protocol: Tcp | Udp | Icmp | *')
  protocol: 'Tcp' | 'Udp' | 'Icmp' | '*'

  @description('Access: Allow | Deny')
  access: 'Allow' | 'Deny'

  @description('Direction: Inbound | Outbound')
  direction: 'Inbound' | 'Outbound'

  @description('Source address prefix or service tag (e.g. 10.0.0.0/8, VirtualNetwork, Internet, *)')
  sourceAddressPrefix: string?

  @description('Multiple source address prefixes — use instead of sourceAddressPrefix for multiple')
  sourceAddressPrefixes: string[]?

  @description('Source port range (* for any)')
  sourcePortRange: string?

  @description('Multiple source port ranges')
  sourcePortRanges: string[]?

  @description('Destination address prefix or service tag')
  destinationAddressPrefix: string?

  @description('Multiple destination address prefixes')
  destinationAddressPrefixes: string[]?

  @description('Destination port range')
  destinationPortRange: string?

  @description('Multiple destination port ranges')
  destinationPortRanges: string[]?

  @description('Optional human-readable description of the rule purpose')
  description: string?
}
