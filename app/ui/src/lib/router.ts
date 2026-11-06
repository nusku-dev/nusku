// A tiny hash router

import { useSyncExternalStore } from 'react'

export type Route =
  | { name: 'sessions' }
  | { name: 'session'; id: string }
  | { name: 'processes' }

function parse(hash: string): Route {
  const parts = hash.replace(/^#\/?/, '').split('/').filter(Boolean)
  if (parts[0] === 'processes') return { name: 'processes' }
  if (parts[0] === 'sessions' && parts[1]) return { name: 'session', id: decodeURIComponent(parts[1]) }
  return { name: 'sessions' }
}

function subscribe(onChange: () => void) {
  window.addEventListener('hashchange', onChange)
  return () => window.removeEventListener('hashchange', onChange)
}

const current = () => window.location.hash

export function useRoute(): Route {
  return parse(useSyncExternalStore(subscribe, current))
}

export const paths = {
  sessions: () => '/sessions',
  session: (id: string) => `/sessions/${encodeURIComponent(id)}`,
  processes: () => '/processes',
}

export function href(path: string): string {
  return `#${path}`
}

export function navigate(path: string): void {
  window.location.hash = path
}
