import { useEffect, useState } from 'react'
import { backend, onConnection, type AppInfo } from './lib/backend'

export default function App() {
  const [connected, setConnected] = useState(false)
  const [info, setInfo] = useState<AppInfo | null>(null)

  useEffect(() => onConnection(setConnected), [])

  useEffect(() => {
    if (connected) backend.appInfo().then(setInfo, console.error)
  }, [connected])

  return (
    <main className="flex-col justify-center items-center">
      <h1>{info ? `${info.name} ${info.version}` : 'Nusku'}</h1>
      <p className={connected ? 'text-green-500' : 'text-red-500'}>
        {connected ? 'Connected to backend' : 'Connecting…'}
      </p>
    </main>
  )
}
