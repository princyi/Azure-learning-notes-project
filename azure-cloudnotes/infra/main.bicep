// CloudNotes core infrastructure
// Deploy: az deployment group create -g <rg> -f main.bicep -p main.bicepparam
targetScope = 'resourceGroup'

@description('Short name used as prefix for all resources (3-10 lowercase letters/numbers).')
@minLength(3)
@maxLength(10)
param appName string = 'cloudnotes'

@description('Environment name.')
@allowed(['dev', 'test', 'prod'])
param env string = 'dev'

@description('Azure region.')
param location string = resourceGroup().location

var suffix = uniqueString(resourceGroup().id)
var baseName = '${appName}-${env}'
var tags = {
  app: appName
  env: env
  purpose: 'azure-learning'
}

// ---------------------------------------------------------------
// PHASE 8: Monitoring (Log Analytics + Application Insights)
// ---------------------------------------------------------------
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'log-${baseName}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInYears: null
    retentionInDays: 30
  }
}

resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: 'appi-${baseName}'
  location: location
  kind: 'web'
  tags: tags
  properties: {
    Application_Type: 'web'
    WorkspaceResourceId: logs.id
  }
}

// ---------------------------------------------------------------
// PHASE 2: Storage (Blob attachments + Function runtime storage)
// ---------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: toLower('st${appName}${take(suffix, 8)}')
  location: location
  tags: tags
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    supportsHttpsTrafficOnly: true
    accessTier: 'Hot'
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource attachmentsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'attachments'
  properties: { publicAccess: 'None' }
}

// Lifecycle: move to Cool after 30 days, delete after 365
resource lifecycle 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'age-out-attachments'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: { blobTypes: ['blockBlob'], prefixMatch: ['attachments/'] }
            actions: {
              baseBlob: {
                tierToCool: { daysAfterModificationGreaterThan: 30 }
                delete: { daysAfterModificationGreaterThan: 365 }
              }
            }
          }
        }
      ]
    }
  }
}

// ---------------------------------------------------------------
// PHASE 4: Cosmos DB (serverless NoSQL)
// ---------------------------------------------------------------
resource cosmos 'Microsoft.DocumentDB/databaseAccounts@2024-05-15' = {
  name: 'cosmos-${baseName}-${take(suffix, 6)}'
  location: location
  tags: tags
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    capabilities: [{ name: 'EnableServerless' }]
    consistencyPolicy: { defaultConsistencyLevel: 'Session' }
    locations: [
      { locationName: location, failoverPriority: 0, isZoneRedundant: false }
    ]
    disableLocalAuth: true // force Entra ID / managed identity auth
  }
}

resource cosmosDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2024-05-15' = {
  parent: cosmos
  name: 'cloudnotes'
  properties: {
    resource: { id: 'cloudnotes' }
  }
}

resource notesContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2024-05-15' = {
  parent: cosmosDb
  name: 'notes'
  properties: {
    resource: {
      id: 'notes'
      partitionKey: { paths: ['/userId'], kind: 'Hash' }
    }
  }
}

// ---------------------------------------------------------------
// PHASE 6: Service Bus (queue for note processing)
// ---------------------------------------------------------------
resource sbNamespace 'Microsoft.ServiceBus/namespaces@2022-10-01-preview' = {
  name: 'sb-${baseName}-${take(suffix, 6)}'
  location: location
  tags: tags
  sku: { name: 'Standard', tier: 'Standard' }
  properties: { disableLocalAuth: true }
}

resource noteQueue 'Microsoft.ServiceBus/namespaces/queues@2022-10-01-preview' = {
  parent: sbNamespace
  name: 'note-processing'
  properties: {
    maxDeliveryCount: 5 // after 5 failures -> dead-letter queue
    lockDuration: 'PT1M'
    deadLetteringOnMessageExpiration: true
  }
}

// ---------------------------------------------------------------
// PHASE 7: Key Vault (RBAC mode) and secrets
// ---------------------------------------------------------------
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${appName}-${take(suffix, 8)}'
  location: location
  tags: tags
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
  }
}

// ---------------------------------------------------------------
// PHASE 3: ACR + App Service (API) + Function App
// ---------------------------------------------------------------
resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: toLower('acr${appName}${take(suffix, 8)}')
  location: location
  tags: tags
  sku: { name: 'Basic' }
  properties: { adminUserEnabled: false }
}

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-${baseName}'
  location: location
  tags: tags
  kind: 'linux'
  sku: { name: 'B1', tier: 'Basic' }
  properties: { reserved: true }
}

resource api 'Microsoft.Web/sites@2023-12-01' = {
  name: 'app-${baseName}-${take(suffix, 6)}'
  location: location
  tags: tags
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      appCommandLine: 'uvicorn main:app --host 0.0.0.0 --port 8000'
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      appSettings: [
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'COSMOS_ENDPOINT', value: cosmos.properties.documentEndpoint }
        { name: 'COSMOS_DATABASE', value: 'cloudnotes' }
        { name: 'COSMOS_CONTAINER', value: 'notes' }
        { name: 'STORAGE_ACCOUNT_URL', value: storage.properties.primaryEndpoints.blob }
        { name: 'BLOB_CONTAINER', value: 'attachments' }
        { name: 'SERVICEBUS_FQDN', value: '${sbNamespace.name}.servicebus.windows.net' }
        { name: 'SERVICEBUS_QUEUE', value: 'note-processing' }
        { name: 'WEBSITES_PORT', value: '8000' }
        { name: 'SCM_DO_BUILD_DURING_DEPLOYMENT', value: 'true' }
      ]
    }
  }
}

