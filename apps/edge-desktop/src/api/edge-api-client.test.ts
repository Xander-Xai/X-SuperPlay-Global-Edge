import { describe, expect, it, vi } from 'vitest'
import {
  ApiResponseError,
  ApiTimeoutError,
  ApiUnavailableError,
  HttpEdgeApiClient,
  UnsupportedApiVersionError,
  loadDashboardSnapshot,
  parsePrometheusMetrics,
} from './edge-api-client'
import { MockEdgeApiClient } from './mock-edge-api-client'
import type { NodeConnectionResponse } from './types'

const service = (name: 'wireguard' | 'xray_reality' | 'hysteria2') => ({
  name,
  status: 'unavailable',
  reason: 'fixture',
  source: 'test',
})

const nodeStatus = {
  node_id: 'edge-test',
  overall_status: 'healthy',
  health_score: 100,
  service_states: {
    wireguard: service('wireguard'),
    xray_reality: service('xray_reality'),
    hysteria2: service('hysteria2'),
  },
  timestamp: '2026-09-10T00:00:00.000Z',
  corrupted_evidence_count: 0,
}

function jsonResponse(body: unknown, status = 200, contentType = 'application/json; charset=utf-8') {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': contentType } })
}

const nodeIdentity = {
  node_id: 'edge-test',
  region: 'example-region',
  provider: 'example-provider',
  version: 'p13-test',
}

const nodeServices = {
  node_id: 'edge-test',
  services: nodeStatus.service_states,
  timestamp: nodeStatus.timestamp,
  corrupted_evidence_count: 0,
}

const nodeConnection = {
  node_id: 'edge-test',
  connection_state: 'connected',
  protocol: 'tcp_probe',
  endpoint_metadata: { host: 'edge.example.invalid', port: 443 },
  timestamp: nodeStatus.timestamp,
  corrupted_evidence_count: 0,
}

const nodeCapabilities = { wireguard: true, xray_reality: true, hysteria2: false }

const nodeMetadata = { node_id: 'edge-test', runtime_version: 'edge-runtime-state-v1', api_version: 'v1' }

const healthCurrent = {
  node_status: 'healthy',
  health_score: 100,
  latest_metrics: {},
  timestamp: nodeStatus.timestamp,
  corrupted_evidence_count: 0,
}

const healthHistory = {
  availability: 100,
  latency_percentiles: { p95: 120 },
  historical_summary: { total_checks: 1, success_rate: 100 },
}

const eventsResponse = { events: [], resolved: true, timestamp: nodeStatus.timestamp }

const metricsText = [
  '# TYPE x_superplay_health_score gauge',
  'x_superplay_health_score 100',
  'x_superplay_http_success_rate 100',
  'x_superplay_latency_p50_ms 60',
  'x_superplay_latency_p95_ms 120',
  'x_superplay_node_status 1',
  'x_superplay_alert_count 0',
].join('\n')

const aggregatePayload = {
  status: nodeStatus,
  identity: nodeIdentity,
  services: nodeServices,
  connection: nodeConnection,
  capabilities: nodeCapabilities,
  metadata: nodeMetadata,
  health_current: healthCurrent,
  health_history: healthHistory,
  events: eventsResponse,
  metrics_text: metricsText,
}

const perResourceRoutes: Record<string, unknown> = {
  '/api/v1/node/status': nodeStatus,
  '/api/v1/node/identity': nodeIdentity,
  '/api/v1/node/services': nodeServices,
  '/api/v1/node/connection': nodeConnection,
  '/api/v1/node/capabilities': nodeCapabilities,
  '/api/v1/node/metadata': nodeMetadata,
  '/api/v1/health/current': healthCurrent,
  '/api/v1/health/history': healthHistory,
  '/api/v1/events': eventsResponse,
}

