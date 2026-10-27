export type BackendStatus = 'healthy' | 'degraded' | 'unknown'
export type { ClientApiState, ErrorCategory, ObservationFreshness } from './resilience'

import type {
  ClientApiState,
  ErrorCategory,
  ObservationFreshness,
  RequestBudget,
} from './resilience'
export type DisplayHealthState = 'healthy' | 'warning' | 'critical' | 'unavailable' | 'unknown'

export type ServiceName = 'wireguard' | 'xray_reality' | 'hysteria2'

export interface ServiceState {
  name: ServiceName
  status: string
  reason: string
  source: string
}

export interface NodeStatusResponse {
  node_id: string
  overall_status: BackendStatus
  health_score: number | null
  service_states: Record<ServiceName, ServiceState>
  timestamp: string | null
  corrupted_evidence_count: number
}

export interface NodeIdentityResponse {
  node_id: string
  region: string
  provider: string
  version: string
}

export interface NodeServicesResponse {
  node_id: string
  services: Record<ServiceName, ServiceState>
  timestamp: string | null
  corrupted_evidence_count: number
}

export interface NodeConnectionResponse {
  node_id: string
  connection_state: string
  protocol: string
  endpoint_metadata: Record<string, unknown>
  timestamp: string | null
  corrupted_evidence_count: number
}

export interface NodeCapabilitiesResponse {
  wireguard: boolean
  xray_reality: boolean
  hysteria2: boolean
}

export interface NodeMetadataResponse {
  node_id: string
  runtime_version: string
  api_version: string
}

export interface HealthCurrentResponse {
  node_status: BackendStatus
  health_score: number | null
  latest_metrics: Record<string, unknown>
  timestamp: string | null
  corrupted_evidence_count: number
}

export interface HealthHistoryResponse {
  availability: number | null
  latency_percentiles: { p95: number | null }
  historical_summary: Record<string, unknown>
}

export type AlertLevel = 'WARNING' | 'CRITICAL' | 'NONE'

export interface AlertEvent {
  timestamp: string
  level: AlertLevel
  reason: string
  metric: string
  value: number | null
  threshold: number | null
  source_evidence: string
  resolved: boolean
}

export interface EventsResponse {
  events: AlertEvent[]
  resolved: boolean | null
  timestamp?: string | null
  error?: string
}

export type PrometheusMetrics = Record<string, number>

export interface EdgeApiClient {
  getNodeStatus(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeStatusResponse>
  getNodeIdentity(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeIdentityResponse>
  getNodeServices(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeServicesResponse>
  getNodeConnection(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeConnectionResponse>
  getNodeCapabilities(
    signal?: AbortSignal,
    budget?: RequestBudget,
  ): Promise<NodeCapabilitiesResponse>
  getNodeMetadata(signal?: AbortSignal, budget?: RequestBudget): Promise<NodeMetadataResponse>
  getHealthCurrent(signal?: AbortSignal, budget?: RequestBudget): Promise<HealthCurrentResponse>
  getHealthHistory(signal?: AbortSignal, budget?: RequestBudget): Promise<HealthHistoryResponse>
  getEvents(signal?: AbortSignal, budget?: RequestBudget): Promise<EventsResponse>
  getMetrics(signal?: AbortSignal, budget?: RequestBudget): Promise<PrometheusMetrics>
  /**
   * Optional single-round-trip aggregate of every dashboard resource. Clients
   * that do not implement it keep using the per-resource endpoints.
   */
  getNodeSnapshotAggregate?(
    signal?: AbortSignal,
    budget?: RequestBudget,
  ): Promise<NodeAggregateResponse>
}

/** One server response that carries every dashboard resource. */
export interface NodeAggregateResponse {
  status: NodeStatusResponse
  identity: NodeIdentityResponse
  services: NodeServicesResponse
  connection: NodeConnectionResponse
  capabilities: NodeCapabilitiesResponse
  metadata: NodeMetadataResponse
  health_current: HealthCurrentResponse
  health_history: HealthHistoryResponse
  events: EventsResponse
  metrics_text: string
}

export interface DashboardSnapshot {
  state: DisplayHealthState
  nodeId: string
  region: string
  provider: string
  healthScore: number | null
  connectionState: string
  protocol: string
  services: Record<ServiceName, ServiceState>
  p50LatencyMs: number | null
  p95LatencyMs: number | null
  httpSuccessRate: number | null
  alertCount: number | null
  timestamp: string | null
  corruptedEvidenceCount: number
  freshness: ObservationFreshness
  sourceTimestamp: string | null
  receivedAt: string
  ageMs: number | null
  clientState: ClientApiState
  apiVersion: string
  resourceErrors: string[]
  lastErrorCategory: ErrorCategory | null
}

export interface NodeSnapshot {
  status: NodeStatusResponse
  identity: NodeIdentityResponse
  capabilities: NodeCapabilitiesResponse
  metadata: NodeMetadataResponse
  services: NodeServicesResponse
  connection: NodeConnectionResponse
  freshness: ObservationFreshness
  sourceTimestamp: string | null
  receivedAt: string
  ageMs: number | null
  clientState: ClientApiState
  resourceErrors: string[]
  lastErrorCategory: ErrorCategory | null
}
