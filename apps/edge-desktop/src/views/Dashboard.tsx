import { formatServiceName } from '../api'
import type { DashboardSnapshot, ServiceName } from '../api'
import { MetricCard } from '../components/MetricCard'
import { StatusBadge } from '../components/StatusBadge'

const serviceOrder: ServiceName[] = ['wireguard', 'xray_reality', 'hysteria2']

function displayNumber(value: number | null, suffix = '') {
  return value === null ? 'Unavailable' : `${value}${suffix}`
}

function serviceTone(status: string) {
  return status === 'observed' || status === 'healthy' ? 'service-good' : 'service-muted'
}

export function DashboardView({ snapshot }: { snapshot: DashboardSnapshot }) {
  return (
    <section aria-label="Dashboard" className="view-stack">
      <div className="page-heading">
        <div>
          <p className="eyebrow">CONTROL PLANE / DASHBOARD</p>
          <h1>Edge overview</h1>
          <p className="muted">Read-only observation from the X-SuperPlay Reliability API.</p>
        </div>
        <StatusBadge state={snapshot.state} />
      </div>

      <div className="hero-card">
        <div>
          <p className="eyebrow">{snapshot.nodeId}</p>
          <h2>{snapshot.region}</h2>
          <p className="muted">{snapshot.provider} · {snapshot.protocol} · {snapshot.connectionState}</p>
        </div>
        <div className="score-block">
          <span>Health score</span>
          <strong>{snapshot.healthScore === null ? '—' : snapshot.healthScore}</strong>
          <small>Source: latest valid evidence</small>
        </div>
      </div>

      <div className="metric-grid">
        <MetricCard label="HTTP success" value={displayNumber(snapshot.httpSuccessRate, '%')} tone="good" />
        <MetricCard label="P50 latency" value={displayNumber(snapshot.p50LatencyMs)} unit="ms" />
        <MetricCard label="P95 latency" value={displayNumber(snapshot.p95LatencyMs)} unit="ms" />
        <MetricCard label="Active alerts" value={displayNumber(snapshot.alertCount)} tone={snapshot.alertCount ? 'warning' : 'neutral'} />
      </div>

      <div className="panel">
        <div className="panel-heading">
          <div>
            <p className="eyebrow">RUNTIME STATE</p>
            <h2>Services</h2>
          </div>
          <span className="muted">No control actions available</span>
        </div>
        <div className="service-grid">
          {serviceOrder.map((name) => {
            const service = snapshot.services[name]
            return (
              <div className="service-row" key={name}>
                <div className="service-icon" aria-hidden="true">{name === 'wireguard' ? 'W' : name === 'xray_reality' ? 'R' : 'H'}</div>
                <div>
                  <strong>{formatServiceName(name)}</strong>
                  <p>{service?.reason ?? 'No local evidence'}</p>
                </div>
                <span className={`service-status ${serviceTone(service?.status ?? 'unavailable')}`}>
                  {service?.status ?? 'unavailable'}
                </span>
              </div>
            )
          })}
        </div>
      </div>

      <p className="footnote">Observed {snapshot.timestamp ?? 'time unavailable'} · corrupted evidence: {snapshot.corruptedEvidenceCount}</p>
    </section>
  )
}
