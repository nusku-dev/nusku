import type { MachineCpu } from './backend'

export interface ProcessInfo {
  pid: number
  name: string
  command: string
  user: string
  cpuPercent: number
  memoryBytes: number
  threads: number
  startedAt: number
}

export interface CpuPoint {
  at: number
  cpu: MachineCpu
}

export interface Machine {
  processes: ProcessInfo[]
  cpus: number
  cpu: MachineCpu | null
  history: CpuPoint[]
  threads: number
  memoryBytes: number
}
