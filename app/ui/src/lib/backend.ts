// The typed bridge to the Zig backend. Every function bound in ../../../src/api.zig gets one
// wrapper here, so the rest of the UI never calls `webui.call` with a bare string.

type Arg = string | number | boolean | Uint8Array

interface WebUI {
  call(fn: string, ...args: Arg[]): Promise<string>
  isConnected(): boolean
  setEventCallback(callback: (event: number) => void): void
  event: { CONNECTED: number; DISCONNECTED: number }
}

declare global {
  // Set by /webui.js, which index.html loads before the app.
  var webui: WebUI | undefined
}

function bridge(): WebUI {
  if (!globalThis.webui) throw new Error('WebUI bridge not loaded: is the backend running?')
  return globalThis.webui
}

async function callJson<T>(fn: string, ...args: Arg[]): Promise<T> {
  return JSON.parse(await bridge().call(fn, ...args)) as T
}

/**
 * Calls `onChange` whenever the connection to the backend opens or drops. Without the bridge
 * (the UI opened in a plain browser) it reports "not connected" once.
 */
export function onConnection(onChange: (connected: boolean) => void): void {
  const ui = globalThis.webui
  if (!ui) return onChange(false)
  ui.setEventCallback((event) => onChange(event === ui.event.CONNECTED))
  onChange(ui.isConnected()) // it may have connected before we subscribed
}

export interface AppInfo {
  name: string
  version: string
}

export const backend = {
  appInfo: () => callJson<AppInfo>('app_info'),
}
