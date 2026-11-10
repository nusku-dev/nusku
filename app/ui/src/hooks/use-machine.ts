import { createContext, useContext, useEffect, useState } from 'react'
import { backend, type ProcessFrame, type ProcessInfoWire } from '@/lib/backend'
import type { CpuPoint, Machine, ProcessInfo } from '@/lib/types'

const pauseMs = 1000
export const historyMs = 60_000

interface State {
  machine: Machine | undefined
  error: Error | undefined
}

export interface MachineState extends State {
  loading: boolean
}

export const MachineContext = createContext<MachineState | null>(null)

export function useMachine(): MachineState {
  const state = useContext(MachineContext)
  if (!state) throw new Error('useMachine needs a MachineProvider around the app')
  return state
}

export function useMachinePolling(): MachineState {
  const [state, setState] = useState<State>({ machine: undefined, error: undefined })

  useEffect(() => {
    let alive = true
    let timer: ReturnType<typeof setTimeout> | undefined
    let history: CpuPoint[] = []

    const ask = () => {
      backend
        .processes()
        .then((frame) => {
          if (!alive) return
          history = historyWith(history, frame)
          setState({ machine: machineOf(frame, history), error: undefined })
        })
        .catch((error: unknown) => {
          if (!alive) return
          setState((last) => ({ ...last, error: error instanceof Error ? error : new Error(String(error)) }))
        })
        .finally(() => {
          if (alive) timer = setTimeout(ask, pauseMs)
        })
    }
    ask()

    return () => {
      alive = false
      clearTimeout(timer)
    }
  }, [])

  return { ...state, loading: !state.machine && !state.error }
}

function historyWith(history: CpuPoint[], frame: ProcessFrame): CpuPoint[] {
  const cpu = frame.machine.cpu
  if (!cpu) return history
  const at = Math.round(frame.unix_ns / 1e6)
  return [...history, { at, cpu }].filter((point) => point.at > at - historyMs)
}

function machineOf(frame: ProcessFrame, history: CpuPoint[]): Machine {
  const processes = frame.processes.map(processOf)
  return {
    processes,
    cpus: frame.machine.cpus,
    cpu: frame.machine.cpu,
    history,
    threads: processes.reduce((sum, p) => sum + p.threads, 0),
    memoryBytes: processes.reduce((sum, p) => sum + p.memoryBytes, 0),
  }
}

function processOf(p: ProcessInfoWire): ProcessInfo {
  return {
    pid: p.pid,
    name: p.name,
    command: p.command || `[${p.name}]`,
    user: p.user,
    cpuPercent: p.cpu_percent ?? 0,
    memoryBytes: p.memory_bytes,
    threads: p.threads,
    startedAt: Math.round(p.started_unix_ns / 1e6),
  }
}
