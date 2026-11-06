import { Activity, Plus } from 'lucide-react'
import { PageHeader } from '@/components/layout/PageHeader'
import { SessionStatus } from '@/components/session-status'
import { Button } from '@/components/ui/button'
import { Empty, EmptyContent, EmptyDescription, EmptyHeader, EmptyMedia, EmptyTitle } from '@/components/ui/empty'
import { Skeleton } from '@/components/ui/skeleton'
import { useSessions } from '@/data/hooks'
import { formatAgo, formatClock, formatInt } from '@/lib/format'
import type { Session } from '@/lib/profile/types'
import { href, navigate, paths } from '@/lib/router'
import { metric } from '@/metrics/registry'
import { useNow } from '@/hooks/use-now'

/** Every profiling run, live ones first. */
export function SessionsPage() {
  const sessions = useSessions()
  const now = useNow(5000)
  const list = [...(sessions.data ?? [])].sort(
    (a, b) => Number(b.status === 'running') - Number(a.status === 'running') || b.startedAt - a.startedAt,
  )

  return (
    <>
      <PageHeader
        title="Sessions"
        description="Every profiling run: live ones as they happen, finished ones to look back at."
        actions={
          <Button nativeButton={false} render={<a href={href(paths.processes())} />}>
            <Plus /> New session
          </Button>
        }
      />
      <div className="min-h-0 flex-1 overflow-auto">
        {sessions.loading ? (
          <div className="space-y-3 p-6">
            {Array.from({ length: 4 }, (_, i) => (
              <Skeleton key={i} className="h-12" />
            ))}
          </div>
        ) : list.length === 0 ? (
          <Empty className="h-full">
            <EmptyHeader>
              <EmptyMedia variant="icon">
                <Activity />
              </EmptyMedia>
              <EmptyTitle>No sessions yet</EmptyTitle>
              <EmptyDescription>Pick a process and see where its time goes, live.</EmptyDescription>
            </EmptyHeader>
            <EmptyContent>
              <Button nativeButton={false} render={<a href={href(paths.processes())} />}>
                <Plus /> Profile a process
              </Button>
            </EmptyContent>
          </Empty>
        ) : (
          <table className="w-full table-fixed border-collapse text-sm">
            <thead className="sticky top-0 z-10 bg-background text-xs text-muted-foreground">
              <tr className="border-b">
                <th className="w-40 px-6 py-2 text-left font-medium">Status</th>
                <th className="px-3 py-2 text-left font-medium">Process</th>
                <th className="w-40 px-3 py-2 text-left font-medium">Metrics</th>
                <th className="w-28 px-3 py-2 text-right font-medium">Duration</th>
                <th className="w-28 px-3 py-2 text-right font-medium">Samples</th>
                <th className="w-32 px-6 py-2 text-right font-medium">Started</th>
              </tr>
            </thead>
            <tbody>
              {list.map((s) => (
                <SessionRow key={s.id} session={s} now={now} />
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  )
}

function SessionRow({ session: s, now }: { session: Session; now: number }) {
  const samples = s.windows.reduce((sum, w) => sum + (w.values.cpu ?? 0), 0)
  return (
    <tr onClick={() => navigate(paths.session(s.id))} className="cursor-pointer border-b border-border/60 hover:bg-muted/50">
      <td className="px-6 py-2.5">
        <SessionStatus session={s} />
      </td>
      <td className="px-3 py-2.5">
        <div className="flex min-w-0 items-baseline gap-2">
          <span className="font-medium">{s.name}</span>
          <span className="text-xs text-muted-foreground tabular-nums">pid {s.pid}</span>
          <span className="truncate font-mono text-xs text-muted-foreground" title={s.command}>
            {s.command}
          </span>
        </div>
      </td>
      <td className="px-3 py-2.5">
        <div className="flex items-center gap-1.5">
          {s.metrics.map((id) => {
            const m = metric(id)
            const Icon = m.icon
            return (
              <span key={id} className="inline-flex items-center gap-1 border px-1.5 py-0.5 text-xs" title={m.description}>
                <Icon className="size-3 text-primary" /> {m.label}
              </span>
            )
          })}
        </div>
      </td>
      <td className="px-3 py-2.5 text-right tabular-nums">{formatClock(s.elapsedMs)}</td>
      <td className="px-3 py-2.5 text-right tabular-nums">{formatInt(samples)}</td>
      <td className="px-6 py-2.5 text-right text-xs text-muted-foreground">{formatAgo(s.startedAt, now)}</td>
    </tr>
  )
}
