type Arg = string | number | boolean | Uint8Array

interface WebUI {
  call(fn: string, ...args: Arg[]): Promise<string>
  isConnected(): boolean
  setEventCallback(callback: (event: number) => void): void
  event: { CONNECTED: number; DISCONNECTED: number }
}

declare global {
  var webui: WebUI | undefined
}

export interface ProcessInfoWire {
  pid: number
  name: string
  user: string
  command: string
  threads: number
  cpu_percent: number | null
  memory_bytes: number
  started_unix_ns: number
}

export interface MachineCpu {
  busy_percent: number
  user_percent: number
  system_percent: number
  iowait_percent: number
  irq_percent: number
  steal_percent: number
}

export interface ProcessFrame {
  unix_ns: number
  interval_ns: number
  processes: ProcessInfoWire[]
  machine: { cpus: number; cpu: MachineCpu | null }
}

const listeners = new Set<(connected: boolean) => void>()
let connected = false
let listening = false

function bridge(): WebUI | undefined {
  const ui = globalThis.webui
  if (ui && !listening) {
    listening = true
    connected = ui.isConnected()
    ui.setEventCallback((event) => {
      connected = event === ui.event.CONNECTED
      for (const listener of listeners) listener(connected)
    })
  }
  return ui
}

export function onConnection(listener: (connected: boolean) => void): () => void {
  bridge()
  listeners.add(listener)
  listener(connected)
  return () => listeners.delete(listener)
}

function whenConnected(): Promise<WebUI> {
  const ui = bridge()
  if (!ui) return Promise.reject(new Error('The backend is not running'))
  if (connected) return Promise.resolve(ui)
  return new Promise((resolve) => {
    const listener = (now: boolean) => {
      if (!now) return
      listeners.delete(listener)
      resolve(ui)
    }
    listeners.add(listener)
  })
}

async function call<T>(fn: string, ...args: Arg[]): Promise<T> {
  const ui = await whenConnected()
  const answer: unknown = JSON.parse(await ui.call(fn, ...args))
  if (answer && typeof answer === 'object' && 'error' in answer) throw new Error(String(answer.error))
  return answer as T
}

export const backend = {
  processes: () => call<ProcessFrame>('get_processes'),
}
