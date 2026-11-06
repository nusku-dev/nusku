// Sample data that behaves like the real thing: sessions start, grow a window every interval,
// stop when their duration ends or when asked, and profiles cover any range of their windows.
// Only cpu is collected, as in nusku today.

import type { DataSource } from '@/data/source'
import type {
  MetricId,
  ProcessInfo,
  Profile,
  Session,
  StartRequest,
  WindowRange,
} from '@/lib/profile/types'
import { programFor, type Program } from './programs'

const sampleHz = 99

/** A small seeded random generator, so the seeded sessions look the same on every start. */
function random(seed: number) {
  let a = seed >>> 0
  return () => {
    a = (a + 0x6d2b79f5) >>> 0
    let t = a
    t = Math.imul(t ^ (t >>> 15), t | 1)
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296
  }
}

interface Run {
  session: Session
  program: Program
  /** Per window, the samples of each of the program's stacks. */
  counts: number[][]
  rand: () => number
}

const processes: Omit<ProcessInfo, 'cpuPercent'>[] = [
  { pid: 4242, name: 'orbit-server', command: '/usr/local/bin/orbit-server --port 7777 --tick 60', user: 'ali', memoryBytes: 412 * 2 ** 20, threads: 9, startedAt: Date.now() - 3 * 3600_000 },
  { pid: 1187, name: 'postgres', command: 'postgres: 16/main: ali app [local] SELECT', user: 'postgres', memoryBytes: 96 * 2 ** 20, threads: 1, startedAt: Date.now() - 26 * 3600_000 },
  { pid: 1102, name: 'postgres', command: '/usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main', user: 'postgres', memoryBytes: 38 * 2 ** 20, threads: 1, startedAt: Date.now() - 26 * 3600_000 },
  { pid: 9811, name: 'python3', command: 'python3 -m worker.ingest --batch 512', user: 'ali', memoryBytes: 1.3 * 2 ** 30, threads: 6, startedAt: Date.now() - 42 * 60_000 },
  { pid: 2290, name: 'nginx', command: 'nginx: worker process', user: 'www-data', memoryBytes: 14 * 2 ** 20, threads: 1, startedAt: Date.now() - 50 * 3600_000 },
  { pid: 3051, name: 'redis-server', command: '/usr/bin/redis-server 127.0.0.1:6379', user: 'redis', memoryBytes: 61 * 2 ** 20, threads: 5, startedAt: Date.now() - 50 * 3600_000 },
  { pid: 5120, name: 'node', command: 'node dist/server.js', user: 'ali', memoryBytes: 230 * 2 ** 20, threads: 11, startedAt: Date.now() - 2 * 3600_000 },
  { pid: 6004, name: 'code', command: '/usr/share/code/code --type=renderer', user: 'ali', memoryBytes: 780 * 2 ** 20, threads: 24, startedAt: Date.now() - 5 * 3600_000 },
  { pid: 7350, name: 'firefox', command: '/usr/lib/firefox/firefox', user: 'ali', memoryBytes: 1.9 * 2 ** 30, threads: 96, startedAt: Date.now() - 8 * 3600_000 },
  { pid: 812, name: 'systemd-journald', command: '/usr/lib/systemd/systemd-journald', user: 'root', memoryBytes: 22 * 2 ** 20, threads: 1, startedAt: Date.now() - 50 * 3600_000 },
  { pid: 905, name: 'dockerd', command: '/usr/bin/dockerd -H fd://', user: 'root', memoryBytes: 88 * 2 ** 20, threads: 17, startedAt: Date.now() - 50 * 3600_000 },
  { pid: 8433, name: 'zig', command: 'zig build test', user: 'ali', memoryBytes: 512 * 2 ** 20, threads: 16, startedAt: Date.now() - 90_000 },
]

const baseCpu: Record<string, number> = {
  'orbit-server': 128,
  python3: 96,
  postgres: 34,
  firefox: 22,
  code: 9,
  node: 6,
  zig: 310,
  dockerd: 1.2,
  nginx: 0.4,
  'redis-server': 0.8,
}

