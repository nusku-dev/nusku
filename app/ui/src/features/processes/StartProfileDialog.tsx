import { useState } from 'react'
import { Check, Play } from 'lucide-react'
import { toast } from 'sonner'
import { cn } from 'cn'
import { Badge } from '@/components/ui/badge'
import { Button } from '@/components/ui/button'
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from '@/components/ui/dialog'
import { Input } from '@/components/ui/input'
import { Label } from '@/components/ui/label'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { useDataSource } from '@/data/hooks'
import type { MetricId, ProcessInfo, StartRequest, Target } from '@/lib/profile/types'
import { navigate, paths } from '@/lib/router'
import { metrics } from '@/metrics/registry'

const intervals = [
  { value: '250', label: 'Every 250 ms' },
  { value: '500', label: 'Every 500 ms' },
  { value: '1000', label: 'Every second' },
  { value: '2000', label: 'Every 2 seconds' },
]

const durations = [
  { value: '0', label: 'Until I stop it' },
  { value: '10', label: '10 seconds' },
  { value: '30', label: '30 seconds' },
  { value: '60', label: '1 minute' },
  { value: '300', label: '5 minutes' },
]

/** What the start dialog opens with: a process to attach to, or a program to launch. */
export type StartPreset = { kind: 'pid'; process: ProcessInfo } | { kind: 'exec' }

/** The `nusku prof` flags, as a form. */
export function StartProfileDialog({
  preset,
  onClose,
}: {
  preset: StartPreset | null
  onClose: () => void
}) {
  return (
    <Dialog open={preset !== null} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="gap-5 sm:max-w-xl">
        {/* Keyed, so every opening starts from a fresh form. */}
        {preset && <StartForm key={preset.kind === 'pid' ? preset.process.pid : 'exec'} preset={preset} onClose={onClose} />}
      </DialogContent>
    </Dialog>
  )
}

