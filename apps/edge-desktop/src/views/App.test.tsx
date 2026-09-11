import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import App from '../App'
import { MockEdgeApiClient } from '../api'
import type { NodeStatusResponse } from '../api'

describe('desktop MVP views', () => {
  it('renders healthy dashboard metrics and services', async () => {
    render(<App client={new MockEdgeApiClient('healthy')} />)
    expect(screen.getByRole('status')).toBeInTheDocument()
    await waitFor(() => expect(screen.getByText('Edge overview')).toBeInTheDocument())
    expect(screen.getByText('Healthy')).toBeInTheDocument()
    expect(screen.getByText('100%')).toBeInTheDocument()
    expect(screen.getByText('Xray Reality')).toBeInTheDocument()
    expect(screen.getByText('P50 latency')).toBeInTheDocument()
  })

  it.each([
    ['warning', 'Warning'],
    ['critical', 'Critical'],
    ['unknown', 'Unknown'],
  ] as const)('renders %s state without promoting it to healthy', async (scenario, label) => {
    render(<App client={new MockEdgeApiClient(scenario)} />)
    await waitFor(() => expect(screen.getByText(label)).toBeInTheDocument())
    expect(screen.queryByText('Healthy')).not.toBeInTheDocument()
  })

  it('renders explicit unavailable state when backend cannot be reached', async () => {
    render(<App client={new MockEdgeApiClient('unavailable')} />)
    await waitFor(() => expect(screen.getByText('Edge API is unavailable')).toBeInTheDocument())
    expect(screen.getByText('Retry read-only request')).toBeInTheDocument()
  })

  it('renders events and resolved empty state', async () => {
    render(<App client={new MockEdgeApiClient('events')} initialView="events" />)
    await waitFor(() => expect(screen.getByText('Evidence-backed events')).toBeInTheDocument())
    expect(screen.getByText('success_rate')).toBeInTheDocument()
    expect(screen.getByText('WARNING')).toBeInTheDocument()

    cleanup()
    render(<App client={new MockEdgeApiClient('healthy')} initialView="events" />)
    await waitFor(() => expect(screen.getByText('No active events')).toBeInTheDocument())
  })

  it('renders node identity, versions, and capabilities', async () => {
    render(<App client={new MockEdgeApiClient('healthy')} initialView="node" />)
    await waitFor(() => expect(screen.getByText('Node identity')).toBeInTheDocument())
    expect(screen.getByText('edge-demo')).toBeInTheDocument()
    expect(screen.getByText('example-region')).toBeInTheDocument()
    expect(screen.getByText('edge-runtime-state-v1')).toBeInTheDocument()
    expect(screen.getAllByText('WireGuard').length).toBeGreaterThanOrEqual(2)
    expect(screen.getAllByText('Declared').length).toBeGreaterThanOrEqual(2)
  })

  it('does not label an unknown node as healthy', async () => {
    render(<App client={new MockEdgeApiClient('unknown')} initialView="node" />)
    await waitFor(() => expect(screen.getByText('Node identity')).toBeInTheDocument())
    expect(screen.getByText('Unknown')).toBeInTheDocument()
    expect(screen.queryByText('Healthy')).not.toBeInTheDocument()
  })

  it('renders stale freshness separately from a last observed healthy runtime', async () => {
    render(<App client={new MockEdgeApiClient('stale')} />)
    await waitFor(() => expect(screen.getByText('Observation STALE')).toBeInTheDocument())
    expect(screen.getByText('Healthy')).toBeInTheDocument()
    expect(screen.getByText(/not current\/live/)).toBeInTheDocument()
  })

  it('distinguishes malformed responses and unsupported API versions', async () => {
    render(<App client={new MockEdgeApiClient('malformed-content-type')} />)
    await waitFor(() => expect(screen.getByText('MALFORMED RESPONSE')).toBeInTheDocument())
    cleanup()

    render(<App client={new MockEdgeApiClient('unsupported-api-version')} />)
    await waitFor(() => expect(screen.getByText('UNSUPPORTED API VERSION')).toBeInTheDocument())
    expect(screen.getByText('Observation API version is not supported')).toBeInTheDocument()
  })

  it('keeps the last-known-good dashboard visible when a later refresh fails', async () => {
    class FlakyClient extends MockEdgeApiClient {
      private statusCalls = 0

      override async getNodeStatus(signal?: AbortSignal): Promise<NodeStatusResponse> {
        this.statusCalls += 1
        if (this.statusCalls > 1) throw new Error('simulated transport failure')
        return super.getNodeStatus(signal)
      }
    }
    const client = new FlakyClient('healthy')
    render(<App client={client} />)
    await waitFor(() => expect(screen.getByText('Edge overview')).toBeInTheDocument())
    fireEvent.click(screen.getByRole('button', { name: 'Refresh evidence' }))
    await waitFor(() => expect(screen.getByText('Observation STALE')).toBeInTheDocument())
    expect(screen.getByText('Edge overview')).toBeInTheDocument()
    expect(screen.getByText(/latest request: transport/)).toBeInTheDocument()
  })

  it('prevents an older refresh response from overwriting a newer one', async () => {
    let releaseFirst!: () => void
    let statusCalls = 0
    const oldClient = new MockEdgeApiClient('critical')
    class RaceClient extends MockEdgeApiClient {
      override getNodeStatus(signal?: AbortSignal): Promise<NodeStatusResponse> {
        statusCalls += 1
        if (statusCalls === 1) {
          return new Promise<NodeStatusResponse>((resolve) => {
            releaseFirst = () => { void oldClient.getNodeStatus(signal).then(resolve) }
          })
        }
        return super.getNodeStatus(signal)
      }
    }
    const client = new RaceClient('healthy')
    render(<App client={client} />)
    fireEvent.click(screen.getByRole('button', { name: 'Refresh evidence' }))
    await waitFor(() => expect(screen.getByText('Healthy')).toBeInTheDocument())
    releaseFirst()
    await new Promise((resolve) => setTimeout(resolve, 0))
    expect(screen.getByText('Healthy')).toBeInTheDocument()
    expect(screen.queryByText('Critical')).not.toBeInTheDocument()
  })
})
