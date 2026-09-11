import { ApiResponseError, ApiTimeoutError, ApiUnavailableError } from './edge-api-client'
import { assertSupportedApiVersion } from './resilience'
import type {
  EdgeApiClient,
  EventsResponse,
  HealthCurrentResponse,
  HealthHistoryResponse,
  NodeCapabilitiesResponse,
  NodeConnectionResponse,
  NodeIdentityResponse,
  NodeMetadataResponse,
  NodeServicesResponse,
  NodeStatusResponse,
  PrometheusMetrics,
} from './types'

export type MockScenario =
  | 'healthy'
  | 'warning'
  | 'critical'
  | 'unavailable'
  | 'unknown'
  | 'events'
  | 'stale'
  | 'timeout'
  | 'transient-retry-success'
  | 'malformed-content-type'
  | 'unsupported-api-version'

const timestamp = '2026-09-08T12:00:00.000Z'

function services(status: string) {
  return {
    wireguard: {
      name: 'wireguard' as const,
      status,
      reason: status === 'unavailable' ? 'service_state_not_present_in_local_evidence' : 'observed_by_mock_fixture',
      source: 'mock_fixture',
    },
    xray_reality: {
      name: 'xray_reality' as const,
      status,
      reason: status === 'unavailable' ? 'service_state_not_present_in_local_evidence' : 'observed_by_mock_fixture',
      source: 'mock_fixture',
    },
    hysteria2: {
      name: 'hysteria2' as const,
      status,
      reason: status === 'unavailable' ? 'service_state_not_present_in_local_evidence' : 'observed_by_mock_fixture',
      source: 'mock_fixture',
    },
  }
}

function warningEvent(): EventsResponse {
  return {
    events: [
      {
        timestamp,
        level: 'WARNING',
        reason: 'success_rate below threshold',
        metric: 'success_rate',
        value: 98,
        threshold: 99,
        source_evidence: 'mock-fixture/summary.json',
        resolved: false,
      },
    ],
    resolved: false,
    timestamp,
  }
}

function criticalEvent(): EventsResponse {
  return {
    events: [
      {
        timestamp,
        level: 'CRITICAL',
        reason: 'tcp failure count above threshold',
        metric: 'tcp_failures',
        value: 4,
        threshold: 3,
        source_evidence: 'mock-fixture/summary.json',
        resolved: false,
      },
    ],
    resolved: false,
    timestamp,
  }
}

