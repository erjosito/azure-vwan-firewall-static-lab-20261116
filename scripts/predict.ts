import { writeFileSync } from 'node:fs'
import { hubFirewallTopology, azHubFirewallTopology, firewallAddresses } from '../../vwan-visual-topology/tests/fixtures/hub-firewall'
import { simulate } from '../../vwan-visual-topology/src/routing'
import { traceNodePath } from '../../vwan-visual-topology/src/paths'
import { simulateAzNet, traceAzNetFlow } from '../../vwan-visual-topology/src/azure-net/engine'
import { validateTopology } from '../../vwan-visual-topology/src/validation'
import { parseAzNetTopology } from '../../vwan-visual-topology/src/azure-net/admission'
import { executePlatform } from '../../vwan-visual-topology/src/platform/service'
import { engineVersion } from '../../vwan-visual-topology/src/platform/contract'

const root = new URL('../', import.meta.url)
const sourceRevision = process.env.PREDICTION_SOURCE ?? 'fa0ba11d1d4341cdda2d5abedf78d7a7f5571ab5'
const sources = ['trusted-a', 'trusted-b', 'untrusted-a'] as const
const predictions = []
for (const design of ['published-vnet', 'published-branch', 'separate-untrusted'] as const) {
  const native = hubFirewallTopology(design)
  native.spokes = native.spokes.filter((spoke) => sources.includes(spoke.id as typeof sources[number]))
  native.sites = []
  native.connections = []
  for (const spoke of native.spokes) spoke.hubRouting!.labels = []
  const mixed = azHubFirewallTopology(design)
  mixed.vnets = mixed.vnets.filter((vnet) => sources.includes(vnet.id as typeof sources[number]))
  mixed.sites = []
  mixed.vpnConnections = []
  for (const vnet of mixed.vnets) vnet.vwanHubAttachment!.hubRouting!.labels = []
  validateTopology(native)
  parseAzNetTopology(mixed)
  writeFileSync(new URL(`${design}.native.json`, root), JSON.stringify(native, null, 2))
  writeFileSync(new URL(`${design}.mixed.json`, root), JSON.stringify(mixed, null, 2))
  const simulation = simulate(native)
  const mixedSimulation = simulateAzNet(mixed)
  for (const source of sources) for (const destination of sources) {
    if (source === destination) continue
    const forward = traceNodePath(native, simulation, { kind: 'spoke', id: source }, firewallAddresses[destination])
    const reverse = traceNodePath(native, simulation, { kind: 'spoke', id: destination }, firewallAddresses[source])
    const mixedTrace = traceAzNetFlow(mixed, mixedSimulation,
      { kind: 'subnet', vnetId: source, subnetId: `sub-${source}` }, firewallAddresses[destination])
    const expectedForward = !source.startsWith('untrusted') && !destination.startsWith('untrusted')
      ? 'bypassed' : design === 'published-branch' && source.startsWith('untrusted') ? 'bypassed' : 'required'
    const expectedReverse = !source.startsWith('untrusted') && !destination.startsWith('untrusted')
      ? 'bypassed' : design === 'published-branch' && destination.startsWith('untrusted') ? 'bypassed' : 'required'
    const parity = (['vwan', 'full'] as const).map((mode) => {
      const endpoint = (id: typeof sources[number]) => mode === 'vwan'
        ? { kind: 'spoke', id } : { kind: 'subnet', vnetId: id, subnetId: `sub-${id}` }
      const result = executePlatform({
        contractVersion: 1, operation: 'evaluate', document: { mode, topology: mode === 'vwan' ? native : mixed },
        requirements: [{ id: `${design}-${source}-${destination}`, kind: 'flow',
          source: endpoint(source), target: endpoint(destination),
          sourceAddress: firewallAddresses[source], destinationAddress: firewallAddresses[destination], expectation: 'allow',
          firewallPolicy: { hubId: 'hub-local', forward: expectedForward, reverse: expectedReverse } }],
      })
      if (result.errors.length) {
        throw new Error(JSON.stringify({ mode, design, source, destination, result }))
      }
      return { mode, outcome: result.assessments[0]?.outcome,
        findings: (result.assessments[0]?.evidence as { findings?: unknown[] })?.findings }
    })
    predictions.push({ design, source, destination, expectedForward, expectedReverse, forward, reverse,
      mixedTrace, parity, nativeHubTables: simulation.hubTables, nativeFirewallTables: simulation.firewallTables })
  }
}
writeFileSync(new URL(process.argv[2] ?? 'predictions-before-azure.json', root),
  JSON.stringify({ source: sourceRevision, engineVersion,
    generatedUtc: new Date().toISOString(), scope: 'Exactly three VNet endpoints; no branches; routing only, not sessions/policy.',
    predictions }, null, 2))
console.log(`Recorded ${predictions.length} direction predictions and both provider assessments without discarding disagreements.`)
