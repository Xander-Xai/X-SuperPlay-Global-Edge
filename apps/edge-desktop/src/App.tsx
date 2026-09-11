import { useEffect, useMemo, useState } from 'react'
import {
  ApiCancelledError,
  ApiResponseError,
  ApiUnavailableError,
  classifyClientApiState,
  createEdgeApiClient,
  errorCategory,
  loadDashboardSnapshot,
  loadNodeSnapshot,
  markDashboardSnapshotFailed,
  markNodeSnapshotFailed,
  POLL_INTERVAL_MS,
} from './api'
import type { ClientApiState, DashboardSnapshot, EdgeApiClient, EventsResponse, NodeSnapshot } from './api'
import { DashboardView } from './views/Dashboard'
import { EventsView } from './views/Events'
import { NodeView } from './views/Node'

type View = 'dashboard' | 'events' | 'node'

const BUILD_VERSION = typeof __BUILD_VERSION__ === 'string' ? __BUILD_VERSION__ : '0.1.0'
const BUILD_SHA = typeof __BUILD_SHA__ === 'string' ? __BUILD_SHA__ : 'local'
const BUILD_TARGET = typeof __BUILD_TARGET__ === 'string' ? __BUILD_TARGET__ : 'web'

function LoadingState() {
  return <div className="loading-state" role="status"><span className="spinner" />Loading evidence snapshot…</div>
}

function errorPresentation(error: unknown): { state: ClientApiState; eyebrow: string; title: string } {
  const state = classifyClientApiState(error)
  if (state === 'unsupported_api_version') {
    return { state, eyebrow: 'UNSUPPORTED API VERSION', title: 'Observation API version is not supported' }
  }
  if (state === 'malformed_response') {
    return { state, eyebrow: 'MALFORMED RESPONSE', title: 'Evidence could not be interpreted' }
  }
  return { state, eyebrow: 'BACKEND UNAVAILABLE', title: 'Edge API is unavailable' }
}

function ErrorState({ error, onRetry }: { error: unknown; onRetry: () => void }) {
  const presentation = errorPresentation(error)
  const message = error instanceof Error ? error.message : 'The response could not be read.'
  return (
    <div className={`error-state client-state-${presentation.state}`} role="alert">
      <div className="error-mark">!</div>
      <p className="eyebrow">{presentation.eyebrow}</p>
      <h2>{presentation.title}</h2>
      <p>{message}</p>
      <button className="secondary-button" onClick={onRetry}>Retry read-only request</button>
    </div>
  )
}

function ObservationNotice({ snapshot }: { snapshot: DashboardSnapshot | NodeSnapshot }) {
  if (snapshot.clientState === 'normal' && snapshot.freshness === 'fresh' && snapshot.resourceErrors.length === 0) return null
  const errorText = snapshot.lastErrorCategory ? ` · latest request: ${snapshot.lastErrorCategory}` : ''
  return (
    <div className={`observation-notice freshness-${snapshot.freshness}`} role="status">
      <strong>Observation {snapshot.freshness.toUpperCase()}</strong>
      <span>
        {snapshot.freshness === 'stale' ? 'Showing last-known-good state; it is not current/live.' : 'Current observation is unavailable.'}
        {snapshot.sourceTimestamp ? ` Last observed ${snapshot.sourceTimestamp}.` : ''}
        {errorText}
      </span>
      {snapshot.resourceErrors.length > 0 && <small>Optional resources unavailable: {snapshot.resourceErrors.join(', ')}</small>}
    </div>
  )
}

