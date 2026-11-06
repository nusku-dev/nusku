// Every metric nusku collects, in one place. The rest of the UI reads this list: the start
// dialog's choices, a session's tabs, which views a metric gets and how its numbers read.
//
// Adding a metric: set its `status` to 'ready', pick the views that fit its stacks, and make the
// data source return its profile. A metric that needs a view of its own (say, live allocations
// for mem) adds that view to features/profile/views.tsx and names it here.

import type { LucideIcon } from 'lucide-react'
import { Cpu, HardDrive, Hourglass, Lock, MemoryStick, Network, Timer } from 'lucide-react'
import { formatBytes, formatCompact, formatDuration, formatInt } from '@/lib/format'
import type { MetricId, Profile } from '@/lib/profile/types'

export type ViewId = 'flame' | 'top' | 'tree'

/** What a stack's value counts. */
export type Unit = 'samples' | 'nanoseconds' | 'bytes' | 'count'

export interface MetricDef {
  id: MetricId
  label: string
  /** One line, for the start dialog and empty states. */
  description: string
  icon: LucideIcon
  status: 'ready' | 'planned'
  unit: Unit
  /** The views it gets, the first one shown by default. */
  views: ViewId[]
  /** What "self" and "total" mean for it, for column headers and tooltips. */
  selfLabel: string
  totalLabel: string
}

const stackViews: ViewId[] = ['flame', 'top', 'tree']

export const metrics: MetricDef[] = [
  {
    id: 'cpu',
    label: 'CPU',
    description: 'What is running on the CPU, sampled 99 times a second.',
    icon: Cpu,
    status: 'ready',
    unit: 'samples',
    views: stackViews,
    selfLabel: 'Self',
    totalLabel: 'Total',
  },
  {
    id: 'offcpu',
    label: 'Off-CPU',
    description: 'Where threads wait instead of run: locks, disk, network, sleep.',
    icon: Hourglass,
    status: 'planned',
    unit: 'nanoseconds',
    views: stackViews,
    selfLabel: 'Blocked',
    totalLabel: 'Total',
  },
  {
    id: 'mem',
    label: 'Memory',
    description: 'What allocates memory, how much, and what of it stays live.',
    icon: MemoryStick,
    status: 'planned',
    unit: 'bytes',
    views: stackViews,
    selfLabel: 'Allocated',
    totalLabel: 'Total',
  },
  {
    id: 'io',
    label: 'Disk I/O',
    description: 'Reads and writes to disk, and the code that asked for them.',
    icon: HardDrive,
    status: 'planned',
    unit: 'bytes',
    views: stackViews,
    selfLabel: 'Bytes',
    totalLabel: 'Total',
  },
  {
    id: 'net',
    label: 'Network',
    description: 'Traffic, latency and retransmits, per call site.',
    icon: Network,
    status: 'planned',
    unit: 'bytes',
    views: stackViews,
    selfLabel: 'Bytes',
    totalLabel: 'Total',
  },
  {
    id: 'locks',
    label: 'Locks',
    description: 'Time spent waiting for a lock, and who held it.',
    icon: Lock,
    status: 'planned',
    unit: 'nanoseconds',
    views: stackViews,
    selfLabel: 'Waited',
    totalLabel: 'Total',
  },
  {
    id: 'sched',
    label: 'Scheduler',
    description: 'Run-queue delay: ready to run, but waiting for a CPU.',
    icon: Timer,
    status: 'planned',
    unit: 'nanoseconds',
    views: stackViews,
    selfLabel: 'Delay',
    totalLabel: 'Total',
  },
]

const byId = new Map(metrics.map((m) => [m.id, m]))

export function metric(id: MetricId): MetricDef {
  const def = byId.get(id)
  if (!def) throw new Error(`unknown metric ${id}`)
  return def
}

export const readyMetrics = metrics.filter((m) => m.status === 'ready')

/** A value in the metric's own unit, in full: "1,234 samples · 12.5 s". */
export function formatValue(def: MetricDef, value: number, profile: Pick<Profile, 'sampleHz'>): string {
  switch (def.unit) {
    case 'samples': {
      const time = profile.sampleHz > 0 ? ` · ${formatDuration((value / profile.sampleHz) * 1000)}` : ''
      return `${formatInt(value)} ${value === 1 ? 'sample' : 'samples'}${time}`
    }
    case 'nanoseconds':
      return formatDuration(value / 1e6)
    case 'bytes':
      return formatBytes(value)
    case 'count':
      return formatInt(value)
  }
}

/** A value, short, for a table cell or an axis. */
export function formatShort(def: MetricDef, value: number, profile: Pick<Profile, 'sampleHz'>): string {
  switch (def.unit) {
    case 'samples':
      return profile.sampleHz > 0 ? formatDuration((value / profile.sampleHz) * 1000) : formatCompact(value)
    case 'nanoseconds':
      return formatDuration(value / 1e6)
    case 'bytes':
      return formatBytes(value)
    case 'count':
      return formatCompact(value)
  }
}
