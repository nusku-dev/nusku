import type { MachineCpu } from './backend'

export const cpuParts = [
  { key: 'user_percent', label: 'User', color: 'var(--chart-1)' },
  { key: 'system_percent', label: 'System', color: 'var(--chart-2)' },
  { key: 'iowait_percent', label: 'I/O wait', color: 'var(--chart-3)' },
  { key: 'irq_percent', label: 'Interrupts', color: 'var(--chart-4)' },
  { key: 'steal_percent', label: 'Steal', color: 'var(--chart-5)' },
] as const satisfies readonly { key: keyof MachineCpu; label: string; color: string }[]

export function idlePercent(cpu: MachineCpu): number {
  return Math.max(0, 100 - cpu.busy_percent - cpu.iowait_percent)
}
