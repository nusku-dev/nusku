import { formatPercent } from '@/lib/format'

/** A percent with a bar under it, for table cells. */
export function ShareBar({ value, total, tone = 'primary' }: { value: number; total: number; tone?: 'primary' | 'muted' }) {
  const share = total > 0 ? Math.min(1, value / total) : 0
  return (
    <div className="flex w-full flex-col gap-1">
      <span className="text-right text-xs tabular-nums">{formatPercent(value, total)}</span>
      <span className="h-1 w-full bg-muted">
        <span
          className={tone === 'primary' ? 'block h-full bg-primary' : 'block h-full bg-muted-foreground/50'}
          style={{ width: `${share * 100}%` }}
        />
      </span>
    </div>
  )
}
