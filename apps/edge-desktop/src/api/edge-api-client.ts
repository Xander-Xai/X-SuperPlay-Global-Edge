import type {
  AlertEvent,
  BackendStatus,
  DashboardSnapshot,
  DisplayHealthState,
  EdgeApiClient,
  EventsResponse,
  HealthCurrentResponse,
  HealthHistoryResponse,
  NodeAggregateResponse,
  NodeCapabilitiesResponse,
  NodeConnectionResponse,
  NodeIdentityResponse,
  NodeMetadataResponse,
  NodeSnapshot,
  NodeServicesResponse,
  NodeStatusResponse,
  PrometheusMetrics,
  ServiceName,
  ServiceState,
} from './types'
import {
  ApiCancelledError,
  ApiResponseError,
  ApiTimeoutError,
  ApiUnavailableError,
  DEFAULT_MAX_ATTEMPTS,
  DEFAULT_TIMEOUT_MS,
  OPTIONAL_MAX_ATTEMPTS,
  OPTIONAL_TIMEOUT_MS,
  assertSupportedApiVersion,
  observationFreshness,
  requestWithPolicy,
  validateContentType,
  type RequestBudget,
  type RequestPolicyOptions,
} from './resilience'

export {
  ApiCancelledError,
  ApiResponseError,
  ApiTimeoutError,
  ApiUnavailableError,
  UnsupportedApiVersionError,
} from './resilience'

const requiredMetricNames = [
  'x_superplay_health_score',
  'x_superplay_http_success_rate',
  'x_superplay_latency_p50_ms',
  'x_superplay_latency_p95_ms',
  'x_superplay_node_status',
  'x_superplay_alert_count',
] as const

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value)
}

function assertRecord(value: unknown, resource: string): asserts value is Record<string, unknown> {
  if (!isRecord(value)) throw new ApiResponseError(`${resource} response must be an object`)
}

type JsonValidator<T> = (value: Record<string, unknown>) => boolean

function isString(value: unknown): value is string {
  return typeof value === 'string'
}

function isNonEmptyString(value: unknown): value is string {
  return isString(value) && value.trim().length > 0
}

function isNullableString(value: unknown): value is string | null {
  return value === null || isString(value)
}

function isNumber(value: unknown): value is number {
  return typeof value === 'number' && Number.isFinite(value)
}

function isNonNegativeNumber(value: unknown): value is number {
  return isNumber(value) && value >= 0
}

function isRate(value: unknown): value is number {
  return isNumber(value) && value >= 0 && value <= 100
}

function isNullableNumber(value: unknown): value is number | null {
  return value === null || isNumber(value)
}

function isNullableScore(value: unknown): value is number | null {
  return value === null || (isNumber(value) && value >= 0 && value <= 100)
}

function isNonNegativeInteger(value: unknown): value is number {
  return typeof value === 'number' && Number.isInteger(value) && value >= 0
}

function isBackendStatus(value: unknown): value is BackendStatus {
  return value === 'healthy' || value === 'degraded' || value === 'unknown'
}

function isServiceState(value: unknown, expectedName?: ServiceName): value is ServiceState {
  return isRecord(value) &&
    isNonEmptyString(value.name) &&
    (!expectedName || value.name === expectedName) &&
    isNonEmptyString(value.status) &&
    isNonEmptyString(value.reason) &&
    isNonEmptyString(value.source)
}

function isServiceMap(value: unknown): value is Record<ServiceName, ServiceState> {
  return isRecord(value) &&
    isServiceState(value.wireguard, 'wireguard') &&
    isServiceState(value.xray_reality, 'xray_reality') &&
    isServiceState(value.hysteria2, 'hysteria2')
}

function isNodeStatusResponse(value: Record<string, unknown>): boolean {
  return isNonEmptyString(value.node_id) &&
    isBackendStatus(value.overall_status) &&
    isNullableScore(value.health_score) &&
    isServiceMap(value.service_states) &&
    isNullableString(value.timestamp) &&
    isNonNegativeInteger(value.corrupted_evidence_count)
}

function isNodeIdentityResponse(value: Record<string, unknown>): boolean {
  return isNonEmptyString(value.node_id) && isNonEmptyString(value.region) &&
    isNonEmptyString(value.provider) && isNonEmptyString(value.version)
}

