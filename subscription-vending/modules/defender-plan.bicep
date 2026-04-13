targetScope = 'subscription'

@description('Microsoft Defender for Cloud pricing tier name')
@allowed([
  'VirtualMachines'
  'StorageAccounts'
  'KeyVaults'
  'SqlServers'
  'SqlServerVirtualMachines'
  'Containers'
  'AppServices'
  'Dns'
  'Arm'
  'OpenSourceRelationalDatabases'
  'CosmosDbs'
])
param pricingTierName string

@description('Pricing tier: Free or Standard')
@allowed(['Free', 'Standard'])
param pricingTier string = 'Standard'

@description('Sub-plan for VirtualMachines: P1 (Foundational) or P2 (Enhanced)')
@allowed(['P1', 'P2', ''])
param subPlan string = ''

resource defenderPlan 'Microsoft.Security/pricings@2023-01-01' = {
  name: pricingTierName
  properties: {
    pricingTier: pricingTier
    subPlan: empty(subPlan) ? null : subPlan
  }
}

output defenderPlanId string = defenderPlan.id
output defenderPlanName string = defenderPlan.name
output pricingState string = defenderPlan.properties.pricingTier
