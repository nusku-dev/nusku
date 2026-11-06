// Where the UI gets its data. Screens only see this interface (through the hooks in hooks.ts),
// so moving from sample data to the real backend means writing one more implementation of it,
// on top of lib/backend.ts, and choosing it in main.tsx.

import type {
  MetricId,
  ProcessInfo,
  Profile,
  Session,
  StartRequest,
  WindowRange,
} from '@/lib/profile/types'

export interface DataSource {
  /** Shown in the sidebar, so it is always clear what the numbers come from. */
  readonly label: string
  listProcesses(): Promise<ProcessInfo[]>
  listSessions(): Promise<Session[]>
  getSession(id: string): Promise<Session | null>
  /** Resolves once the session exists; it then runs on its own. */
  startSession(request: StartRequest): Promise<Session>
  stopSession(id: string): Promise<void>
  deleteSession(id: string): Promise<void>
  /** The profile of one metric over the whole session, or over `range` of its windows. */
  getProfile(id: string, metric: MetricId, range: WindowRange | null): Promise<Profile>
  /** Called whenever anything may have changed (a new window, a session that ended). */
  subscribe(onChange: () => void): () => void
}
