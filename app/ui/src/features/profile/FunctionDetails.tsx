import type { ReactNode } from 'react'
import { useMemo } from 'react'
import { Copy, X } from 'lucide-react'
import { toast } from 'sonner'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import { frameName, moduleName, neighbours, type Neighbour } from '@/lib/profile/analyze'
import { formatPercent } from '@/lib/format'
import { formatValue, type MetricDef } from '@/metrics/registry'
import type { Analysis } from './analysis'
import { frameColor, frameKind, kindLabels } from './colors'

/** Everything about one function: where it is, its share, who calls it and what it calls. */
export function FunctionDetails({
  analysis,
  metric,
  functionKey,
  onSelect,
}: {
  analysis: Analysis
  metric: MetricDef
  functionKey: string
  onSelect: (key: string | null) => void
}) {
  const stat = analysis.byKey.get(functionKey)
  const { callers, callees } = useMemo(
    () => neighbours(analysis.profile, functionKey),
    [analysis.profile, functionKey],
  )
  const total = analysis.profile.total

  if (!stat) {
    return (
      <Panel onClose={() => onSelect(null)} title="Function">
        <p className="p-4 text-sm text-muted-foreground">Not in this part of the profile.</p>
      </Panel>
    )
  }

  const { frame } = stat
  const name = frameName(frame)
  const kind = frameKind(frame, analysis.programModule)
  const source = frame.file ? `${frame.file}${frame.line ? `:${frame.line}` : ''}` : null

  return (
    <Panel onClose={() => onSelect(null)} title="Function">
      <div className="space-y-4 p-4">
        <div className="space-y-2">
          <div className="flex items-start gap-2">
            <span className="mt-1 size-2.5 shrink-0" style={{ background: frameColor(kind, name) }} />
            <h3 className="font-mono text-sm font-medium break-all">{name}</h3>
          </div>
          <div className="flex flex-wrap gap-1.5">
            <Badge variant="secondary">{kindLabels[kind]}</Badge>
            <Badge variant="outline" title={frame.module ?? undefined}>
              {moduleName(frame)}
            </Badge>
          </div>
          <dl className="space-y-1 text-xs">
            {source && <Field label="Source" value={source} />}
            <Field label="Address" value={`0x${frame.address}`} />
            {frame.module && <Field label="Module" value={frame.module} />}
          </dl>
          <Button
            variant="outline"
            size="xs"
            onClick={() => {
              void navigator.clipboard?.writeText(name)
              toast.success('Function name copied')
            }}
          >
            <Copy /> Copy name
          </Button>
        </div>

        <div className="grid grid-cols-2 gap-px border bg-border">
          <Stat label={metric.selfLabel} value={formatPercent(stat.self, total)} detail={formatValue(metric, stat.self, analysis.profile)} />
          <Stat label={metric.totalLabel} value={formatPercent(stat.total, total)} detail={formatValue(metric, stat.total, analysis.profile)} />
        </div>

        <Neighbours title="Called by" items={callers} total={stat.total} onSelect={onSelect} empty="Nothing: it is where its stacks start." />
        <Neighbours title="Calls" items={callees} total={stat.total} onSelect={onSelect} empty="Nothing: it does all its work itself." />
      </div>
    </Panel>
  )
}

function Panel({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  return (
    <aside className="flex h-full w-80 shrink-0 flex-col border-l bg-background">
      <div className="flex h-9 items-center justify-between border-b pr-1 pl-4">
        <span className="text-xs font-medium tracking-wide text-muted-foreground uppercase">{title}</span>
        <Button variant="ghost" size="icon-xs" onClick={onClose} aria-label="Close">
          <X />
        </Button>
      </div>
      <div className="min-h-0 flex-1 overflow-auto">{children}</div>
    </aside>
  )
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="grid grid-cols-[4rem_1fr] gap-2">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="font-mono break-all">{value}</dd>
    </div>
  )
}

function Stat({ label, value, detail }: { label: string; value: string; detail: string }) {
  return (
    <div className="bg-background p-3">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="text-xl font-semibold tabular-nums">{value}</div>
      <div className="text-xs text-muted-foreground tabular-nums">{detail}</div>
    </div>
  )
}

function Neighbours({
  title,
  items,
  total,
  onSelect,
  empty,
}: {
  title: string
  items: Neighbour[]
  total: number
  onSelect: (key: string) => void
  empty: string
}) {
  return (
    <section>
      <h4 className="mb-1.5 text-xs font-medium text-muted-foreground">{title}</h4>
      {items.length === 0 ? (
        <p className="text-xs text-muted-foreground">{empty}</p>
      ) : (
        <ul className="space-y-0.5">
          {items.slice(0, 10).map((item) => (
            <li key={item.key}>
              <button
                type="button"
                onClick={() => onSelect(item.key)}
                className="flex w-full items-center gap-2 px-1.5 py-1 text-left hover:bg-muted"
              >
                <span className="min-w-0 flex-1 truncate font-mono text-xs" title={frameName(item.frame)}>
                  {frameName(item.frame)}
                </span>
                <span className="shrink-0 text-xs text-muted-foreground tabular-nums">{formatPercent(item.value, total)}</span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}
