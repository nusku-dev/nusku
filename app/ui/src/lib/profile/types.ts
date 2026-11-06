// The data the UI shows. These mirror what the nusku server returns (server/query.zig) so that
// swapping the sample data for the real backend only changes the data source, not the UI.

/** Every metric nusku knows about. Which ones are ready is in metrics/registry.ts. */
export type MetricId = 'cpu' | 'offcpu' | 'mem' | 'io' | 'net' | 'locks' | 'sched'

/** Why a run ended (agent/profile.zig). */
export type StopReason = 'duration' | 'target_exited' | 'cancelled'

/** One frame of a stack (server `Frame`). */
export interface Frame {
  /** The raw address, as the agent reported it, in hex without `0x`. */
  address: string
  kernel: boolean
  /** Null when the address could not be named: the UI shows the raw address. */
  function: string | null
  file: string | null
  line: number | null
  /** The binary or library the address is in. */
  module: string | null
}

/** One distinct stack and how much of the metric it accounts for (server `SymbolStack`). */
export interface Stack {
  /** Samples for cpu; later nanoseconds for offcpu, bytes for mem, and so on. */
  value: number
  /** Innermost frame first, kernel frames before user frames. */
  frames: Frame[]
  /** False when the unwinder could not reach the outermost frame. */
  complete: boolean
}

/** The stacks of one metric over a span of a session (server `Profile`). */
export interface Profile {
  metric: MetricId
  sampleHz: number
  /** Sum of every stack's value. */
  total: number
  /** Samples the kernel dropped: the profile is missing them. */
  lost: number
  stacks: Stack[]
}

/** A process that can be profiled. */
export interface ProcessInfo {
  pid: number
  name: string
  command: string
  user: string
  cpuPercent: number
  memoryBytes: number
  threads: number
  /** Unix milliseconds. */
  startedAt: number
}

export type Target = { kind: 'pid'; pid: number } | { kind: 'exec'; path: string; args: string[] }

/** What the `nusku prof` flags say, as a request. */
export interface StartRequest {
  target: Target
  metrics: MetricId[]
  intervalMs: number
  /** 0: until stopped or the process exits. */
  durationS: number
}

/** One report window: what the agent sent every `intervalMs`. */
export interface Window {
  /** Milliseconds since the session started. */
  startMs: number
  durationMs: number
  /** The window's total per collected metric (samples for cpu). */
  values: Partial<Record<MetricId, number>>
}

export type SessionStatus = 'running' | 'stopped'

/** One profiling run of one process. */
export interface Session {
  id: string
  pid: number
  name: string
  command: string
  metrics: MetricId[]
  intervalMs: number
  durationS: number
  /** Unix milliseconds. */
  startedAt: number
  elapsedMs: number
  status: SessionStatus
  /** Null while running. */
  reason: StopReason | null
  sampleHz: number
  lost: number
  windows: Window[]
}

/** A span of a session, in window indices, both ends included. */
export interface WindowRange {
  from: number
  to: number
}
