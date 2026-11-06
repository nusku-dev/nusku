import { useEffect, useRef, useState } from 'react'
import { Search, X } from 'lucide-react'
import { cn } from 'cn'
import { Input } from '@/components/ui/input'
import { Kbd } from '@/components/ui/kbd'
import { Skeleton } from '@/components/ui/skeleton'
import { useProfile } from '@/data/hooks'
import type { Session, WindowRange } from '@/lib/profile/types'
import { formatShort, type MetricDef, type ViewId } from '@/metrics/registry'
import { useAnalysis } from './analysis'
import { FunctionDetails } from './FunctionDetails'
import { Timeline } from './Timeline'
import { views } from './views'

/** One metric of one session: its timeline, its views, and the selected function. */
export function ProfileWorkspace({ session, metric }: { session: Session; metric: MetricDef }) {
  const [view, setView] = useState<ViewId>(metric.views[0])
  const [range, setRange] = useState<WindowRange | null>(null)
  const [search, setSearch] = useState('')
  const [selected, setSelected] = useState<string | null>(null)
  const searchRef = useRef<HTMLInputElement>(null)

  const profile = useProfile(session.id, metric.id, range)
  const analysis = useAnalysis(profile.data)

  // "/" jumps to the search, Escape clears it and then the selection.
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const typing = event.target instanceof HTMLInputElement
      if (event.key === '/' && !typing) {
        event.preventDefault()
        searchRef.current?.focus()
      } else if (event.key === 'Escape') {
        if (typing) (event.target as HTMLInputElement).blur()
        else setSelected(null)
      }
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  const View = views[view].component
  const formatWindow = (value: number) => formatShort(metric, value, session)

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="border-b px-6 py-3">
        <Timeline
          windows={session.windows}
          metric={metric.id}
          range={range}
          onRangeChange={setRange}
          format={formatWindow}
        />
      </div>

      <div className="flex h-11 items-center gap-3 border-b px-6">
        <div className="flex items-center gap-0.5 border p-0.5" role="tablist" aria-label="View">
          {metric.views.map((id) => {
            const def = views[id]
            const Icon = def.icon
            return (
              <button
                key={id}
                type="button"
                role="tab"
                aria-selected={view === id}
                title={def.hint}
                onClick={() => setView(id)}
                className={cn(
                  'inline-flex h-7 items-center gap-1.5 px-2.5 text-xs font-medium text-muted-foreground transition-colors hover:text-foreground',
                  view === id && 'bg-muted text-foreground',
                )}
              >
                <Icon className="size-3.5" />
                {def.label}
              </button>
            )
          })}
        </div>
        <div className="flex-1" />
        <div className="relative w-72">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            ref={searchRef}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search functions or modules"
            className="h-8 pr-8 pl-8 text-xs"
          />
          {search ? (
            <button
              type="button"
              aria-label="Clear search"
              onClick={() => setSearch('')}
              className="absolute top-1/2 right-2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            >
              <X className="size-3.5" />
            </button>
          ) : (
            <Kbd className="absolute top-1/2 right-2 -translate-y-1/2">/</Kbd>
          )}
        </div>
      </div>

      <div className="flex min-h-0 flex-1">
        <div className="min-w-0 flex-1">
          {profile.error ? (
            <Message title="Could not load the profile" text={profile.error.message} />
          ) : !analysis ? (
            <div className="space-y-2 p-6">
              {Array.from({ length: 8 }, (_, i) => (
                <Skeleton key={i} className="h-5" style={{ width: `${100 - i * 9}%` }} />
              ))}
            </div>
          ) : analysis.profile.total === 0 ? (
            <Message
              title={session.status === 'running' ? 'Collecting samples…' : 'No samples'}
              text={
                session.status === 'running'
                  ? 'The first stacks show up after the first report.'
                  : 'The process did not run on the CPU while it was profiled.'
              }
            />
          ) : (
            <View analysis={analysis} metric={metric} search={search} selected={selected} onSelect={setSelected} />
          )}
        </div>
        {selected && analysis && (
          <FunctionDetails analysis={analysis} metric={metric} functionKey={selected} onSelect={setSelected} />
        )}
      </div>
    </div>
  )
}

function Message({ title, text }: { title: string; text: string }) {
  return (
    <div className="grid h-full place-items-center p-10 text-center">
      <div>
        <p className="font-medium">{title}</p>
        <p className="mt-1 text-sm text-muted-foreground">{text}</p>
      </div>
    </div>
  )
}
