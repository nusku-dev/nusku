import { useMemo, useState } from 'react'
import { ArrowDown } from 'lucide-react'
import { cn } from 'cn'
import { frameName, matches, moduleName } from '@/lib/profile/analyze'
import { formatShort } from '@/metrics/registry'
import type { ViewProps } from './analysis'
import { frameColor, frameKind } from './colors'
import { ShareBar } from './ShareBar'

type SortKey = 'self' | 'total'

/** How many rows to draw at most: past this, the functions are noise. */
const maxRows = 400

/** Every function, by the time it ran itself or with what it called. */
export function TopFunctions({ analysis, metric, search, selected, onSelect }: ViewProps) {
  const [sort, setSort] = useState<SortKey>('self')
  const total = analysis.profile.total

  const rows = useMemo(() => {
    const filtered = search ? analysis.functions.filter((f) => matches(f.frame, search)) : analysis.functions
    return [...filtered].sort((a, b) => b[sort] - a[sort]).slice(0, maxRows)
  }, [analysis.functions, search, sort])

  const header = (key: SortKey, label: string) => (
    <button
      type="button"
      onClick={() => setSort(key)}
      className={cn('inline-flex w-full items-center justify-end gap-1 hover:text-foreground', sort === key && 'text-foreground')}
    >
      {sort === key && <ArrowDown className="size-3" />}
      {label}
    </button>
  )

  return (
    <div className="h-full overflow-auto">
      <table className="w-full table-fixed border-collapse text-sm">
        <thead className="sticky top-0 z-10 bg-background text-xs text-muted-foreground">
          <tr className="border-b">
            <th className="w-12 px-3 py-2 text-right font-medium">#</th>
            <th className="px-3 py-2 text-left font-medium">Function</th>
            <th className="w-32 px-3 py-2 font-medium">{header('self', metric.selfLabel)}</th>
            <th className="w-32 px-3 py-2 font-medium">{header('total', metric.totalLabel)}</th>
            <th className="w-24 px-3 py-2 text-right font-medium">{metric.unit === 'samples' ? 'CPU time' : 'Value'}</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((f, i) => {
            const kind = frameKind(f.frame, analysis.programModule)
            const name = frameName(f.frame)
            return (
              <tr
                key={f.key}
                onClick={() => onSelect(f.key === selected ? null : f.key)}
                className={cn(
                  'cursor-pointer border-b border-border/60 hover:bg-muted/60',
                  f.key === selected && 'bg-muted',
                )}
              >
                <td className="px-3 py-1.5 text-right text-xs text-muted-foreground tabular-nums">{i + 1}</td>
                <td className="px-3 py-1.5">
                  <div className="flex min-w-0 items-center gap-2">
                    <span className="size-2.5 shrink-0" style={{ background: frameColor(kind, name) }} />
                    <span className="truncate font-mono text-[12.5px]" title={name}>
                      {name}
                    </span>
                    <span className="shrink-0 truncate text-xs text-muted-foreground">{moduleName(f.frame)}</span>
                  </div>
                </td>
                <td className="px-3 py-1.5">
                  <ShareBar value={f.self} total={total} />
                </td>
                <td className="px-3 py-1.5">
                  <ShareBar value={f.total} total={total} tone="muted" />
                </td>
                <td className="px-3 py-1.5 text-right text-xs text-muted-foreground tabular-nums">
                  {formatShort(metric, f[sort], analysis.profile)}
                </td>
              </tr>
            )
          })}
        </tbody>
      </table>
      {rows.length === 0 && (
        <p className="p-8 text-center text-sm text-muted-foreground">No function matches “{search}”.</p>
      )}
    </div>
  )
}