function fixture(scenario: Exclude<MockScenario, 'unavailable' | 'timeout' | 'malformed-content-type'>) {
  const isUnknown = scenario === 'unknown'
  const isCritical = scenario === 'critical'
  const isWarning = scenario === 'warning' || scenario === 'events'
  const isStale = scenario === 'stale'
  const score = isUnknown ? null : isCritical ? 82 : isWarning ? 98 : 100
  const overallStatus = isUnknown ? 'unknown' : score !== null && score >= 99 ? 'healthy' : 'degraded'
  const serviceStatus = isUnknown ? 'unavailable' : 'observed'
  const nodeStatus: NodeStatusResponse = {
    node_id: 'edge-demo',
    overall_status: overallStatus,
    health_score: score,
    service_states: services(serviceStatus),
    timestamp: isUnknown ? null : isStale ? '2020-01-01T00:00:00.000Z' : timestamp,
    corrupted_evidence_count: 0,
  }
  const identity: NodeIdentityResponse = {
    node_id: 'edge-demo',
    region: 'example-region',
    provider: 'example-provider',
    version: 'p13-002-mock',
  }
  const nodeServices: NodeServicesResponse = {
    node_id: 'edge-demo',
    services: services(serviceStatus),
    timestamp: nodeStatus.timestamp,
    corrupted_evidence_count: 0,
  }
  const connection: NodeConnectionResponse = {
    node_id: 'edge-demo',
    connection_state: isUnknown ? 'unknown' : 'connected',
    protocol: isUnknown ? 'unknown' : 'tcp_probe',
    endpoint_metadata: { host: 'edge.example.invalid', port: 443 },
    timestamp: nodeStatus.timestamp,
    corrupted_evidence_count: 0,
  }
  const current: HealthCurrentResponse = {
    node_status: overallStatus,
    health_score: score,
    latest_metrics: isUnknown ? {} : { tcp: { success: true }, http: { gstatic: { success: true } } },
    timestamp: nodeStatus.timestamp,
    corrupted_evidence_count: 0,
  }
  const history: HealthHistoryResponse = {
    availability: isUnknown ? 0 : isWarning ? 98 : 100,
    latency_percentiles: { p95: isUnknown ? 0 : isCritical ? 480 : 120 },
    historical_summary: { total_checks: isUnknown ? 0 : 4, success_rate: isUnknown ? 0 : isWarning ? 98 : 100 },
  }
  const events = isCritical ? criticalEvent() : isWarning ? warningEvent() : { events: [], resolved: true, timestamp: nodeStatus.timestamp }
  const metrics: PrometheusMetrics = {
    x_superplay_health_score: score ?? Number.NaN,
    x_superplay_http_success_rate: history.availability ?? Number.NaN,
    x_superplay_latency_p50_ms: isUnknown ? Number.NaN : isCritical ? 240 : 60,
    x_superplay_latency_p95_ms: history.latency_percentiles.p95 ?? Number.NaN,
    x_superplay_node_status: overallStatus === 'healthy' ? 1 : overallStatus === 'degraded' ? 0 : Number.NaN,
    x_superplay_alert_count: events.events.length,
  }
  return {
    nodeStatus,
    identity,
    nodeServices,
    connection,
    current,
    history,
    events,
    metrics,
  }
}

export class MockEdgeApiClient implements EdgeApiClient {
  readonly scenario: MockScenario

  constructor(scenario: MockScenario = 'healthy') {
    this.scenario = scenario
  }

  private data() {
    if (this.scenario === 'unavailable') throw new ApiUnavailableError('Mock backend unavailable')
    if (this.scenario === 'timeout') throw new ApiTimeoutError('Mock request timed out')
    if (this.scenario === 'malformed-content-type') throw new ApiResponseError('Mock response returned incompatible Content-Type')
    return fixture(this.scenario === 'transient-retry-success' ? 'healthy' : this.scenario)
  }

  async getNodeStatus(_signal?: AbortSignal): Promise<NodeStatusResponse> { return this.data().nodeStatus }
  async getNodeIdentity(_signal?: AbortSignal): Promise<NodeIdentityResponse> { return this.data().identity }
  async getNodeServices(_signal?: AbortSignal): Promise<NodeServicesResponse> { return this.data().nodeServices }
  async getNodeConnection(_signal?: AbortSignal): Promise<NodeConnectionResponse> { return this.data().connection }
  async getNodeCapabilities(_signal?: AbortSignal): Promise<NodeCapabilitiesResponse> {
    this.data()
    return { wireguard: true, xray_reality: true, hysteria2: false }
  }
  async getNodeMetadata(_signal?: AbortSignal): Promise<NodeMetadataResponse> {
    const data = this.data()
    const metadata = {
      node_id: data.identity.node_id,
      runtime_version: 'edge-runtime-state-v1',
      api_version: this.scenario === 'unsupported-api-version' ? 'v2' : 'v1',
    }
    assertSupportedApiVersion(metadata.api_version)
    return metadata
  }
  async getHealthCurrent(_signal?: AbortSignal): Promise<HealthCurrentResponse> { return this.data().current }
  async getHealthHistory(_signal?: AbortSignal): Promise<HealthHistoryResponse> { return this.data().history }
  async getEvents(_signal?: AbortSignal): Promise<EventsResponse> { return this.data().events }
  async getMetrics(_signal?: AbortSignal): Promise<PrometheusMetrics> { return this.data().metrics }
}
