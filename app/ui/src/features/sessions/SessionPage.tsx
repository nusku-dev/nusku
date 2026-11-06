import { useState } from 'react'
import { ArrowLeft, Download, Ellipsis, Square, Trash2, TriangleAlert } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from 'cn'
import { SessionStatus } from '@/components/session-status'
import { Button } from '@/components/ui/button'
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from '@/components/ui/dropdown-menu'
import { Skeleton } from '@/components/ui/skeleton'
import { useDataSource, useSession } from '@/data/hooks'
import { folded } from '@/lib/profile/analyze'
import { formatClock, formatInt, formatPercent } from '@/lib/format'
import type { MetricId, Session } from '@/lib/profile/types'
import { href, navigate, paths } from '@/lib/router'
import { metric as metricDef, metrics } from '@/metrics/registry'
import { ProfileWorkspace } from '@/features/profile/ProfileWorkspace'

export function SessionPage({ id }: { id: string }) {
  const session = useSession(id)

  if (session.loading) {
    return (
      <div className="space-y-4 p-6">
        <Skeleton className="h-8 w-72" />
        <Skeleton className="h-16" />
        <Skeleton className="h-96" />
      </div>
    )
  }
  if (!session.data) {
    return (
      <div className="grid h-full place-items-center text-center">
        <div>
          <p className="font-medium">This session is gone</p>
          <p className="mt-1 text-sm text-muted-foreground">It may have been deleted.</p>
          <Button className="mt-4" variant="outline" nativeButton={false} render={<a href={href(paths.sessions())} />}>
            <ArrowLeft /> All sessions
          </Button>
        </div>
      </div>
    )
  }
  // Keyed, so moving to another session starts with fresh view state.
  return <SessionView key={id} session={session.data} />
}

function SessionView({ session }: { session: Session }) {
  const [active, setActive] = useState<MetricId>(session.metrics[0] ?? 'cpu')
  const def = metricDef(active)

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <SessionHeader session={session} />
      <SessionStats session={session} />

      <div className="flex h-10 shrink-0 items-stretch gap-1 border-b px-4" role="tablist" aria-label="Metric">
        {metrics.map((m) => {
          const collected = session.metrics.includes(m.id)
          const Icon = m.icon
          const reason = m.status === 'planned' ? 'Coming soon' : collected ? m.description : 'Not collected in this session'
          return (
            <button
              key={m.id}
              type="button"
              role="tab"
              aria-selected={active === m.id}
              disabled={!collected}
              title={reason}
              onClick={() => setActive(m.id)}
              className={cn(
                'relative inline-flex items-center gap-1.5 px-3 text-sm text-muted-foreground transition-colors',
                collected ? 'hover:text-foreground' : 'cursor-not-allowed opacity-45',
                active === m.id && 'font-medium text-foreground',
              )}
            >
              <Icon className={cn('size-4', active === m.id && 'text-primary')} />
              {m.label}
              {active === m.id && <span className="absolute inset-x-2 -bottom-px h-0.5 bg-primary" />}
            </button>
          )
        })}
      </div>

      <ProfileWorkspace key={active} session={session} metric={def} />
    </div>
  )
}

function SessionHeader({ session }: { session: Session }) {
  const source = useDataSource()
  const running = session.status === 'running'

  const exportFolded = async () => {
    const profile = await source.getProfile(session.id, 'cpu', null)
    const blob = new Blob([folded(profile) + '\n'], { type: 'text/plain' })
    const link = document.createElement('a')
    link.href = URL.createObjectURL(blob)
    link.download = `${session.name}-${session.pid}.folded`
    link.click()
    URL.revokeObjectURL(link.href)
    toast.success('Stacks exported', { description: 'In the folded format: open them in speedscope or FlameGraph.' })
  }

  return (
    <header className="flex h-14 shrink-0 items-center gap-3 border-b px-4">
      <Button variant="ghost" size="icon-sm" nativeButton={false} render={<a href={href(paths.sessions())} aria-label="All sessions" />}>
        <ArrowLeft />
      </Button>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2.5">
          <h1 className="truncate text-base font-semibold tracking-tight">{session.name}</h1>
          <span className="text-sm text-muted-foreground tabular-nums">pid {session.pid}</span>
          <SessionStatus session={session} />
        </div>
        <p className="truncate font-mono text-xs text-muted-foreground" title={session.command}>
          {session.command}
        </p>
      </div>
      {running && (
        <Button variant="destructive" onClick={() => void source.stopSession(session.id)}>
          <Square className="fill-current" /> Stop
        </Button>
      )}
      <Button variant="outline" onClick={() => void exportFolded()}>
        <Download /> Export
      </Button>
      <DropdownMenu>
        <DropdownMenuTrigger render={<Button variant="ghost" size="icon" aria-label="More" />}>
          <Ellipsis />
        </DropdownMenuTrigger>
        <DropdownMenuContent align="end" className="w-48">
          <DropdownMenuItem
            onClick={() => {
              void navigator.clipboard?.writeText(String(session.pid))
              toast.success('PID copied')
            }}
          >
            Copy PID
          </DropdownMenuItem>
          <DropdownMenuSeparator />
          <DropdownMenuItem
            variant="destructive"
            disabled={running}
            onClick={() => {
              void source.deleteSession(session.id)
              navigate(paths.sessions())
              toast('Session deleted')
            }}
          >
            <Trash2 /> Delete session
          </DropdownMenuItem>
        </DropdownMenuContent>
      </DropdownMenu>
    </header>
  )
}

function SessionStats({ session }: { session: Session }) {
  const samples = session.windows.reduce((sum, w) => sum + (w.values.cpu ?? 0), 0)
  const lostShare = samples + session.lost > 0 ? session.lost / (samples + session.lost) : 0
  const stats = [
    { label: 'Elapsed', value: formatClock(session.elapsedMs) },
    { label: 'Samples', value: formatInt(samples) },
    { label: 'Sample rate', value: `${session.sampleHz} Hz` },
    { label: 'Reports', value: `${formatInt(session.windows.length)} × ${session.intervalMs >= 1000 ? `${session.intervalMs / 1000} s` : `${session.intervalMs} ms`}` },
    { label: 'Duration', value: session.durationS > 0 ? `${session.durationS} s` : 'Until stopped' },
  ]
  return (
    <div className="flex shrink-0 items-center gap-8 border-b px-6 py-2.5">
      {stats.map((s) => (
        <div key={s.label}>
          <div className="text-[11px] tracking-wide text-muted-foreground uppercase">{s.label}</div>
          <div className="text-sm font-medium tabular-nums">{s.value}</div>
        </div>
      ))}
      {session.lost > 0 && (
        <div
          className="ml-auto flex items-center gap-2 border border-amber-500/40 bg-amber-500/10 px-2.5 py-1 text-xs text-amber-700 dark:text-amber-300"
          title="The kernel dropped these samples: the profile is missing them."
        >
          <TriangleAlert className="size-3.5" />
          {formatInt(session.lost)} samples lost ({formatPercent(session.lost, samples + session.lost)})
        </div>
      )}
      {lostShare === 0 && <div className="flex-1" />}
    </div>
  )
}
