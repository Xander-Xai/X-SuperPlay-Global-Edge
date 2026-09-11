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
})