function isNodeServicesResponse(value: Record<string, unknown>): boolean {
  return isNonEmptyString(value.node_id) &&
    isServiceMap(value.services) &&
    isNullableString(value.timestamp) &&
    isNonNegativeInteger(value.corrupted_evidence_count)
}

function isNodeConnectionResponse(value: Record<string, unknown>): boolean {
  return isNonEmptyString(value.node_id) &&
    isNonEmptyString(value.connection_state) &&
    isNonEmptyString(value.protocol) &&
    isRecord(value.endpoint_metadata) &&
    isNullableString(value.timestamp) &&
    isNonNegativeInteger(value.corrupted_evidence_count)
}

function isNodeCapabilitiesResponse(value: Record<string, unknown>): boolean {
  return typeof value.wireguard === 'boolean' &&
    typeof value.xray_reality === 'boolean' &&
    typeof value.hysteria2 === 'boolean'
}

function isNodeMetadataResponse(value: Record<string, unknown>): boolean {
  return isNonEmptyString(value.node_id) && isNonEmptyString(value.runtime_version) &&
    isNonEmptyString(value.api_version)
}

function isHealthCurrentResponse(value: Record<string, unknown>): boolean {
  return isBackendStatus(value.node_status) &&
    isNullableScore(value.health_score) &&
    isRecord(value.latest_metrics) &&
    isNullableString(value.timestamp) &&
    isNonNegativeInteger(value.corrupted_evidence_count)
}

function isHealthHistoryResponse(value: Record<string, unknown>): boolean {
  return (value.availability === null || isRate(value.availability)) &&
    isRecord(value.latency_percentiles) &&
    (value.latency_percentiles.p95 === null || isNonNegativeNumber(value.latency_percentiles.p95)) &&
    isRecord(value.historical_summary)
}

function isAlertEvent(value: unknown): value is AlertEvent {
  return isRecord(value) &&
    isString(value.timestamp) &&
    (value.level === 'WARNING' || value.level === 'CRITICAL' || value.level === 'NONE') &&
    isString(value.reason) && isString(value.metric) &&
    isNullableNumber(value.value) && isNullableNumber(value.threshold) &&
    isString(value.source_evidence) && typeof value.resolved === 'boolean'
}

function isEventsResponse(value: Record<string, unknown>): boolean {
  return Array.isArray(value.events) && value.events.every(isAlertEvent) &&
    (typeof value.resolved === 'boolean' || value.resolved === null) &&
    (value.timestamp === undefined || isNullableString(value.timestamp)) &&
    (value.error === undefined || isString(value.error))
}

function isNodeAggregateResponse(value: Record<string, unknown>): boolean {
  const status = value.status
  const identity = value.identity
  const services = value.services
  const connection = value.connection
  const capabilities = value.capabilities
  const metadata = value.metadata
  const healthCurrent = value.health_current
  const healthHistory = value.health_history
  const events = value.events
  return isRecord(status) && isNodeStatusResponse(status) &&
    isRecord(identity) && isNodeIdentityResponse(identity) &&
    isRecord(services) && isNodeServicesResponse(services) &&
    isRecord(connection) && isNodeConnectionResponse(connection) &&
    isRecord(capabilities) && isNodeCapabilitiesResponse(capabilities) &&
    isRecord(metadata) && isNodeMetadataResponse(metadata) &&
    isRecord(healthCurrent) && isHealthCurrentResponse(healthCurrent) &&
    isRecord(healthHistory) && isHealthHistoryResponse(healthHistory) &&
    isRecord(events) && isEventsResponse(events) &&
    isString(value.metrics_text)
}

function parseJson<T>(value: unknown, resource: string, validator?: JsonValidator<T>): T {
  assertRecord(value, resource)
  if (validator && !validator(value)) throw new ApiResponseError(`${resource} response failed schema validation`)
  return value as T
}

