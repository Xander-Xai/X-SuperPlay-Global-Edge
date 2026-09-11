import { describe, expect, it } from 'vitest'
import {
  DEFAULT_MAX_ATTEMPTS,
  DEFAULT_TIMEOUT_MS,
  STALE_THRESHOLD_MS,
  assertSupportedApiVersion,
  observationFreshness,
} from './resilience'

describe('read-only resilience policy', () => {
  it('keeps timeout and retry policy bounded', () => {
    expect(DEFAULT_TIMEOUT_MS).toBeGreaterThanOrEqual(3000)
    expect(DEFAULT_TIMEOUT_MS).toBeLessThanOrEqual(10000)
    expect(DEFAULT_MAX_ATTEMPTS).toBe(2)
  })

  it('classifies fresh, stale, and unavailable observations separately from health', () => {
    const now = Date.parse('2026-09-10T00:00:00.000Z')
    expect(observationFreshness('2026-09-09T23:59:00.000Z', now).freshness).toBe('fresh')
    expect(observationFreshness(new Date(now - STALE_THRESHOLD_MS - 1).toISOString(), now).freshness).toBe('stale')
    expect(observationFreshness(null, now)).toEqual({ freshness: 'unavailable', ageMs: null })
  })

  it('accepts v1 and rejects incompatible major versions', () => {
    expect(() => assertSupportedApiVersion('v1')).not.toThrow()
    expect(() => assertSupportedApiVersion('v2')).toThrow(/Unsupported observation API major version/)
  })
})
