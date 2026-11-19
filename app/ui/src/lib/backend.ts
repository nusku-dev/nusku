type Arg = string | number | boolean | Uint8Array;

interface WebUI {
  call(fn: string, ...args: Arg[]): Promise<string>;
  isConnected(): boolean;
  setEventCallback(callback: (event: number) => void): void;
  allowNavigation(status: boolean): void;
  event: { CONNECTED: number; DISCONNECTED: number };
}

declare global {
  var webui: WebUI | undefined;
}

export interface ProcessInfoWire {
  pid: number;
  name: string;
  user: string;
  command: string;
  threads: number;
  cpu_percent: number | null;
  memory_bytes: number;
  started_unix_ns: number;
}

export interface MachineCpu {
  busy_percent: number;
  user_percent: number;
  system_percent: number;
  iowait_percent: number;
  irq_percent: number;
  steal_percent: number;
}

export interface ProcessFrame {
  unix_ns: number;
  interval_ns: number;
  processes: ProcessInfoWire[];
  machine: { cpus: number; cpu: MachineCpu | null };
}

export type StopReason = "duration" | "target_exited" | "cancelled";

type Big = number | string;

type WindowWire = {
  start_unix_ns: Big;
  duration_ns: Big;
  samples: Big;
  samples_lost: Big;
};

export interface SummaryWire {
  sample_hz: number;
  samples: Big;
  samples_lost: Big;
  windows_rejected: Big;
  windows: WindowWire[];
}

export interface FrameWire {
  a: string;
  k: boolean;
  f: number;
  s: number;
  l: number;
  m: number;
  i: boolean;
}

export interface CompactWire extends SummaryWire {
  strings: string[];
  stacks: { d: number; n: Big; c: boolean; f: FrameWire[] }[];
}

export interface ProfileStateWire {
  job: number;
  pid: number;
  running: boolean;
  users: number;
  elapsed_ms: number;
  reason: StopReason | null;
  failure: string | null;
  profile: SummaryWire | null;
}

export interface StartRequest {
  pid: number;
  metrics: string;
  interval_ms: number;
  duration_s: number;
}

export interface LaunchRequest {
  exec: string;
  args: string[];
  metrics: string;
  interval_ms: number;
  duration_s: number;
  end_program: boolean;
}

const listeners = new Set<(connected: boolean) => void>();
let connected = false;
let listening = false;

function bridge(): WebUI | undefined {
  const ui = globalThis.webui;
  if (ui && !listening) {
    listening = true;
    connected = ui.isConnected();
    if (connected) ui.allowNavigation(true);
    ui.setEventCallback((event) => {
      connected = event === ui.event.CONNECTED;
      if (connected) ui.allowNavigation(true);
      for (const listener of listeners) listener(connected);
    });
  }
  return ui;
}

export function onConnection(
  listener: (connected: boolean) => void,
): () => void {
  bridge();
  listeners.add(listener);
  listener(connected);
  return () => listeners.delete(listener);
}

function whenConnected(): Promise<WebUI> {
  const ui = bridge();
  if (!ui) return Promise.reject(new Error("The backend is not running"));
  if (connected) return Promise.resolve(ui);
  return new Promise((resolve) => {
    const listener = (now: boolean) => {
      if (!now) return;
      listeners.delete(listener);
      resolve(ui);
    };
    listeners.add(listener);
  });
}

async function call<T>(fn: string, ...args: Arg[]): Promise<T> {
  const ui = await whenConnected();
  const answer: unknown = JSON.parse(await ui.call(fn, ...args));
  if (answer && typeof answer === "object" && "error" in answer)
    throw new Error(String(answer.error));
  return answer as T;
}

export const backend = {
  processes: () => call<ProcessFrame>("get_processes"),
  profileStart: (request: StartRequest) =>
    call<{ job: number; pid: number; joined: boolean }>(
      "profile_start",
      JSON.stringify(request),
    ),
  profileLaunch: (request: LaunchRequest) =>
    call<{ job: number; joined: boolean }>(
      "profile_launch",
      JSON.stringify(request),
    ),
  profileStop: (job: number) =>
    call<{ job: number; reason: StopReason | null; users: number }>(
      "profile_stop",
      job,
    ),
  profileStream: () => call<ProfileStateWire[]>("profile_stream"),
  profileGet: (job: number, since: number) =>
    call<
      | { unchanged: true }
      | { clock: number; full: boolean; profile: CompactWire }
    >("profile_get", JSON.stringify({ job, since })),
  profileRange: (job: number, fromMs: number, toMs: number) =>
    call<CompactWire>(
      "profile_range",
      JSON.stringify({
        job,
        from_ms: Math.floor(fromMs),
        to_ms: Math.ceil(toMs),
      }),
    ),
};
