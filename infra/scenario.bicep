@allowed([ 'published-vnet', 'published-branch', 'separate-untrusted' ])
param design string

resource hub 'Microsoft.Network/virtualHubs@2024-05-01' existing = { name: 'hub-fw177' }
resource firewall 'Microsoft.Network/azureFirewalls@2024-05-01' existing = { name: 'fw-fw177' }
var names = [ 'trusted-a', 'trusted-b', 'untrusted-a' ]
var tableNames = [ 'defaultRouteTable', 'trusted', 'untrusted' ]

@batchSize(1)
resource tables 'Microsoft.Network/virtualHubs/hubRouteTables@2024-05-01' = [for name in tableNames: {
  parent: hub
  name: name
  properties: {
    labels: [ name == 'defaultRouteTable' ? 'default' : name ]
    routes: [
      {
        name: 'inspect-private'
        destinationType: 'CIDR'
        destinations: [ '10.0.0.0/8' ]
        nextHopType: 'ResourceId'
        nextHop: firewall.id
      }
    ]
  }
}]
resource vnets 'Microsoft.Network/virtualNetworks@2024-05-01' existing = [for name in names: { name: 'vnet-${name}' }]
@batchSize(1)
resource connections 'Microsoft.Network/virtualHubs/hubVirtualNetworkConnections@2024-05-01' = [for (name, i) in names: {
  parent: hub
  name: 'conn-${name}'
  properties: {
    remoteVirtualNetwork: { id: vnets[i].id }
    allowHubToRemoteVnetTransit: true
    allowRemoteVnetToUseHubVnetGateways: false
    enableInternetSecurity: false
    routingConfiguration: {
      associatedRouteTable: {
        id: '${hub.id}/hubRouteTables/${i < 2 ? 'trusted' : design == 'separate-untrusted' ? 'untrusted' : 'defaultRouteTable'}'
      }
      propagatedRouteTables: {
        labels: []
        ids: i < 2
          ? design == 'published-vnet'
            ? [ { id: '${hub.id}/hubRouteTables/trusted' } ]
            : [ { id: '${hub.id}/hubRouteTables/trusted' }, { id: '${hub.id}/hubRouteTables/defaultRouteTable' } ]
          : [ { id: '${hub.id}/hubRouteTables/noneRouteTable' } ]
      }
      vnetRoutes: { staticRoutes: [] }
    }
  }
  dependsOn: [ tables ]
}]
