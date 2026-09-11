import { formatServiceName } from '../api'
import type { NodeSnapshot, ServiceName } from '../api'
import { StateLabel } from '../components/StatusBadge'

const services: ServiceName[] = ['wireguard', 'xray_reality', 'hysteria2']

export function NodeView({ snapshot }: { snapshot: NodeSnapshot }) {
  const state = snapshot.status.overall_status === 'healthy'
    ? 'healthy'
    : snapshot.status.overall_status === 'degraded'
      ? 'warning'
      : 'unknown'
  return (
    <section aria-label="Node" className="view-stack">
      <div className="page-heading">
        <div>
          <p className="eyebrow">CONTROL PLANE / NODE</p>
          <h1>Node identity</h1>
          <p className="muted">Configuration-backed identity and capability declarations.</p>
        </div>
        <StateLabel state={state} />
      </div>

      <div className="node-layout">
        <div className="panel identity-panel">
          <p className="eyebrow">IDENTITY</p>
          <dl className="detail-list">
            <div><dt>Node ID</dt><dd>{snapshot.identity.node_id}</dd></div>
            <div><dt>Region</dt><dd>{snapshot.identity.region}</dd></div>
            <div><dt>Provider</dt><dd>{snapshot.identity.provider}</dd></div>
            <div><dt>Identity version</dt><dd>{snapshot.identity.version}</dd></div>
            <div><dt>Runtime version</dt><dd>{snapshot.metadata.runtime_version}</dd></div>
            <div><dt>API version</dt><dd>{snapshot.metadata.api_version}</dd></div>
          </dl>
        </div>
        <div className="panel">
          <p className="eyebrow">DECLARED CAPABILITIES</p>
          <div className="capability-list">
            {services.map((name) => (
              <div className="capability-row" key={name}>
                <span>{formatServiceName(name)}</span>
                <span className={snapshot.capabilities[name] ? 'capability-on' : 'capability-off'}>
                  {snapshot.capabilities[name] ? 'Declared' : 'Not declared'}
                </span>
              </div>
            ))}
          </div>
          <p className="callout">Capability declarations do not prove liveness. Observe the Dashboard service state for evidence.</p>
        </div>
      </div>

      <div className="panel">
        <div className="panel-heading"><h2>Observed service states</h2><span className="muted">{snapshot.services.timestamp ?? 'Timestamp unavailable'}</span></div>
        <div className="service-table" role="table" aria-label="Observed service states">
          {services.map((name) => {
            const service = snapshot.services.services[name]
            return <div className="service-table-row" role="row" key={name}><span>{formatServiceName(name)}</span><span>{service?.status ?? 'unavailable'}</span><small>{service?.reason ?? 'No local evidence'}</small></div>
          })}
        </div>
        <p className="footnote">Connection: {snapshot.connection.connection_state} via {snapshot.connection.protocol}</p>
      </div>
    </section>
  )
}
