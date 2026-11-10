import type { ReactNode } from 'react'
import { CpuChart } from '@/components/cpu-chart'
import { cpuParts as parts, idlePercent } from '@/lib/cpu'
import { formatBytes } from '@/lib/format'
import type { Machine } from '@/lib/types'

export function MachinePanel({ machine }: { machine: Machine }) {
  const cpu = machine.cpu
  return (
    <section className="shrink-0 border-b px-6 py-4">
      <div className="mb-4 flex flex-wrap gap-x-10 gap-y-3">
        <Stat label="CPU busy" value={cpu ? `${cpu.busy_percent.toFixed(1)}%` : '–'} hint={`of ${machine.cpus} CPUs`} />
        <Stat label="CPUs" value={machine.cpus} />
        <Stat label="Processes" value={machine.processes.length} />
        <Stat label="Threads" value={machine.threads} />
        <Stat label="Memory in use" value={formatBytes(machine.memoryBytes)} hint="resident, all processes" />
      </div>
      <div className="flex gap-6">
        <div className="min-w-0 flex-1">
          <CpuChart history={machine.history} />
        </div>
        <ul className="w-40 shrink-0 space-y-1.5 pt-1 text-xs">
          {[...parts].reverse().map((part) => (
            <li key={part.key} className="flex items-center gap-2">
              <span className="size-2.5 rounded-sm" style={{ background: part.color }} />
              <span className="flex-1 text-muted-foreground">{part.label}</span>
              <span className="font-medium tabular-nums">{cpu ? `${cpu[part.key].toFixed(1)}%` : '–'}</span>
            </li>
          ))}
          <li className="flex items-center gap-2 border-t pt-1.5">
            <span className="size-2.5" />
            <span className="flex-1 text-muted-foreground">Idle</span>
            <span className="font-medium tabular-nums">
              {cpu ? `${idlePercent(cpu).toFixed(1)}%` : '–'}
            </span>
          </li>
        </ul>
      </div>
    </section>
  )
}

function Stat({ label, value, hint }: { label: string; value: ReactNode; hint?: string }) {
  return (
    <div>
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="text-2xl font-semibold tracking-tight tabular-nums">{value}</div>
      {hint && <div className="text-xs text-muted-foreground">{hint}</div>}
    </div>
  )
}