// Function app on Consumption (Y1) plan
resource funcPlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: 'asp-func-${baseName}'
  location: location
  tags: tags
  kind: 'linux'
  sku: { name: 'Y1', tier: 'Dynamic' }
  properties: { reserved: true }
}

resource func 'Microsoft.Web/sites@2023-12-01' = {
  name: 'func-${baseName}-${take(suffix, 6)}'
  location: location
  tags: tags
  kind: 'functionapp,linux'
  identity: { type: 'SystemAssigned' }
  properties: {
    serverFarmId: funcPlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'PYTHON|3.11'
      minTlsVersion: '1.2'
      appSettings: [
        { name: 'AzureWebJobsStorage__accountName', value: storage.name }
        { name: 'FUNCTIONS_EXTENSION_VERSION', value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME', value: 'python' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'ServiceBusConnection__fullyQualifiedNamespace', value: '${sbNamespace.name}.servicebus.windows.net' }
        { name: 'COSMOS_ENDPOINT', value: cosmos.properties.documentEndpoint }
        { name: 'COSMOS_DATABASE', value: 'cloudnotes' }
        { name: 'COSMOS_CONTAINER', value: 'notes' }
      ]
    }
  }
}

// ---------------------------------------------------------------
// PHASE 3: Container Apps environment (serverless containers)
// ---------------------------------------------------------------
resource caEnv 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: 'cae-${baseName}'
  location: location
  tags: tags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logs.properties.customerId
        sharedKey: logs.listKeys().primarySharedKey
      }
    }
  }
}

// ---------------------------------------------------------------
// PHASE 1/7: RBAC. Give identities least-privilege access (no keys!)
// ---------------------------------------------------------------
var roles = {
  storageBlobContributor: 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
  storageQueueContributor: '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageAccountContributor: '17d1049b-9a84-46fb-8f53-869881c3d3ab'
  storageBlobDataOwner: 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  serviceBusSender: '69a216fc-b8fb-44d8-bc22-1f3c2cd27a39'
  serviceBusReceiver: '4f6d3b9b-027b-4f4c-9142-0e5a2a2247e0'
  keyVaultSecretsUser: '4633458b-17de-408a-b874-0f5a7d5a1c5b'
  acrPull: '7f951dda-4ed3-4680-a7ca-43fe172d538d'
}

resource apiBlob 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, api.id, roles.storageBlobContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobContributor)
    principalId: api.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource apiSb 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbNamespace.id, api.id, roles.serviceBusSender)
  scope: sbNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.serviceBusSender)
    principalId: api.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource apiKv 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVault.id, api.id, roles.keyVaultSecretsUser)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.keyVaultSecretsUser)
    principalId: api.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource funcSb 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sbNamespace.id, func.id, roles.serviceBusReceiver)
  scope: sbNamespace
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.serviceBusReceiver)
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource funcStorageOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, func.id, roles.storageBlobDataOwner)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageBlobDataOwner)
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

resource funcStorageQueue 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(storage.id, func.id, roles.storageQueueContributor)
  scope: storage
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roles.storageQueueContributor)
    principalId: func.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

// Cosmos DB uses its own data-plane RBAC (built-in Data Contributor role)
var cosmosDataContributor = '00000000-0000-0000-0000-000000000002'

resource apiCosmos 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmos
  name: guid(cosmos.id, api.id, cosmosDataContributor)
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${cosmosDataContributor}'
    principalId: api.identity.principalId
    scope: cosmos.id
  }
}

resource funcCosmos 'Microsoft.DocumentDB/databaseAccounts/sqlRoleAssignments@2024-05-15' = {
  parent: cosmos
  name: guid(cosmos.id, func.id, cosmosDataContributor)
  properties: {
    roleDefinitionId: '${cosmos.id}/sqlRoleDefinitions/${cosmosDataContributor}'
    principalId: func.identity.principalId
    scope: cosmos.id
  }
}

// ---------------------------------------------------------------
// PHASE 8: Diagnostic settings + a simple alert
// ---------------------------------------------------------------
resource sbDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: sbNamespace
  properties: {
    workspaceId: logs.id
    logs: [{ categoryGroup: 'allLogs', enabled: true }]
    metrics: [{ category: 'AllMetrics', enabled: true }]
  }
}

resource alertActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-${baseName}'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'cnotes'
    enabled: true
    emailReceivers: []
  }
}

resource deadLetterAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-${baseName}-deadletters'
  location: 'global'
  tags: tags
  properties: {
    description: 'Fires when messages land in the dead-letter queue.'
    severity: 2
    enabled: true
    scopes: [sbNamespace.id]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'DeadLetters'
          metricName: 'DeadletteredMessages'
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Maximum'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    actions: [{ actionGroupId: alertActionGroup.id }]
  }
}

// ---------------------------------------------------------------
// PHASE 6: Event Grid system topic (blob created -> events)
// ---------------------------------------------------------------
resource storageTopic 'Microsoft.EventGrid/systemTopics@2022-06-15' = {
  name: 'evgt-${baseName}-storage'
  location: location
  tags: tags
  properties: {
    source: storage.id
    topicType: 'Microsoft.Storage.StorageAccounts'
  }
}

// ---------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------
output apiName string = api.name
output apiUrl string = 'https://${api.properties.defaultHostName}'
output functionAppName string = func.name
output cosmosEndpoint string = cosmos.properties.documentEndpoint
output storageAccountName string = storage.name
output serviceBusNamespace string = '${sbNamespace.name}.servicebus.windows.net'
output keyVaultName string = keyVault.name
output acrLoginServer string = acr.properties.loginServer
output appInsightsName string = appInsights.name
output logAnalyticsName string = logs.name
