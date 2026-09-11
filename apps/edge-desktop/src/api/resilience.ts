export const SUPPORTED_API_MAJOR = 'v1'
export const DEFAULT_TIMEOUT_MS = 5000
export const DEFAULT_MAX_ATTEMPTS = 2
export const STALE_THRESHOLD_MS = 5 * 60 * 1000
export const POLL_INTERVAL_MS = 30 * 1000

export type ClientApiState =
  | 'normal'
  | 'backend_unavailable'
  | 'malformed_response'
  | 'unsupported_api_version'

export type ObservationFreshness = 'fresh' | 'stale' | 'unavailable'

export type ErrorCategory =
  | 'transport'
  | 'timeout'
  | 'http'
  | 'malformed'
  | 'unsupported_api_version'
  | 'cancelled'

export class ApiUnavailableError extends Error {
  readonly kind = 'unavailable' as const
  readonly category: Exclude<ErrorCategory, 'malformed' | 'unsupported_api_version' | 'cancelled'>
  readonly status?: number

  constructor(
    message = 'Read-only observation API is unavailable',
    category: 'transport' | 'timeout' | 'http' = 'transport',
    status?: number,
  ) {
    super(message)
    this.name = 'ApiUnavailableError'
    this.category = category
    this.status = status
  }
}

export class ApiTimeoutError extends ApiUnavailableError {
  constructor(message = 'Read-only observation API request timed out') {
    super(message, 'timeout')
    this.name = 'ApiTimeoutError'
  }
}

export class ApiCancelledError extends Error {
  readonly kind = 'cancelled' as const
  readonly category = 'cancelled' as const

  constructor(message = 'Read-only observation request was cancelled') {
    super(message)
    this.name = 'ApiCancelledError'
  }
}

export class ApiResponseError extends Error {
  readonly kind = 'malformed' as const
  readonly category = 'malformed' as const

  constructor(message: string) {
    super(message)
    this.name = 'ApiResponseError'
  }
}

export class UnsupportedApiVersionError extends Error {
  readonly kind = 'unsupported_api_version' as const
  readonly category = 'unsupported_api_version' as const
  readonly version: string

  constructor(version: string) {
    super(`Unsupported observation API major version: ${version}`)
    this.name = 'UnsupportedApiVersionError'
    this.version = version
  }
}

export interface RequestPolicyOptions {
  timeoutMs?: number
  maxAttempts?: number
  signal?: AbortSignal
  fetchImpl?: typeof fetch
}

const RETRYABLE_HTTP_STATUSES = new Set([502, 503, 504])

function isAbortError(error: unknown): boolean {
  return error instanceof DOMException && error.name === 'AbortError'
}

function isRetryableTransport(error: unknown): boolean {
  return !(error instanceof ApiCancelledError)
}

/**
 * One bounded GET policy used by every HTTP resource adapter.
 * A fresh AbortController is created per attempt so a timed-out attempt cannot
 * leak into the next bounded retry.
 */
export async function requestWithPolicy(
  url: string,
  init: RequestInit = {},
  options: RequestPolicyOptions = {},
): Promise<Response> {
  const method = (init.method ?? 'GET').toUpperCase()
  if (method !== 'GET') throw new ApiResponseError(`Read-only request policy rejected ${method}`)

  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS
  const maxAttempts = Math.min(DEFAULT_MAX_ATTEMPTS, Math.max(1, options.maxAttempts ?? DEFAULT_MAX_ATTEMPTS))
  const fetchImpl = options.fetchImpl ?? fetch

  if (options.signal?.aborted) throw new ApiCancelledError()

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const controller = new AbortController()
    let timedOut = false
    const onAbort = () => controller.abort()
    options.signal?.addEventListener('abort', onAbort, { once: true })
    const timer = setTimeout(() => {
      timedOut = true
      controller.abort()
    }, timeoutMs)

    try {
      const response = await fetchImpl(url, { ...init, method: 'GET', signal: controller.signal })
      if (RETRYABLE_HTTP_STATUSES.has(response.status) && attempt < maxAttempts) continue
      if (!response.ok) throw new ApiUnavailableError(`Read-only observation API returned HTTP ${response.status}`, 'http', response.status)
      return response
    } catch (error) {
      if (options.signal?.aborted && !timedOut) throw new ApiCancelledError()
      if (timedOut || isAbortError(error)) {
        if (attempt < maxAttempts) continue
        throw new ApiTimeoutError()
      }
      if (error instanceof ApiUnavailableError && error.category === 'http') throw error
      if (error instanceof ApiResponseError || error instanceof UnsupportedApiVersionError) throw error
      if (attempt < maxAttempts && isRetryableTransport(error)) continue
      throw new ApiUnavailableError(error instanceof Error ? error.message : 'Network request failed')
    } finally {
      clearTimeout(timer)
      options.signal?.removeEventListener('abort', onAbort)
    }
  }

  throw new ApiUnavailableError('Read-only observation API request failed')
}

export function validateContentType(response: Response, expected: 'json' | 'text', resource: string): void {
  const contentType = response.headers.get('content-type')?.split(';', 1)[0].trim().toLowerCase() ?? ''
  const valid = expected === 'json'
    ? contentType === 'application/json' || contentType.endsWith('+json')
    : contentType === 'text/plain'
  if (!valid) throw new ApiResponseError(`${resource} returned incompatible Content-Type: ${contentType || 'missing'}`)
}

export function assertSupportedApiVersion(version: string): void {
  const major = /^v\d+/.exec(version)?.[0]
  if (major !== SUPPORTED_API_MAJOR) throw new UnsupportedApiVersionError(version)
}

export function classifyClientApiState(error: unknown): ClientApiState {
  if (error instanceof UnsupportedApiVersionError) return 'unsupported_api_version'
  if (error instanceof ApiResponseError) return 'malformed_response'
  return 'backend_unavailable'
}

export function errorCategory(error: unknown): ErrorCategory {
  if (error instanceof ApiCancelledError) return 'cancelled'
  if (error instanceof UnsupportedApiVersionError) return 'unsupported_api_version'
  if (error instanceof ApiResponseError) return 'malformed'
  if (error instanceof ApiTimeoutError) return 'timeout'
  if (error instanceof ApiUnavailableError) return error.category
  return 'transport'
}

export function observationFreshness(
  sourceTimestamp: string | null,
  receivedAt = Date.now(),
): { freshness: ObservationFreshness; ageMs: number | null } {
  if (!sourceTimestamp) return { freshness: 'unavailable', ageMs: null }
  const sourceMs = Date.parse(sourceTimestamp)
  if (!Number.isFinite(sourceMs)) return { freshness: 'unavailable', ageMs: null }
  const ageMs = Math.max(0, receivedAt - sourceMs)
  return {
    freshness: ageMs > STALE_THRESHOLD_MS ? 'stale' : 'fresh',
    ageMs,
  }
}
