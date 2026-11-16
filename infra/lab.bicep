param location string = 'swedencentral'
param vmSize string = 'Standard_B2ts_v2'
param correlation string = 'fw177-20261116-4cf83a'
@secure()
param adminPublicKey string

var tags = {
  lab: 'true'
  created_by: 'copilot-lab'
  correlation_id: correlation
}
var endpoints = [
  { name: 'trusted-a', prefix: '10.10.0.0/16', subnet: '10.10.0.0/24', ip: '10.10.0.4' }
  { name: 'trusted-b', prefix: '10.20.0.0/16', subnet: '10.20.0.0/24', ip: '10.20.0.4' }
  { name: 'untrusted-a', prefix: '10.30.0.0/16', subnet: '10.30.0.0/24', ip: '10.30.0.4' }
]

resource wan 'Microsoft.Network/virtualWans@2024-05-01' = {
  name: 'wan-fw177'
  location: location
  tags: tags
  properties: {
    type: 'Standard'
    allowBranchToBranchTraffic: true
    allowVnetToVnetTraffic: true
  }
}
resource hub 'Microsoft.Network/virtualHubs@2024-05-01' = {
  name: 'hub-fw177'
  location: location
  tags: tags
  properties: {
    addressPrefix: '10.100.0.0/23'
    virtualWan: { id: wan.id }
    sku: 'Standard'
    virtualRouterAutoScaleConfiguration: { minCapacity: 2 }
  }
}
resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: 'policy-fw177'
  location: location
  tags: tags
  properties: {
    sku: { tier: 'Standard' }
    threatIntelMode: 'Off'
  }
}
resource controls 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = {
  parent: policy
  name: 'lab-network-controls'
  properties: {
    priority: 100
    ruleCollections: [
      {
        name: 'explicit-deny-control'
        priority: 100
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Deny' }
        rules: [
          {
            name: 'deny-tcp-18081'
            ruleType: 'NetworkRule'
            ipProtocols: [ 'TCP' ]
            sourceAddresses: [ '10.0.0.0/8' ]
            destinationAddresses: [ '10.0.0.0/8' ]
            destinationPorts: [ '18081' ]
          }
          {
            name: 'deny-udp-18083'
            ruleType: 'NetworkRule'
            ipProtocols: [ 'UDP' ]
            sourceAddresses: [ '10.0.0.0/8' ]
            destinationAddresses: [ '10.0.0.0/8' ]
            destinationPorts: [ '18083' ]
          }
        ]
      }
      {
        name: 'explicit-allow-control'
        priority: 200
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        action: { type: 'Allow' }
        rules: [
          {
            name: 'allow-tcp-18080'
            ruleType: 'NetworkRule'
            ipProtocols: [ 'TCP' ]
            sourceAddresses: [ '10.0.0.0/8' ]
            destinationAddresses: [ '10.0.0.0/8' ]
            destinationPorts: [ '18080' ]
          }
          {
            name: 'allow-udp-18082'
            ruleType: 'NetworkRule'
            ipProtocols: [ 'UDP' ]
            sourceAddresses: [ '10.0.0.0/8' ]
            destinationAddresses: [ '10.0.0.0/8' ]
            destinationPorts: [ '18082' ]
          }
        ]
      }
    ]
  }
}
resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: 'fw-fw177'
  location: location
  tags: tags
  properties: {
    sku: { name: 'AZFW_Hub', tier: 'Standard' }
    virtualHub: { id: hub.id }
    hubIPAddresses: { publicIPs: { count: 1 } }
    firewallPolicy: { id: policy.id }
  }
  dependsOn: [ controls ]
}
resource logs 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: 'logs-fw177-${uniqueString(resourceGroup().id)}'
  location: location
  tags: tags
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
    workspaceCapping: { dailyQuotaGb: 1 }
  }
}
resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'lab-network-rules'
  scope: firewall
  properties: {
    workspaceId: logs.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      { category: 'AzureFirewallNetworkRule', enabled: true }
      { category: 'AZFWNetworkRule', enabled: true }
    ]
  }
}
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-fw177'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'AllowSyntheticProbes'
        properties: {
          priority: 200
          access: 'Allow'
          direction: 'Inbound'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '18080-18083'
          sourceAddressPrefix: '10.0.0.0/8'
          destinationAddressPrefix: '10.0.0.0/8'
        }
      }
    ]
  }
}
resource vnets 'Microsoft.Network/virtualNetworks@2024-05-01' = [for endpoint in endpoints: {
  name: 'vnet-${endpoint.name}'
  location: location
  tags: tags
  properties: {
    addressSpace: { addressPrefixes: [ endpoint.prefix ] }
    subnets: [
      {
        name: 'workloads'
        properties: {
          addressPrefix: endpoint.subnet
          defaultOutboundAccess: true
          networkSecurityGroup: { id: nsg.id }
        }
      }
    ]
  }
}]
resource nics 'Microsoft.Network/networkInterfaces@2024-05-01' = [for (endpoint, i) in endpoints: {
  name: 'nic-${endpoint.name}'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          primary: true
          privateIPAllocationMethod: 'Static'
          privateIPAddress: endpoint.ip
          subnet: { id: '${vnets[i].id}/subnets/workloads' }
        }
      }
    ]
  }
}]
resource vms 'Microsoft.Compute/virtualMachines@2024-07-01' = [for (endpoint, i) in endpoints: {
  name: 'vm-${endpoint.name}'
  location: location
  tags: tags
  properties: {
    hardwareProfile: { vmSize: vmSize }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: '0001-com-ubuntu-server-jammy'
        sku: '22_04-lts-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 30
        managedDisk: { storageAccountType: 'StandardSSD_LRS' }
        deleteOption: 'Delete'
      }
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: { secureBootEnabled: true, vTpmEnabled: true }
    }
    osProfile: {
      computerName: endpoint.name
      adminUsername: 'azurelabuser'
      customData: base64(loadTextContent('guest-cloud-init.yaml'))
      linuxConfiguration: {
        disablePasswordAuthentication: true
        provisionVMAgent: true
        ssh: { publicKeys: [ { path: '/home/azurelabuser/.ssh/authorized_keys', keyData: adminPublicKey } ] }
      }
    }
    networkProfile: { networkInterfaces: [ { id: nics[i].id, properties: { deleteOption: 'Delete' } } ] }
    diagnosticsProfile: { bootDiagnostics: { enabled: true } }
  }
}]

output hubId string = hub.id
output firewallId string = firewall.id
output workspaceId string = logs.properties.customerId
output endpointIps array = [for endpoint in endpoints: endpoint.ip]