function StartForm({ preset, onClose }: { preset: StartPreset; onClose: () => void }) {
  const source = useDataSource()
  const [path, setPath] = useState('')
  const [args, setArgs] = useState('')
  const [chosen, setChosen] = useState<MetricId[]>(['cpu'])
  const [interval, setIntervalMs] = useState('1000')
  const [duration, setDuration] = useState('0')
  const [starting, setStarting] = useState(false)

  const target: Target | null =
    preset.kind === 'pid'
      ? { kind: 'pid', pid: preset.process.pid }
      : path.trim()
        ? { kind: 'exec', path: path.trim(), args: args.trim() ? args.trim().split(/\s+/) : [] }
        : null
  const valid = target !== null && chosen.length > 0

  const toggle = (id: MetricId) =>
    setChosen((prev) => (prev.includes(id) ? prev.filter((m) => m !== id) : [...prev, id]))

  const start = async () => {
    if (!target || !valid) return
    const request: StartRequest = {
      target,
      metrics: chosen,
      intervalMs: Number(interval),
      durationS: Number(duration),
    }
    setStarting(true)
    try {
      const session = await source.startSession(request)
      toast.success(`Profiling ${session.name}`, { description: `pid ${session.pid}` })
      onClose()
      navigate(paths.session(session.id))
    } catch (error) {
      toast.error('Could not start profiling', { description: error instanceof Error ? error.message : String(error) })
      setStarting(false)
    }
  }

  return (
    <>
      <DialogHeader>
        <DialogTitle>{preset.kind === 'pid' ? `Profile ${preset.process.name}` : 'Launch and profile'}</DialogTitle>
        <DialogDescription>
          {preset.kind === 'pid'
            ? 'Attach to the running process. It keeps running when profiling ends.'
            : 'Start a program and profile it from its first instruction. It is stopped when profiling ends.'}
        </DialogDescription>
      </DialogHeader>

      {preset.kind === 'pid' ? (
        <div className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 border bg-muted/40 p-3 text-xs">
          <span className="text-muted-foreground">Process</span>
          <span className="font-medium">
            {preset.process.name} <span className="text-muted-foreground tabular-nums">· pid {preset.process.pid}</span>
          </span>
          <span className="text-muted-foreground">Command</span>
          <span className="truncate font-mono" title={preset.process.command}>
            {preset.process.command}
          </span>
        </div>
      ) : (
        <div className="grid gap-3">
          <div className="grid gap-1.5">
            <Label htmlFor="exec-path">Executable</Label>
            <Input id="exec-path" autoFocus placeholder="/usr/bin/dd" value={path} onChange={(e) => setPath(e.target.value)} className="font-mono" />
          </div>
          <div className="grid gap-1.5">
            <Label htmlFor="exec-args">Arguments</Label>
            <Input id="exec-args" placeholder="if=/dev/zero of=/dev/null bs=1" value={args} onChange={(e) => setArgs(e.target.value)} className="font-mono" />
          </div>
        </div>
      )}

      <div className="grid gap-2">
        <Label>Metrics</Label>
        <div className="grid grid-cols-2 gap-2">
          {metrics.map((m) => {
            const Icon = m.icon
            const ready = m.status === 'ready'
            const on = chosen.includes(m.id)
            return (
              <button
                key={m.id}
                type="button"
                disabled={!ready}
                onClick={() => toggle(m.id)}
                aria-pressed={on}
                className={cn(
                  'flex items-start gap-2.5 border p-2.5 text-left transition-colors',
                  ready ? 'hover:bg-muted/60' : 'cursor-not-allowed opacity-55',
                  on && 'border-primary bg-primary/10 hover:bg-primary/15',
                )}
              >
                <Icon className={cn('mt-0.5 size-4 shrink-0', on ? 'text-primary' : 'text-muted-foreground')} />
                <span className="min-w-0 flex-1">
                  <span className="flex items-center gap-1.5 text-sm font-medium">
                    {m.label}
                    {!ready && (
                      <Badge variant="outline" className="h-4 px-1.5 text-[10px]">
                        Soon
                      </Badge>
                    )}
                  </span>
                  <span className="mt-0.5 line-clamp-2 block text-xs text-muted-foreground">{m.description}</span>
                </span>
                {on && <Check className="size-4 shrink-0 text-primary" />}
              </button>
            )
          })}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="grid gap-1.5">
          <Label>Report</Label>
          <Select value={interval} onValueChange={(v) => v && setIntervalMs(v)} items={intervals}>
            <SelectTrigger className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {intervals.map((o) => (
                <SelectItem key={o.value} value={o.value}>
                  {o.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
        <div className="grid gap-1.5">
          <Label>Duration</Label>
          <Select value={duration} onValueChange={(v) => v && setDuration(v)} items={durations}>
            <SelectTrigger className="w-full">
              <SelectValue />
            </SelectTrigger>
            <SelectContent>
              {durations.map((o) => (
                <SelectItem key={o.value} value={o.value}>
                  {o.label}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      <div className="space-y-1">
        <p className="text-xs text-muted-foreground">Same as</p>
        <pre className="overflow-x-auto border bg-muted/40 px-3 py-2 font-mono text-xs">{cliCommand(target, chosen, interval, duration)}</pre>
      </div>

      <DialogFooter>
        <Button variant="outline" onClick={onClose}>
          Cancel
        </Button>
        <Button onClick={start} disabled={!valid || starting}>
          <Play /> {starting ? 'Starting…' : 'Start profiling'}
        </Button>
      </DialogFooter>
    </>
  )
}

/** The `nusku prof` command that does the same, so the UI teaches the CLI. */
function cliCommand(target: Target | null, chosen: MetricId[], interval: string, duration: string): string {
  const parts = ['sudo nusku prof']
  if (target?.kind === 'pid') parts.push(`-p ${target.pid}`)
  else parts.push(`-e ${target?.kind === 'exec' ? target.path : '<executable>'}`)
  if (chosen.join(',') !== 'cpu') parts.push(`--metrics ${chosen.join(',')}`)
  if (interval !== '1000') parts.push(`--interval ${interval}`)
  if (duration !== '0') parts.push(`--duration ${duration}`)
  if (target?.kind === 'exec' && target.args.length > 0) parts.push(`-- ${target.args.join(' ')}`)
  return parts.join(' ')
}
