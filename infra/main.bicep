@description('Location for all resources')
param location string = resourceGroup().location

@description('Location for Cosmos DB account (defaults to same as other resources)')
param cosmosLocation string = ''

@description('Name prefix for resources')
param namePrefix string = 'cosmosmsiscale'

@description('AKS node count')
param aksNodeCount int = 3

@description('AKS node VM size')
param aksNodeSize string = 'standard_d2_v3'

@description('Principal ID of the user deploying the template (for Grafana access)')
param deployerPrincipalId string = ''

// Variables
var acrName = '${namePrefix}acr${uniqueString(resourceGroup().id)}'
var cosmosAccountName = '${namePrefix}cosmos${uniqueString(resourceGroup().id)}'
var aksClusterName = '${namePrefix}-aks'
var managedIdentityName = '${namePrefix}-identity'
var monitorWorkspaceName = '${namePrefix}-monitor-${uniqueString(resourceGroup().id)}'
var grafanaName = 'grf-${uniqueString(resourceGroup().id)}'
var actualCosmosLocation = empty(cosmosLocation) ? location : cosmosLocation

// Azure Container Registry
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

// Cosmos DB Account with Table API
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: cosmosAccountName
  location: actualCosmosLocation
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    disableLocalAuth: true
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
    locations: [
      {
        locationName: location
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    capabilities: [
      {
        name: 'EnableTable'
      }
    ]
  }
}

// Managed Identity for pods
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: managedIdentityName
  location: location
}

// AKS Cluster with Azure Overlay Networking
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: aksClusterName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    dnsPrefix: aksClusterName
    agentPoolProfiles: [
      {
        name: 'nodepool1'
        count: aksNodeCount
        vmSize: aksNodeSize
        mode: 'System'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
      podCidrs: [
        '10.244.0.0/16'
      ]
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    azureMonitorProfile: {
      metrics: {
        enabled: true
        kubeStateMetrics: {
          metricLabelsAllowlist: ''
          metricAnnotationsAllowList: ''
        }
      }
    }
  }
  dependsOn: [
    monitorWorkspace
  ]
}

// Grant AKS access to pull from ACR
resource acrPullRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aksCluster.id, 'acrpull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d') // AcrPull role
    principalId: aksCluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

// Grant the kubelet managed identity access to Cosmos DB - Data Contributor role
resource cosmosRoleAssignment 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmosAccount
  name: guid(aksCluster.id, cosmosAccount.id, 'contributor')
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000002' // Cosmos DB Built-in Data Contributor
    principalId: aksCluster.properties.identityProfile.kubeletidentity.objectId
    scope: cosmosAccount.id
  }
}

// Grant the kubelet managed identity access to Cosmos DB - Data Reader role
resource cosmosRoleAssignmentReader 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmosAccount
  name: guid(aksCluster.id, cosmosAccount.id, 'reader')
  properties: {
    roleDefinitionId: '${cosmosAccount.id}/sqlRoleDefinitions/00000000-0000-0000-0000-000000000001' // Cosmos DB Built-in Data Reader
    principalId: aksCluster.properties.identityProfile.kubeletidentity.objectId
    scope: cosmosAccount.id
  }
}

// Azure Monitor Workspace for Prometheus metrics
resource monitorWorkspace 'Microsoft.Monitor/accounts@2023-04-03' = {
  name: monitorWorkspaceName
  location: location
  properties: {}
}

// Data Collection Endpoint for Prometheus metrics
resource dataCollectionEndpoint 'Microsoft.Insights/dataCollectionEndpoints@2022-06-01' = {
  name: '${namePrefix}-dce'
  location: location
  properties: {
    networkAcls: {
      publicNetworkAccess: 'Enabled'
    }
  }
}

// Data Collection Rule for scraping Prometheus metrics from AKS
resource dataCollectionRule 'Microsoft.Insights/dataCollectionRules@2022-06-01' = {
  name: '${namePrefix}-dcr'
  location: location
  properties: {
    dataCollectionEndpointId: dataCollectionEndpoint.id
    dataSources: {
      prometheusForwarder: [
        {
          name: 'PrometheusDataSource'
          streams: [
            'Microsoft-PrometheusMetrics'
          ]
          labelIncludeFilter: {}
        }
      ]
    }
    destinations: {
      monitoringAccounts: [
        {
          accountResourceId: monitorWorkspace.id
          name: 'MonitoringAccount'
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-PrometheusMetrics'
        ]
        destinations: [
          'MonitoringAccount'
        ]
      }
    ]
  }
}

// Associate DCR with AKS cluster
resource dataCollectionRuleAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2022-06-01' = {
  name: 'configurationAccessEndpoint'
  scope: aksCluster
  properties: {
    dataCollectionRuleId: dataCollectionRule.id
  }
}

// Azure Managed Grafana
resource grafana 'Microsoft.Dashboard/grafana@2023-09-01' = {
  name: grafanaName
  location: location
  sku: {
    name: 'Standard'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    grafanaIntegrations: {
      azureMonitorWorkspaceIntegrations: [
        {
          azureMonitorWorkspaceResourceId: monitorWorkspace.id
        }
      ]
    }
  }
}

// Grant Grafana Monitoring Reader role on the Monitor workspace
resource grafanaMonitoringReaderRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(grafana.id, monitorWorkspace.id, 'MonitoringReader')
  scope: monitorWorkspace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05') // Monitoring Reader
    principalId: grafana.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Grant Grafana Admin role to the deployer user (if provided)
resource grafanaAdminRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (deployerPrincipalId != '') {
  name: guid(grafana.id, deployerPrincipalId, 'GrafanaAdmin')
  scope: grafana
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '22926164-76b3-42b3-bc55-97df8dab3e41') // Grafana Admin
    principalId: deployerPrincipalId
    principalType: 'User'
  }
}

// Outputs
output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output cosmosAccountName string = cosmosAccount.name
output cosmosAccountUrl string = 'https://${cosmosAccount.name}.table.cosmos.azure.com'
output aksClusterName string = aksCluster.name
output managedIdentityName string = managedIdentity.name
output managedIdentityClientId string = managedIdentity.properties.clientId
output kubeletIdentityClientId string = aksCluster.properties.identityProfile.kubeletidentity.clientId
output kubeletIdentityResourceId string = aksCluster.properties.identityProfile.kubeletidentity.resourceId
output aksOidcIssuerUrl string = aksCluster.properties.oidcIssuerProfile.issuerURL
output grafanaName string = grafana.name
output grafanaUrl string = grafana.properties.endpoint
output monitorWorkspaceName string = monitorWorkspace.name
output monitorWorkspaceId string = monitorWorkspace.id
