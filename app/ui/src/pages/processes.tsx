import { useMemo, useState } from 'react'
import { ArrowDown, Play, Rocket, Search } from 'lucide-react'
import { cn } from 'cn'
import { PageHeader } from '@/components/layout/PageHeader'
import { MachinePanel } from '@/components/machine-panel'
import { Button } from '@/components/ui/button'
import { Input } from '@/components/ui/input'
import { Skeleton } from '@/components/ui/skeleton'
import { useMachine } from '@/hooks/use-machine'
import { useNow } from '@/hooks/use-now'
import { useVisibleRows } from '@/hooks/use-visible-rows'
import { formatAgo, formatBytes } from '@/lib/format'
import type { ProcessInfo } from '@/lib/types'

type SortKey = 'cpuPercent' | 'memoryBytes' | 'name' | 'pid'

const rowHeight = 40

export function ProcessesPage() {
  const { machine, error, loading } = useMachine()
  const now = useNow(5000)
  const [query, setQuery] = useState('')
  const [sort, setSort] = useState<SortKey>('cpuPercent')

  const rows = useMemo(() => {
    const q = query.trim().toLowerCase()
    const list = (machine?.processes ?? []).filter(
      (p) => !q || p.name.toLowerCase().includes(q) || p.command.toLowerCase().includes(q) || String(p.pid).includes(q),
    )
    const dir = sort === 'name' || sort === 'pid' ? 1 : -1
    return [...list].sort((a, b) => (a[sort] < b[sort] ? -dir : a[sort] > b[sort] ? dir : 0))
  }, [machine, query, sort])

  const [scroller, visible] = useVisibleRows(rows.length, rowHeight)

  const header = (key: SortKey, label: string, align: 'left' | 'right' = 'right') => (
    <button
      type="button"
      onClick={() => setSort(key)}
      className={cn(
        'inline-flex w-full items-center gap-1 hover:text-foreground',
        align === 'right' ? 'justify-end' : 'justify-start',
        sort === key && 'text-foreground',
      )}
    >
      {label}
      {sort === key && <ArrowDown className="size-3" />}
    </button>
  )

  return (
    <>
      <PageHeader
        title="Processes"
        description="Pick a running process to profile, or launch a program under nusku."
        actions={
          <>
            <div className="relative w-64">
              <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
              <Input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Filter by name, command or pid"
                className="h-8 pl-8 text-xs"
              />
            </div>
            <Button>
              <Rocket /> Launch program
            </Button>
          </>
        }
      />

      {machine && <MachinePanel machine={machine} />}
      {error && <p className="border-b px-6 py-2 text-sm text-destructive">Cannot reach the backend: {error.message}</p>}

      <div ref={scroller} className="min-h-0 flex-1 overflow-auto">
        <table className="w-full table-fixed border-collapse text-sm">
          <thead className="sticky top-0 z-10 bg-background text-xs text-muted-foreground">
            <tr className="border-b">
              <th className="w-56 px-6 py-2 text-left font-medium">{header('name', 'Process', 'left')}</th>
              <th className="w-20 px-3 py-2 font-medium">{header('pid', 'PID')}</th>
              <th className="px-3 py-2 text-left font-medium">Command</th>
              <th className="w-24 px-3 py-2 text-left font-medium">User</th>
              <th className="w-32 px-3 py-2 font-medium">{header('cpuPercent', 'CPU')}</th>
              <th className="w-24 px-3 py-2 font-medium">{header('memoryBytes', 'Memory')}</th>
              <th className="w-24 px-3 py-2 text-right font-medium">Started</th>
              <th className="w-32 px-6 py-2" />
            </tr>
          </thead>
          <tbody>
            {loading &&
              Array.from({ length: 8 }, (_, i) => (
                <tr key={i} className="border-b">
                  <td colSpan={8} className="px-6 py-2.5">
                    <Skeleton className="h-4" />
                  </td>
                </tr>
              ))}
            {visible.before > 0 && <tr style={{ height: visible.before }} />}
            {rows.slice(visible.start, visible.end).map((p) => (
              <ProcessRow key={p.pid} process={p} now={now} />
            ))}
            {visible.after > 0 && <tr style={{ height: visible.after }} />}
          </tbody>
        </table>
        {machine && rows.length === 0 && (
          <p className="p-10 text-center text-sm text-muted-foreground">No process matches “{query}”.</p>
        )}
      </div>
    </>
  )
}

function ProcessRow({ process: p, now }: { process: ProcessInfo; now: number }) {
  const share = Math.min(1, p.cpuPercent / 400)
  return (
    <tr className="group border-b border-border/60 hover:bg-muted/50" style={{ height: rowHeight }}>
      <td className="truncate px-6">
        <span className="font-medium">{p.name}</span>
        <span className="ml-1.5 text-xs text-muted-foreground">{p.threads === 1 ? '1 thread' : `${p.threads} threads`}</span>
      </td>
      <td className="px-3 text-right text-muted-foreground tabular-nums">{p.pid}</td>
      <td className="truncate px-3 font-mono text-xs text-muted-foreground" title={p.command}>
        {p.command}
      </td>
      <td className="truncate px-3 text-xs text-muted-foreground">{p.user}</td>
      <td className="px-3">
        <div className="flex items-center justify-end gap-2">
          <span className="h-1 w-12 bg-muted">
            <span className="block h-full bg-primary" style={{ width: `${share * 100}%` }} />
          </span>
          <span className="w-12 text-right text-xs tabular-nums">{p.cpuPercent.toFixed(1)}%</span>
        </div>
      </td>
      <td className="px-3 text-right text-xs tabular-nums">{formatBytes(p.memoryBytes)}</td>
      <td className="px-3 text-right text-xs text-muted-foreground">{formatAgo(p.startedAt, now)}</td>
      <td className="px-6 text-right">
        <button
          type="button"
          className="inline-flex h-7 items-center gap-1 rounded-md border bg-background px-2 text-xs font-medium opacity-70 hover:bg-muted group-hover:opacity-100"
        >
          <Play className="size-3.5" /> Profile
        </button>
      </td>
    </tr>
  )
}
