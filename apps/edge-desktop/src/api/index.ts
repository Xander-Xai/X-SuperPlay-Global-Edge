import { HttpEdgeApiClient } from './edge-api-client'
import { MockEdgeApiClient, type MockScenario } from './mock-edge-api-client'
import type { EdgeApiClient } from './types'

export * from './edge-api-client'
export * from './mock-edge-api-client'
export * from './resilience'
export * from './types'

export function createEdgeApiClient(): EdgeApiClient {
  const baseUrl = import.meta.env.VITE_EDGE_API_BASE_URL
  if (typeof baseUrl === 'string' && baseUrl.trim()) return new HttpEdgeApiClient(baseUrl)
  const scenario = (import.meta.env.VITE_EDGE_MOCK_SCENARIO || 'healthy') as MockScenario
  const supported: MockScenario[] = [
    'healthy', 'warning', 'critical', 'unavailable', 'unknown', 'events',
    'stale', 'timeout', 'transient-retry-success', 'malformed-content-type',
    'unsupported-api-version',
  ]
  return new MockEdgeApiClient(supported.includes(scenario) ? scenario : 'healthy')
}