function App({ client: suppliedClient, initialView = 'dashboard' }: { client?: EdgeApiClient; initialView?: View }) {
  const client = useMemo(() => suppliedClient ?? createEdgeApiClient(), [suppliedClient])
  const [view, setView] = useState<View>(initialView)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<unknown>(null)
  const [dashboard, setDashboard] = useState<DashboardSnapshot | null>(null)
  const [events, setEvents] = useState<EventsResponse | null>(null)
  const [node, setNode] = useState<NodeSnapshot | null>(null)
  const [refreshToken, setRefreshToken] = useState(0)

  useEffect(() => {
    const controller = new AbortController()
    let cancelled = false
    let pollTimer: ReturnType<typeof setTimeout> | undefined
    setLoading(true)
    setError(null)

    const schedulePoll = () => {
      if (!cancelled) pollTimer = setTimeout(() => setRefreshToken((value) => value + 1), POLL_INTERVAL_MS)
    }

    const load = async () => {
      try {
        if (view === 'dashboard') {
          const result = await loadDashboardSnapshot(client, { signal: controller.signal })
          if (!cancelled) setDashboard(result)
        } else if (view === 'events') {
          const result = await client.getEvents(controller.signal)
          if (!Array.isArray(result.events)) throw new ApiResponseError('events must be an array')
          if (!cancelled) setEvents(result)
        } else {
          const result = await loadNodeSnapshot(client, { signal: controller.signal })
          if (!cancelled) setNode(result)
        }
      } catch (loadError) {
        if (cancelled || loadError instanceof ApiCancelledError) return
        setError(loadError)
        if (view === 'dashboard') setDashboard((previous) => previous ? markDashboardSnapshotFailed(previous, loadError) : previous)
        if (view === 'node') setNode((previous) => previous ? markNodeSnapshotFailed(previous, loadError) : previous)
      } finally {
        if (!cancelled) {
          setLoading(false)
          schedulePoll()
        }
      }
    }
    void load()
    return () => {
      cancelled = true
      controller.abort()
      if (pollTimer) clearTimeout(pollTimer)
    }
  }, [client, refreshToken, view])

  const mode = import.meta.env.VITE_EDGE_API_BASE_URL ? 'REAL API' : 'MOCK MODE'
  const cachedView = view === 'dashboard' ? dashboard : view === 'node' ? node : null

  return (
    <div className="app-shell">
      <aside className="side-rail">
        <div className="brand-lockup">
          <div className="brand-mark">X</div>
          <div><strong>X-SuperPlay</strong><span>Global Edge</span></div>
        </div>
        <div className="mode-chip"><span className="mode-dot" />{mode}</div>
        <nav aria-label="Primary navigation">
          {(['dashboard', 'events', 'node'] as View[]).map((item) => (
            <button className={`nav-button ${view === item ? 'nav-active' : ''}`} key={item} onClick={() => setView(item)} aria-current={view === item ? 'page' : undefined}>
              <span className="nav-icon">{item === 'dashboard' ? '◈' : item === 'events' ? '!' : '◎'}</span>
              {item[0].toUpperCase() + item.slice(1)}
            </button>
          ))}
        </nav>
        <div className="rail-footer">
          <span>Read-only observation API</span>
          <span>v{BUILD_VERSION} · {BUILD_TARGET}</span>
          <span className="build-sha">{BUILD_SHA}</span>
        </div>
      </aside>
      <main className="main-canvas">
        <header className="topbar">
          <span>Edge observation</span>
          <button className="refresh-button" onClick={() => setRefreshToken((value) => value + 1)} aria-label="Refresh evidence">↻ Refresh</button>
        </header>
        <div className="content-wrap">
          {loading && !cachedView && <LoadingState />}
          {!loading && error !== null && !cachedView && <ErrorState error={error} onRetry={() => setRefreshToken((value) => value + 1)} />}
          {!loading && view === 'dashboard' && dashboard && <><ObservationNotice snapshot={dashboard} /><DashboardView snapshot={dashboard} /></>}
          {!loading && view === 'events' && events && <EventsView response={events} />}
          {!loading && view === 'node' && node && <><ObservationNotice snapshot={node} /><NodeView snapshot={node} /></>}
          {!loading && error !== null && cachedView && <div className="cached-retry"><ErrorState error={error} onRetry={() => setRefreshToken((value) => value + 1)} /></div>}
        </div>
      </main>
    </div>
  )
}

export default App
