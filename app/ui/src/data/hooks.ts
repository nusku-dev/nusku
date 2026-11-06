import { createContext, useContext, useEffect, useEffectEvent, useState } from 'react'
import type { MetricId, WindowRange } from '@/lib/profile/types'
import type { DataSource } from './source'

export const DataSourceContext = createContext<DataSource | null>(null)

export function useDataSource(): DataSource {
  const source = useContext(DataSourceContext)
  if (!source) throw new Error('useDataSource outside of DataSourceContext')
  return source
}

export interface Resource<T> {
  data: T | undefined
  error: Error | undefined
  /** True until the first answer for this key. Later refreshes keep the old data showing. */
  loading: boolean
}

/**
 * Loads something from the data source, and loads it again whenever the source says it changed.
 * `key` names what is loaded: a new key starts over, and the old key's answer is never shown.
 */
function useResource<T>(key: string, load: (source: DataSource) => Promise<T>): Resource<T> {
  const source = useDataSource()
  const [state, setState] = useState<{ key: string; data?: T; error?: Error }>({ key: '' })
  const fetch = useEffectEvent((alive: () => boolean) => {
    load(source).then(
      (data) => alive() && setState({ key, data }),
      (error: unknown) => alive() && setState({ key, error: error instanceof Error ? error : new Error(String(error)) }),
    )
  })

  useEffect(() => {
    let alive = true
    const isAlive = () => alive
    fetch(isAlive)
    const unsubscribe = source.subscribe(() => fetch(isAlive))
    return () => {
      alive = false
      unsubscribe()
    }
  }, [key, source])

  const current = state.key === key
  return {
    data: current ? state.data : undefined,
    error: current ? state.error : undefined,
    loading: !current,
  }
}

export function useProcesses() {
  return useResource('processes', (s) => s.listProcesses())
}

export function useSessions() {
  return useResource('sessions', (s) => s.listSessions())
}

export function useSession(id: string) {
  return useResource(`session:${id}`, (s) => s.getSession(id))
}

export function useProfile(id: string, metric: MetricId, range: WindowRange | null) {
  const key = `profile:${id}:${metric}:${range ? `${range.from}-${range.to}` : 'all'}`
  return useResource(key, (s) => s.getProfile(id, metric, range))
}
