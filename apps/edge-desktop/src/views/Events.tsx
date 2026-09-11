import { formatAlertType } from '../api'
import type { EventsResponse } from '../api'

export function EventsView({ response }: { response: EventsResponse }) {
  const activeEvents = response.events.filter((event) => !event.resolved)
  return (
    <section aria-label="Events" className="view-stack">
      <div className="page-heading">
        <div>
          <p className="eyebrow">CONTROL PLANE / EVENTS</p>
          <h1>Evidence-backed events</h1>
          <p className="muted">Alerts are read from the existing alert engine output.</p>
        </div>
        <span className="event-count">{activeEvents.length} active</span>
      </div>
      {response.error && <div className="inline-warning">Backend returned an invalid alert snapshot: {response.error}</div>}
      {activeEvents.length === 0 ? (
        <div className="empty-state">
          <div className="empty-mark">✓</div>
          <h2>No active events</h2>
          <p>{response.resolved === null ? 'Resolution state unavailable.' : 'The current alert snapshot is resolved or empty.'}</p>
        </div>
      ) : (
        <div className="event-list">
          {activeEvents.map((event) => (
            <article className={`event-card event-${event.level.toLowerCase()}`} key={`${event.timestamp}-${event.metric}`}>
              <div className="event-topline">
                <span className={`severity severity-${event.level.toLowerCase()}`}>{event.level}</span>
                <time dateTime={event.timestamp}>{event.timestamp}</time>
              </div>
              <h2>{formatAlertType(event)}</h2>
              <p>{event.reason}</p>
              <div className="event-meta">
                <span>Value <strong>{event.value ?? '—'}</strong></span>
                <span>Threshold <strong>{event.threshold ?? '—'}</strong></span>
                <span>Source <strong>{event.source_evidence}</strong></span>
              </div>
            </article>
          ))}
        </div>
      )}
    </section>
  )
}
