@description('The resource group of the media account')
param mediaAccountRG string

@description('Azure Media Services account name')
param mediaAccountName string

@description('The subscription of the media account')
param mediaAccountSubscription string = subscription().subscriptionId

@description('The storage account where the migrated data is written')
param storageAccountName string

@description('The resource group of storage account where the migrated data is written')
param storageAccountRG string

@description('The resource group of the storage account')
param storageAccountSubscription string = subscription().subscriptionId

@description('The region where the Azure media services account is present')
param location string = resourceGroup().location

@description('Set to true if you need to encrypt the content')
param encrypt bool = true

@description('The key vault to store the envcryption keys')
param keyvaultName string

@description('The resource group where key vault is present.')
param keyvaultRG string

@description('The subscription where the key vault is present.')
param keyvaultSubscription string = subscription().subscriptionId

@description('Additional command line arguments to pass')
param arguments array = []

var tags = {
  name: 'azure-media-migration',
  owner: 'Core-Platform'
}

// The identity to create and the roles to assign.
var identifier = 'azure-media-migration'
var mediaRoleName =  'Contributor'
var storageRoleName = 'Storage Blob Data Contributor'
var keyVaultRoleName = 'Key Vault Secrets Officer'

// Parameters for the container creation.
var cpus = 4
var memoryInGB = 16
var image = 'ghcr.io/azure/azure-media-migration:main'

resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name:  'azure-media-migration-identity'
  location: location
  tags: tags
}

resource mediaAccount 'Microsoft.Media/mediaservices@2023-01-01' existing = {
  scope: resourceGroup(mediaAccountSubscription, mediaAccountRG)
  name: mediaAccountName
}

module mediaRoleAssignment 'roleassignment.bicep' = {
  scope: resourceGroup(mediaAccountSubscription, mediaAccountRG)
  name: 'mediaRoleAssignement'
  params: {
    resourceName: mediaAccountName
    principalId: managedIdentity.properties.principalId
    roleName: mediaRoleName
    storage: false
    assignGroupRole: true    
  }
}

var storageAccountIds = map(mediaAccount.properties.storageAccounts, arg => arg.id)
module storageRoleAssignments 'storageaccounts.bicep' = {
  name: 'storageRoleAssignments'
  params: {
    storageAccounts: storageAccountIds
    principalId: managedIdentity.properties.principalId
    storageRoleName: storageRoleName
  }
}

resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
  scope: resourceGroup(storageAccountSubscription, storageAccountRG)
}

module storageRoleAssignment 'roleassignment.bicep' = {
  scope: resourceGroup(storageAccountSubscription, storageAccountRG)
  name: 'storageRoleAssignment'
  params: {
    resourceName: storageAccountName
    principalId: managedIdentity.properties.principalId
    roleName: storageRoleName
    storage: true
  }
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' existing = if (encrypt) {
  name: keyvaultName
  scope: resourceGroup(keyvaultSubscription, keyvaultRG)
}
module keyVaultRoleAssignment 'roleassignment.bicep' = if (encrypt) {
  scope: resourceGroup(keyvaultSubscription, keyvaultRG)
  name: 'keyVaultRoleAssignment'
  params: {
    resourceName: keyvaultName
    principalId: managedIdentity.properties.principalId
    roleName: keyVaultRoleName
    storage: true
  }
}

// Default arguments to the migration tool.
var defaultArguments = [
  'dotnet'
  'AMSMigrate.dll'
  'assets'
  '-s'
  mediaAccountSubscription
  '-g'
  mediaAccountRG
  '-n'
  mediaAccountName
  '-o'
  storageAccount.properties.primaryEndpoints.blob
]

var encryptionArguments = [
  '--encrypt-content'
  '--key-vault-uri'
]

resource container 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: identifier
  tags: tags
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}' : {}
    }
  }
  properties: {
    containers: [
      {
        name: 'amsmigrate'
        properties: {
          image: image
          resources: {
            requests: {
              cpu: cpus
              memoryInGB: memoryInGB
            }
          }
          command: concat(defaultArguments, arguments, encrypt ? encryptionArguments : [], encrypt ? [ keyVault.properties.vaultUri ] : [])
        }
      }
    ]
    osType: 'Linux'
    restartPolicy: 'Never'
  }
}

output follow string =  'az container logs -g ${resourceGroup().name} -n ${identifier} --follow'
