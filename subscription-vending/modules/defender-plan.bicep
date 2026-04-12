// =============================================================
// Module: Enable a Microsoft Defender for Cloud plan
// Deployed as a nested subscription-scope resource
// =============================================================

@description('Subscription ID to enable Defender on')
param subscriptionId string

@description('Defender plan name — VirtualMachines | StorageAccounts | KeyVaults | SqlServers | Containers | Dns | Arm')
param planName string

@description('Pricing tier: Standard | Free')
@allowed(['Standard', 'Free'])
param pricingTier string = 'Standard'

@description('Sub-plan (only applicable to VirtualMachines): P1 | P2')
param subPlanName string = ''

resource defenderPlan 'Microsoft.Security/pricings@2023-01-01' = {
  name: planName
  scope: subscription(subscriptionId) // workaround — deploy in target sub via nested deployment
  properties: {
    pricingTier: pricingTier
    subPlan: empty(subPlanName) ? null : subPlanName
  }
}

output defenderPlanId string = defenderPlan.id
