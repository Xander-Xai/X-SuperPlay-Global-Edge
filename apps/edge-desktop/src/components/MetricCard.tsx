export function MetricCard({ label, value, unit, tone = 'neutral' }: {
  label: string
  value: string
  unit?: string
  tone?: 'neutral' | 'good' | 'warning'
}) {
  return (
    <article className={`metric-card metric-${tone}`}>
      <p>{label}</p>
      <strong>{value}</strong>
      {unit && <span>{unit}</span>}
    </article>
  )
}
