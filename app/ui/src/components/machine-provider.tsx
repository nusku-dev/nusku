import type { ReactNode } from 'react'
import { MachineContext, useMachinePolling } from '@/hooks/use-machine'

export function MachineProvider({ children }: { children: ReactNode }) {
  const state = useMachinePolling()
  return <MachineContext value={state}>{children}</MachineContext>
}
