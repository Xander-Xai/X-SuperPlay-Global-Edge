import type { DisplayHealthState } from '../api'

const labels: Record<DisplayHealthState, string> = {
  healthy: 'Healthy',
  warning: 'Warning',
  critical: 'Critical',
  unavailable: 'Unavailable',
  unknown: 'Unknown',
}

export function StatusBadge({ state }: { state: DisplayHealthState }) {
  return <span className={`status-badge status-${state}`}>{labels[state]}</span>
}

export function StateLabel({ state }: { state: DisplayHealthState }) {
  return <span className={`state-label state-${state}`}>{labels[state]}</span>
}