export function parsePrometheusMetrics(text: string): PrometheusMetrics {
  const metrics: PrometheusMetrics = {}
  for (const line of text.split(/\r?\n/)) {
    if (!line || line.startsWith('#')) continue
    const match = /^(x_superplay_[a-z0-9_]+) (NaN|[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?)$/.exec(line)
    if (!match) throw new ApiResponseError(`Malformed Prometheus sample: ${line}`)
    metrics[match[1]] = match[2] === 'NaN' ? Number.NaN : Number(match[2])
  }
  for (const name of requiredMetricNames) {
    if (!(name in metrics)) throw new ApiResponseError(`Missing Prometheus metric: ${name}`)
  }
  return metrics
}

function normalizeUrl(baseUrl: string): string {
  const trimmed = baseUrl.trim()
  if (!trimmed) throw new ApiUnavailableError('Read-only observation API base URL is empty')
  return trimmed.replace(/\/+$/, '')
}

export interface HttpEdgeApiClientOptions extends RequestPolicyOptions {}

const OPTIONAL_BUDGET: RequestBudget = {
  timeoutMs: OPTIONAL_TIMEOUT_MS,
  maxAttempts: OPTIONAL_MAX_ATTEMPTS,
}

export class HttpEdgeApiClient implements EdgeApiClient {
  private readonly baseUrl: string
  private readonly policy: HttpEdgeApiClientOptions
  private aggregateSupported: boolean | null = null

  constructor(baseUrl: string, options: HttpEdgeApiClientOptions = {}) {
    this.baseUrl = normalizeUrl(baseUrl)
    this.policy = {
      timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
      maxAttempts: options.maxAttempts ?? DEFAULT_MAX_ATTEMPTS,
      fetchImpl: options.fetchImpl,
    }
  }

  private async requestJson<T>(
    path: string,
    validator?: JsonValidator<T>,
    signal?: AbortSignal,
    budget?: RequestBudget,
  ): Promise<T> {
    const response = await requestWithPolicy(`${this.baseUrl}${path}`, {
      method: 'GET',
      headers: { Accept: 'application/json' },
    }, { ...this.policy, ...budget, signal })
    validateContentType(response, 'json', path)
    let payload: unknown
    try {
      payload = await response.json()
    } catch {
      throw new ApiResponseError(`${path} did not return JSON`)
    }
    return parseJson<T>(payload, path, validator)
  }

  private async requestText(path: string, signal?: AbortSignal, budget?: RequestBudget): Promise<string> {
    const response = await requestWithPolicy(`${this.baseUrl}${path}`, {
      method: 'GET',
      headers: { Accept: 'text/plain; version=0.0.4' },
    }, { ...this.policy, ...budget, signal })
    validateContentType(response, 'text', path)
    return response.text()
  }

  getNodeStatus(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeStatusResponse> {
    return this.requestJson<NodeStatusResponse>('/api/v1/node/status', isNodeStatusResponse, signal, budget)
  }

  getNodeIdentity(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeIdentityResponse> {
    return this.requestJson<NodeIdentityResponse>('/api/v1/node/identity', isNodeIdentityResponse, signal, budget)
  }

  getNodeServices(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeServicesResponse> {
    return this.requestJson<NodeServicesResponse>('/api/v1/node/services', isNodeServicesResponse, signal, budget)
  }

  getNodeConnection(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeConnectionResponse> {
    return this.requestJson<NodeConnectionResponse>('/api/v1/node/connection', isNodeConnectionResponse, signal, budget)
  }

  getNodeCapabilities(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeCapabilitiesResponse> {
    return this.requestJson<NodeCapabilitiesResponse>('/api/v1/node/capabilities', isNodeCapabilitiesResponse, signal, budget)
  }

  async getNodeMetadata(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeMetadataResponse> {
    const metadata = await this.requestJson<NodeMetadataResponse>('/api/v1/node/metadata', isNodeMetadataResponse, signal, budget)
    assertSupportedApiVersion(metadata.api_version)
    return metadata
  }

  getHealthCurrent(signal?: AbortSignal, budget?: RequestBudget): Promise<HealthCurrentResponse> {
    return this.requestJson<HealthCurrentResponse>('/api/v1/health/current', isHealthCurrentResponse, signal, budget)
  }

  getHealthHistory(signal?: AbortSignal, budget?: RequestBudget): Promise<HealthHistoryResponse> {
    return this.requestJson<HealthHistoryResponse>('/api/v1/health/history', isHealthHistoryResponse, signal, budget)
  }

  getEvents(signal?: AbortSignal, budget?: RequestBudget): Promise<EventsResponse> {
    return this.requestJson<EventsResponse>('/api/v1/events', isEventsResponse, signal, budget)
  }

  async getMetrics(signal?: AbortSignal, budget?: RequestBudget): Promise<PrometheusMetrics> {
    return parsePrometheusMetrics(await this.requestText('/metrics', signal, budget))
  }

  /**
   * One round trip for every dashboard resource. Older servers do not expose
   * this route; the negative result is remembered so the panel stops paying
   * for a request that can never succeed.
   */
  async getNodeSnapshotAggregate(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeAggregateResponse> {
    if (this.aggregateSupported === false) {
      throw new ApiUnavailableError('Aggregate snapshot route is not served by this API version', 'http', 404)
    }
    try {
      const aggregate = await this.requestJson<NodeAggregateResponse>(
        '/api/v1/node/snapshot',
        isNodeAggregateResponse,
        signal,
        budget ?? OPTIONAL_BUDGET,
      )
      this.aggregateSupported = true
      return aggregate
    } catch (error) {
      if (error instanceof ApiUnavailableError && (error.status === 404 || error.status === 405)) {
        this.aggregateSupported = false
      }
      throw error
    }
  }
}

function metricValue(metrics: PrometheusMetrics, name: string): number | null {
  const value = metrics[name]
  return typeof value === 'number' && Number.isFinite(value) ? value : null
}

function statusFromPayload(overallStatus: BackendStatus, events: EventsResponse): DisplayHealthState {
  const activeEvents = events.events.filter((event) => !event.resolved)
  if (activeEvents.some((event) => event.level === 'CRITICAL')) return 'critical'
  if (overallStatus === 'healthy') return activeEvents.length ? 'warning' : 'healthy'
  if (overallStatus === 'degraded') return 'warning'
  return 'unknown'
}

function fallbackServices(status: NodeStatusResponse): NodeServicesResponse {
  return {
    node_id: status.node_id,
    services: status.service_states,
    timestamp: status.timestamp,
    corrupted_evidence_count: status.corrupted_evidence_count,
  }
}

function fallbackConnection(status: NodeStatusResponse): NodeConnectionResponse {
  return {
    node_id: status.node_id,
    connection_state: 'unknown',
    protocol: 'unknown',
    endpoint_metadata: {},
    timestamp: null,
    corrupted_evidence_count: status.corrupted_evidence_count,
  }
}

function fallbackHistory(): HealthHistoryResponse {
  return { availability: null, latency_percentiles: { p95: null }, historical_summary: {} }
}

function fallbackEvents(): EventsResponse {
  return { events: [], resolved: null, timestamp: null, error: 'resource_unavailable' }
}

function fallbackMetrics(): PrometheusMetrics {
  return Object.fromEntries(requiredMetricNames.map((name) => [name, Number.NaN]))
}

type Settled<T> = { ok: true; value: T } | { ok: false; error: unknown }

/**
 * Turn a request into a settled outcome so a failing optional resource never
 * rejects the batch that contains it.
 */
function settle<T>(request: () => Promise<T>): Promise<Settled<T>> {
  try {
    return request().then(
      (value) => ({ ok: true as const, value }),
      (error) => ({ ok: false as const, error }),
    )
  } catch (error) {
    return Promise.resolve({ ok: false as const, error })
  }
}

function unwrap<T>(name: string, settled: Settled<T>, fallback: () => T, errors: string[]): T {
  if (settled.ok) return settled.value
  if (settled.error instanceof ApiCancelledError) throw settled.error
  errors.push(`${name}:${settled.error instanceof Error ? settled.error.name : 'error'}`)
  return fallback()
}

/**
 * Prefer the single-round-trip aggregate when the server exposes it. A server
 * that does not serve the route, or an aggregate that fails, falls back to the
 * per-resource endpoints instead of breaking the view.
 */
async function loadAggregate(
  client: EdgeApiClient,
  options: { signal?: AbortSignal; budget?: RequestBudget },
): Promise<NodeAggregateResponse | null> {
  const getAggregate = client.getNodeSnapshotAggregate?.bind(client)
  if (!getAggregate) return null
  try {
    // The aggregate is an optimisation, so it never gets a second attempt and
    // never gets the long default budget: failing fast falls back to the
    // per-resource endpoints instead of stalling the view.
    return await getAggregate(options.signal, OPTIONAL_BUDGET)
  } catch (error) {
    if (error instanceof ApiCancelledError) throw error
    return null
  }
}

function dashboardSnapshotFromAggregate(
  aggregate: NodeAggregateResponse,
  nowValue?: number,
): DashboardSnapshot {
  const resourceErrors: string[] = []
  let metrics: PrometheusMetrics
  try {
    metrics = parsePrometheusMetrics(aggregate.metrics_text)
  } catch (error) {
    metrics = fallbackMetrics()
    resourceErrors.push(`metrics:${error instanceof Error ? error.name : 'error'}`)
  }
  const now = nowValue ?? Date.now()
  const sourceTimestamp = aggregate.status.timestamp ?? aggregate.health_current.timestamp
  const freshness = observationFreshness(sourceTimestamp, now)
  return {
    state: statusFromPayload(aggregate.status.overall_status, aggregate.events),
    nodeId: aggregate.identity.node_id,
    region: aggregate.identity.region,
    provider: aggregate.identity.provider,
    healthScore: aggregate.status.health_score ?? aggregate.health_current.health_score,
    connectionState: aggregate.connection.connection_state,
    protocol: aggregate.connection.protocol,
    services: aggregate.services.services,
    p50LatencyMs: metricValue(metrics, 'x_superplay_latency_p50_ms'),
    p95LatencyMs: metricValue(metrics, 'x_superplay_latency_p95_ms') ?? aggregate.health_history.latency_percentiles.p95,
    httpSuccessRate: metricValue(metrics, 'x_superplay_http_success_rate') ?? aggregate.health_history.availability,
    alertCount: metricValue(metrics, 'x_superplay_alert_count') ?? aggregate.events.events.length,
    timestamp: sourceTimestamp,
    corruptedEvidenceCount: Math.max(aggregate.status.corrupted_evidence_count, aggregate.health_current.corrupted_evidence_count),
    freshness: freshness.freshness,
    sourceTimestamp,
    receivedAt: new Date(now).toISOString(),
    ageMs: freshness.ageMs,
    clientState: 'normal',
    apiVersion: aggregate.metadata.api_version,
    resourceErrors,
    lastErrorCategory: null,
  }
}

export async function loadDashboardSnapshot(
  client: EdgeApiClient,
  options: { signal?: AbortSignal; now?: number; budget?: RequestBudget } = {},
): Promise<DashboardSnapshot> {
  const aggregate = await loadAggregate(client, options)
  if (aggregate) return dashboardSnapshotFromAggregate(aggregate, options.now)

  const resourceErrors: string[] = []
  const servicesRequest = settle(() => client.getNodeServices(options.signal, OPTIONAL_BUDGET))
  const connectionRequest = settle(() => client.getNodeConnection(options.signal, OPTIONAL_BUDGET))
  const historyRequest = settle(() => client.getHealthHistory(options.signal, OPTIONAL_BUDGET))
  const eventsRequest = settle(() => client.getEvents(options.signal, OPTIONAL_BUDGET))
  const metricsRequest = settle(() => client.getMetrics(options.signal, OPTIONAL_BUDGET))

  const [status, identity, current, metadata] = await Promise.all([
    client.getNodeStatus(options.signal, options.budget),
    client.getNodeIdentity(options.signal, options.budget),
    client.getHealthCurrent(options.signal, options.budget),
    client.getNodeMetadata(options.signal, options.budget),
  ])
  const services = unwrap('services', await servicesRequest, () => fallbackServices(status), resourceErrors)
  const connection = unwrap('connection', await connectionRequest, () => fallbackConnection(status), resourceErrors)
  const history = unwrap('history', await historyRequest, fallbackHistory, resourceErrors)
  const events = unwrap('events', await eventsRequest, fallbackEvents, resourceErrors)
  const metrics = unwrap('metrics', await metricsRequest, fallbackMetrics, resourceErrors)
  const now = options.now ?? Date.now()
  const sourceTimestamp = status.timestamp ?? current.timestamp
  const freshness = observationFreshness(sourceTimestamp, now)

  return {
    state: statusFromPayload(status.overall_status, events),
    nodeId: identity.node_id,
    region: identity.region,
    provider: identity.provider,
    healthScore: status.health_score ?? current.health_score,
    connectionState: connection.connection_state,
    protocol: connection.protocol,
    services: services.services,
    p50LatencyMs: metricValue(metrics, 'x_superplay_latency_p50_ms'),
    p95LatencyMs: metricValue(metrics, 'x_superplay_latency_p95_ms') ?? history.latency_percentiles.p95,
    httpSuccessRate: metricValue(metrics, 'x_superplay_http_success_rate') ?? history.availability,
    alertCount: metricValue(metrics, 'x_superplay_alert_count') ?? events.events.length,
    timestamp: sourceTimestamp,
    corruptedEvidenceCount: Math.max(status.corrupted_evidence_count, current.corrupted_evidence_count),
    freshness: freshness.freshness,
    sourceTimestamp,
    receivedAt: new Date(now).toISOString(),
    ageMs: freshness.ageMs,
    clientState: 'normal',
    apiVersion: metadata.api_version,
    resourceErrors,
    lastErrorCategory: null,
  }
}

export function markDashboardSnapshotFailed(snapshot: DashboardSnapshot, error: unknown): DashboardSnapshot {
  const freshness = observationFreshness(snapshot.sourceTimestamp)
  const kind = error instanceof Error && 'kind' in error ? error.kind : undefined
  return {
    ...snapshot,
    freshness: snapshot.sourceTimestamp ? 'stale' : freshness.freshness,
    clientState: kind === 'unsupported_api_version'
      ? 'unsupported_api_version'
      : error instanceof ApiResponseError ? 'malformed_response' : 'backend_unavailable',
    lastErrorCategory: error instanceof Error && 'category' in error
      ? error.category as DashboardSnapshot['lastErrorCategory']
      : 'transport',
  }
}

function fallbackCapabilities(): NodeCapabilitiesResponse {
  return { wireguard: false, xray_reality: false, hysteria2: false }
}

export async function loadNodeSnapshot(
  client: EdgeApiClient,
  options: { signal?: AbortSignal; now?: number; budget?: RequestBudget } = {},
): Promise<NodeSnapshot> {
  const aggregate = await loadAggregate(client, options)
  if (aggregate) {
    const now = options.now ?? Date.now()
    const aggregateFreshness = observationFreshness(aggregate.status.timestamp, now)
    return {
      status: aggregate.status,
      identity: aggregate.identity,
      capabilities: aggregate.capabilities,
      metadata: aggregate.metadata,
      services: aggregate.services,
      connection: aggregate.connection,
      freshness: aggregateFreshness.freshness,
      sourceTimestamp: aggregate.status.timestamp,
      receivedAt: new Date(now).toISOString(),
      ageMs: aggregateFreshness.ageMs,
      clientState: 'normal' as const,
      resourceErrors: [],
      lastErrorCategory: null,
    }
  }

  const resourceErrors: string[] = []
  const capabilitiesRequest = settle(() => client.getNodeCapabilities(options.signal, OPTIONAL_BUDGET))
  const servicesRequest = settle(() => client.getNodeServices(options.signal, OPTIONAL_BUDGET))
  const connectionRequest = settle(() => client.getNodeConnection(options.signal, OPTIONAL_BUDGET))
  const [status, identity, metadata] = await Promise.all([
    client.getNodeStatus(options.signal, options.budget),
    client.getNodeIdentity(options.signal, options.budget),
    client.getNodeMetadata(options.signal, options.budget),
  ])
  const capabilities = unwrap('capabilities', await capabilitiesRequest, fallbackCapabilities, resourceErrors)
  const services = unwrap('services', await servicesRequest, () => fallbackServices(status), resourceErrors)
  const connection = unwrap('connection', await connectionRequest, () => fallbackConnection(status), resourceErrors)
  const now = options.now ?? Date.now()
  const sourceTimestamp = status.timestamp
  const freshness = observationFreshness(sourceTimestamp, now)
  return {
    status,
    identity,
    capabilities,
    metadata,
    services,
    connection,
    freshness: freshness.freshness,
    sourceTimestamp,
    receivedAt: new Date(now).toISOString(),
    ageMs: freshness.ageMs,
    clientState: 'normal' as const,
    resourceErrors,
    lastErrorCategory: null,
  }
}

export function markNodeSnapshotFailed(snapshot: Awaited<ReturnType<typeof loadNodeSnapshot>>, error: unknown) {
  const kind = error instanceof Error && 'kind' in error ? error.kind : undefined
  return {
    ...snapshot,
    freshness: snapshot.sourceTimestamp ? 'stale' as const : 'unavailable' as const,
    clientState: kind === 'unsupported_api_version'
      ? 'unsupported_api_version' as const
      : error instanceof ApiResponseError ? 'malformed_response' as const : 'backend_unavailable' as const,
    lastErrorCategory: error instanceof Error && 'category' in error
      ? error.category as typeof snapshot.lastErrorCategory
      : 'transport' as const,
  }
}

export function formatServiceName(name: ServiceName): string {
  if (name === 'xray_reality') return 'Xray Reality'
  if (name === 'hysteria2') return 'Hysteria2'
  return 'WireGuard'
}

export function formatAlertType(event: AlertEvent): string {
  return event.metric || event.reason
}