export class MockSource implements DataSource {
  readonly label = 'Sample data'

  private runs = new Map<string, Run>()
  private listeners = new Set<() => void>()
  private nextId = 1
  private timer: ReturnType<typeof setInterval> | undefined
  /** The last profile per request: the same until a new window arrives. */
  private profiles = new Map<string, { windows: number; profile: Profile }>()

  constructor() {
    const hour = 3600_000
    this.seed('orbit-server', 4242, 30, Date.now() - 2 * hour, 'duration')
    this.seed('postgres', 1187, 48, Date.now() - 5 * hour, 'cancelled')
    this.seed('python3', 9811, 12, Date.now() - 26 * hour, 'target_exited')
    void this.startSession({ target: { kind: 'pid', pid: 4242 }, metrics: ['cpu'], intervalMs: 1000, durationS: 0 })
  }

  async listProcesses(): Promise<ProcessInfo[]> {
    const t = Date.now() / 4000
    return processes.map((p) => {
      const base = baseCpu[p.name] ?? 0.1
      const wobble = 1 + 0.2 * Math.sin(t + p.pid)
      return { ...p, cpuPercent: Math.max(0, base * wobble) }
    })
  }

  async listSessions(): Promise<Session[]> {
    return [...this.runs.values()].map((r) => ({ ...r.session })).sort((a, b) => b.startedAt - a.startedAt)
  }

  async getSession(id: string): Promise<Session | null> {
    const run = this.runs.get(id)
    return run ? { ...run.session } : null
  }

  async startSession(request: StartRequest): Promise<Session> {
    let pid: number
    let name: string
    let command: string
    if (request.target.kind === 'pid') {
      const targetPid = request.target.pid
      const process = processes.find((p) => p.pid === targetPid)
      if (!process) throw new Error(`no process with pid ${targetPid}`)
      pid = process.pid
      name = process.name
      command = process.command
    } else {
      pid = 20000 + Math.floor(Math.random() * 10000)
      name = request.target.path.slice(request.target.path.lastIndexOf('/') + 1) || request.target.path
      command = [request.target.path, ...request.target.args].join(' ')
    }
    const id = `s${this.nextId++}`
    const run: Run = {
      session: {
        id,
        pid,
        name,
        command,
        metrics: request.metrics,
        intervalMs: request.intervalMs,
        durationS: request.durationS,
        startedAt: Date.now(),
        elapsedMs: 0,
        status: 'running',
        reason: null,
        sampleHz,
        lost: 0,
        windows: [],
      },
      program: programFor(name),
      counts: [],
      rand: random(pid),
    }
    this.runs.set(id, run)
    this.ensureTimer()
    this.emit()
    return { ...run.session }
  }

  async stopSession(id: string): Promise<void> {
    const run = this.runs.get(id)
    if (!run || run.session.status !== 'running') return
    this.finish(run, 'cancelled')
    this.emit()
  }

  async deleteSession(id: string): Promise<void> {
    this.runs.delete(id)
    for (const key of this.profiles.keys()) if (key.startsWith(`${id}:`)) this.profiles.delete(key)
    this.emit()
  }

  async getProfile(id: string, metric: MetricId, range: WindowRange | null): Promise<Profile> {
    const run = this.runs.get(id)
    if (!run) throw new Error(`no session ${id}`)
    const empty: Profile = { metric, sampleHz, total: 0, lost: 0, stacks: [] }
    if (metric !== 'cpu' || !run.session.metrics.includes('cpu')) return empty

    const cacheKey = `${id}:${metric}:${range ? `${range.from}-${range.to}` : 'all'}`
    const cached = this.profiles.get(cacheKey)
    if (cached && cached.windows === run.counts.length) return cached.profile

    const from = range ? Math.max(0, range.from) : 0
    const to = range ? Math.min(run.counts.length - 1, range.to) : run.counts.length - 1
    const sums = new Array<number>(run.program.stacks.length).fill(0)
    for (let w = from; w <= to; w++) {
      run.counts[w].forEach((n, i) => (sums[i] += n))
    }
    const stacks = run.program.stacks
      .map((template, i) => ({ value: sums[i], frames: template.frames, complete: template.complete }))
      .filter((s) => s.value > 0)
    const total = stacks.reduce((sum, s) => sum + s.value, 0)
    const lost = range ? 0 : run.session.lost
    const profile: Profile = { metric, sampleHz, total, lost, stacks }
    this.profiles.set(cacheKey, { windows: run.counts.length, profile })
    return profile
  }