function perResourceFetch(url: string): Response {
  if (url.endsWith('/metrics')) {
    return new Response(metricsText, { status: 200, headers: { 'content-type': 'text/plain; version=0.0.4' } })
  }
  const route = Object.keys(perResourceRoutes).find((candidate) => url.endsWith(candidate))
  return jsonResponse(perResourceRoutes[route as string])
}

describe('Edge API adapter', () => {
  it.each(['healthy', 'warning', 'critical', 'unknown', 'events'] as const)('supports %s mock fixture', async (scenario) => {
    const client = new MockEdgeApiClient(scenario)
    const events = await client.getEvents()
    const status = await client.getNodeStatus()
    expect(status.node_id).toBe('edge-demo')
    expect(Array.isArray(events.events)).toBe(true)
  })

  it('models unavailable backend without a network call', async () => {
    await expect(new MockEdgeApiClient('unavailable').getNodeStatus()).rejects.toMatchObject({ kind: 'unavailable' })
  })

  it('performs a successful bounded GET with JSON content type validation', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(nodeStatus))
    const client = new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: fetchMock })
    await expect(client.getNodeStatus()).resolves.toMatchObject({ node_id: 'edge-test' })
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0][1]).toMatchObject({ method: 'GET', headers: { Accept: 'application/json' } })
  })

  it('retries one transient transport failure, then succeeds', async () => {
    const fetchMock = vi.fn()
      .mockRejectedValueOnce(new TypeError('connection reset'))
      .mockResolvedValueOnce(jsonResponse(nodeStatus))
    const client = new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: fetchMock })
    await expect(client.getNodeStatus()).resolves.toMatchObject({ node_id: 'edge-test' })
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('enforces the two-attempt transport retry limit', async () => {
    const fetchMock = vi.fn().mockRejectedValue(new TypeError('offline'))
    const client = new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: fetchMock })
    await expect(client.getNodeStatus()).rejects.toMatchObject({ kind: 'unavailable', category: 'transport' })
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('cancels timed-out requests and makes only the bounded retry', async () => {
    const fetchMock = vi.fn((_url: RequestInfo | URL, init?: RequestInit) => new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener('abort', () => reject(new DOMException('Aborted', 'AbortError')), { once: true })
    }))
    const client = new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: fetchMock as unknown as typeof fetch, timeoutMs: 5 })
    await expect(client.getNodeStatus()).rejects.toBeInstanceOf(ApiTimeoutError)
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it.each([404, 405])('does not retry non-retryable HTTP %s', async (status) => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse({ error: 'not allowed' }, status))
    const client = new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: fetchMock })
    await expect(client.getNodeStatus()).rejects.toMatchObject({ kind: 'unavailable', status })
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('retries a safe transient server response', async () => {
    const fetchMock = vi.fn()
      .mockResolvedValueOnce(jsonResponse({ error: 'temporary' }, 503))
      .mockResolvedValueOnce(jsonResponse(nodeStatus))
    const client = new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: fetchMock })
    await expect(client.getNodeStatus()).resolves.toMatchObject({ node_id: 'edge-test' })
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('does not retry malformed payloads or content-type mismatches', async () => {
    const malformed = vi.fn().mockResolvedValue(new Response('{bad', { status: 200, headers: { 'content-type': 'application/json' } }))
    await expect(new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: malformed }).getNodeStatus()).rejects.toBeInstanceOf(ApiResponseError)
    expect(malformed).toHaveBeenCalledTimes(1)

    const wrongType = vi.fn().mockResolvedValue(jsonResponse(nodeStatus, 200, 'text/plain'))
    await expect(new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: wrongType }).getNodeStatus()).rejects.toBeInstanceOf(ApiResponseError)
    expect(wrongType).toHaveBeenCalledTimes(1)
  })

  it('rejects invalid counts without retry and distinguishes unsupported API major versions', async () => {
    const invalid = vi.fn().mockResolvedValue(jsonResponse({ ...nodeStatus, corrupted_evidence_count: -1 }))
    await expect(new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: invalid }).getNodeStatus()).rejects.toBeInstanceOf(ApiResponseError)
    expect(invalid).toHaveBeenCalledTimes(1)

    const metadata = vi.fn().mockResolvedValue(jsonResponse({ node_id: 'edge-test', runtime_version: 'runtime', api_version: 'v2' }))
    await expect(new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: metadata }).getNodeMetadata()).rejects.toBeInstanceOf(UnsupportedApiVersionError)
    expect(metadata).toHaveBeenCalledTimes(1)
  })

  it('accepts additive fields and preserves optional-resource boundaries', async () => {
    class PartialClient extends MockEdgeApiClient {
      override async getNodeConnection(): Promise<NodeConnectionResponse> {
        throw new ApiUnavailableError('connection unavailable')
      }
    }
    const partial = new PartialClient('healthy')
    const snapshot = await loadDashboardSnapshot(partial)
    expect(snapshot.clientState).toBe('normal')
    expect(snapshot.resourceErrors).toContain('connection:ApiUnavailableError')
    expect(snapshot.connectionState).toBe('unknown')

    const additive = { ...nodeStatus, additive_field: { retained: true } }
    const client = new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: vi.fn().mockResolvedValue(jsonResponse(additive)) })
    await expect(client.getNodeStatus()).resolves.toMatchObject({ additive_field: { retained: true } })
  })

  it('requires compatible Prometheus text and accepts NaN as unavailable', () => {
    expect(() => parsePrometheusMetrics('x_superplay_health_score nope')).toThrow(ApiResponseError)
    const text = [
      '# TYPE x_superplay_health_score gauge',
      'x_superplay_health_score NaN',
      'x_superplay_http_success_rate 100',
      'x_superplay_latency_p50_ms NaN',
      'x_superplay_latency_p95_ms 300',
      'x_superplay_node_status 1',
      'x_superplay_alert_count 0',
    ].join('\n')
    const metrics = parsePrometheusMetrics(text)
    expect(Number.isNaN(metrics.x_superplay_health_score)).toBe(true)
    expect(metrics.x_superplay_alert_count).toBe(0)
  })

  it('serves the whole dashboard from one aggregate request when the API exposes it', async () => {
    const fetchMock = vi.fn().mockResolvedValue(jsonResponse(aggregatePayload))
    const client = new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: fetchMock })
    const snapshot = await loadDashboardSnapshot(client)
    expect(snapshot.nodeId).toBe('edge-test')
    expect(snapshot.p95LatencyMs).toBe(120)
    expect(snapshot.resourceErrors).toEqual([])
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(fetchMock.mock.calls[0][0]).toBe('http://127.0.0.1:8080/api/v1/node/snapshot')
  })

  it('falls back to the per-resource endpoints when the aggregate route is not served', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      if (url.endsWith('/api/v1/node/snapshot')) return jsonResponse({ error: 'not_found' }, 404)
      return perResourceFetch(url)
    })
    const client = new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: fetchMock as unknown as typeof fetch })
    const snapshot = await loadDashboardSnapshot(client)
    expect(snapshot.nodeId).toBe('edge-test')
    expect(snapshot.p95LatencyMs).toBe(120)
    expect(snapshot.resourceErrors).toEqual([])
  })

  it('stops probing the aggregate route after the server reported it as absent', async () => {
    const fetchMock = vi.fn(async (url: string) => {
      if (url.endsWith('/api/v1/node/snapshot')) return jsonResponse({ error: 'not_found' }, 404)
      return perResourceFetch(url)
    })
    const client = new HttpEdgeApiClient('http://127.0.0.1:8080', { fetchImpl: fetchMock as unknown as typeof fetch })
    await loadDashboardSnapshot(client)
    await loadDashboardSnapshot(client)
    const aggregateCalls = fetchMock.mock.calls.filter((call) => String(call[0]).endsWith('/api/v1/node/snapshot'))
    expect(aggregateCalls).toHaveLength(1)
  })
})
