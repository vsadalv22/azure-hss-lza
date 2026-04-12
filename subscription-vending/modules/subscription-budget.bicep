// =============================================================
// Module: Subscription Budget with alerts at 80% and 100%
// =============================================================

@description('Subscription ID')
param subscriptionId string

@description('Budget resource name')
param budgetName string

@description('Monthly budget amount in AUD')
param amountAUD int

@description('Email for budget alerts')
param contactEmail string

@description('Subscription alias — used in alert display name')
param subscriptionAlias string

resource budget 'Microsoft.Consumption/budgets@2023-11-01' = {
  name: budgetName
  scope: subscription(subscriptionId)
  properties: {
    category   : 'Cost'
    amount     : amountAUD
    timeGrain  : 'Monthly'
    timePeriod : {
      startDate: '${substring(utcNow('yyyy-MM-dd'), 0, 7)}-01'   // First day of current month
    }
    filter: {}
    notifications: {
      // Alert at 80% forecast
      forecastAt80: {
        enabled     : true
        operator    : 'GreaterThan'
        threshold   : 80
        thresholdType: 'Forecasted'
        contactEmails: [contactEmail]
        contactRoles : ['Owner', 'Contributor']
      }
      // Alert at 100% actual spend
      actualAt100: {
        enabled     : true
        operator    : 'GreaterThan'
        threshold   : 100
        thresholdType: 'Actual'
        contactEmails: [contactEmail]
        contactRoles : ['Owner', 'Contributor']
      }
      // Alert at 120% actual spend — escalation
      actualAt120: {
        enabled     : true
        operator    : 'GreaterThan'
        threshold   : 120
        thresholdType: 'Actual'
        contactEmails: [contactEmail]
        contactRoles : ['Owner', 'Contributor', 'AccountAdmin']
      }
    }
  }
}

output budgetId string = budget.id
