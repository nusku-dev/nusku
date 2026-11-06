import { AppShell } from '@/components/layout/AppShell'
import { ProcessesPage } from '@/features/processes/ProcessesPage'
import { SessionPage } from '@/features/sessions/SessionPage'
import { SessionsPage } from '@/features/sessions/SessionsPage'
import { useRoute } from '@/lib/router'

export default function App() {
  const route = useRoute()
  return (
    <AppShell>
      {route.name === 'processes' && <ProcessesPage />}
      {route.name === 'sessions' && <SessionsPage />}
      {route.name === 'session' && <SessionPage id={route.id} />}
    </AppShell>
  )
}