  subscribe(onChange: () => void): () => void {
    this.listeners.add(onChange)
    return () => this.listeners.delete(onChange)
  }

  private emit() {
    for (const listener of this.listeners) listener()
  }

  /** A finished session, as if it had run `seconds` long at `startedAt`. */
  private seed(name: string, pid: number, seconds: number, startedAt: number, reason: Session['reason']) {
    const process = processes.find((p) => p.pid === pid)
    const id = `s${this.nextId++}`
    const run: Run = {
      session: {
        id,
        pid,
        name,
        command: process?.command ?? name,
        metrics: ['cpu'],
        intervalMs: 1000,
        durationS: reason === 'duration' ? seconds : 0,
        startedAt,
        elapsedMs: 0,
        status: 'running',
        reason: null,
        sampleHz,
        lost: 0,
        windows: [],
      },
      program: programFor(name),
      counts: [],
      rand: random(pid * 31 + seconds),
    }
    for (let i = 0; i < seconds; i++) this.addWindow(run)
    this.finish(run, reason ?? 'cancelled')
    if (name === 'postgres') run.session.lost = 37 // shows the "samples lost" warning
    this.runs.set(id, run)
  }

  private ensureTimer() {
    if (this.timer !== undefined) return
    this.timer = setInterval(() => this.tick(), 200)
  }

  private tick() {
    let changed = false
    let running = 0
    const now = Date.now()
    for (const run of this.runs.values()) {
      const s = run.session
      if (s.status !== 'running') continue
      running++
      s.elapsedMs = now - s.startedAt
      while ((s.windows.length + 1) * s.intervalMs <= s.elapsedMs) {
        this.addWindow(run)
        if (s.durationS > 0 && s.windows.length * s.intervalMs >= s.durationS * 1000) {
          this.finish(run, 'duration')
          break
        }
      }
      // The clock in the header moves even between windows.
      changed = true
    }
    if (running === 0 && this.timer !== undefined) {
      clearInterval(this.timer)
      this.timer = undefined
    }
    if (changed) this.emit()
  }

  private addWindow(run: Run) {
    const s = run.session
    const index = s.windows.length
    const seconds = s.intervalMs / 1000
    const t = (index * s.intervalMs) / 1000
    const weights = run.program.stacks.map((st) => st.weight * (1 + st.swing * Math.sin(t / 4 + st.phase)))
    const sum = weights.reduce((a, b) => a + b, 0)
    const expected = sampleHz * seconds * run.program.load * (0.85 + 0.3 * run.rand())
    const counts = weights.map((w) => {
      const mean = (expected * w) / sum
      return Math.max(0, Math.round(mean + (run.rand() - 0.5) * Math.sqrt(mean) * 2))
    })
    const total = counts.reduce((a, b) => a + b, 0)
    run.counts.push(counts)
    s.windows = [...s.windows, { startMs: index * s.intervalMs, durationMs: s.intervalMs, values: { cpu: total } }]
    s.elapsedMs = Math.max(s.elapsedMs, (index + 1) * s.intervalMs)
  }

  private finish(run: Run, reason: NonNullable<Session['reason']>) {
    run.session.status = 'stopped'
    run.session.reason = reason
    run.session.elapsedMs = Math.max(run.session.elapsedMs, run.session.windows.length * run.session.intervalMs)
  }
}
