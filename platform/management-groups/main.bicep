targetScope = 'tenant'

// ============================================================
// Azure Landing Zone - Management Group Hierarchy
// Region: Australia East | EA Agreement
// ============================================================

@description('Root management group ID prefix')
param rootManagementGroupId string = 'alz'

@description('Root management group display name')
param rootManagementGroupDisplayName string = 'Azure Landing Zones'

// ---- Root Management Group ----
resource rootMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: rootManagementGroupId
  properties: {
    displayName: rootManagementGroupDisplayName
  }
}

// ---- Platform ----
resource platformMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${rootManagementGroupId}-platform'
  properties: {
    displayName: 'Platform'
    details: {
      parent: {
        id: rootMg.id
      }
    }
  }
}

resource managementMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${rootManagementGroupId}-platform-management'
  properties: {
    displayName: 'Management'
    details: {
      parent: {
        id: platformMg.id
      }
    }
  }
}

resource connectivityMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${rootManagementGroupId}-platform-connectivity'
  properties: {
    displayName: 'Connectivity'
    details: {
      parent: {
        id: platformMg.id
      }
    }
  }
}

resource identityMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${rootManagementGroupId}-platform-identity'
  properties: {
    displayName: 'Identity'
    details: {
      parent: {
        id: platformMg.id
      }
    }
  }
}

// ---- Landing Zones ----
resource landingZonesMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${rootManagementGroupId}-landingzones'
  properties: {
    displayName: 'Landing Zones'
    details: {
      parent: {
        id: rootMg.id
      }
    }
  }
}

resource corpMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${rootManagementGroupId}-landingzones-corp'
  properties: {
    displayName: 'Corp'
    details: {
      parent: {
        id: landingZonesMg.id
      }
    }
  }
}

resource onlineMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${rootManagementGroupId}-landingzones-online'
  properties: {
    displayName: 'Online'
    details: {
      parent: {
        id: landingZonesMg.id
      }
    }
  }
}

// ---- Sandbox ----
resource sandboxMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${rootManagementGroupId}-sandbox'
  properties: {
    displayName: 'Sandbox'
    details: {
      parent: {
        id: rootMg.id
      }
    }
  }
}

// ---- Decommissioned ----
resource decommissionedMg 'Microsoft.Management/managementGroups@2023-04-01' = {
  name: '${rootManagementGroupId}-decommissioned'
  properties: {
    displayName: 'Decommissioned'
    details: {
      parent: {
        id: rootMg.id
      }
    }
  }
}

// ---- Outputs ----
output rootManagementGroupId string = rootMg.id
output platformManagementGroupId string = platformMg.id
output connectivityManagementGroupId string = connectivityMg.id
output landingZonesManagementGroupId string = landingZonesMg.id
output corpManagementGroupId string = corpMg.id
output onlineManagementGroupId string = onlineMg.id
