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

export interface RunMeta {
  id: number;
  label: string;
  note: string;
  program: string;
  command: string;
  pid: number;
  started_unix_ms: number;
  elapsed_ms: number;
  saved_unix_ms: number;
  samples: number;
  sample_hz: number;
}

export interface SaveRequest {
  job: number;
  label: string;
  note: string;
  program: string;
  command: string;
}

export interface ProbeListed {
  job: number;
  pid: number;
  running: boolean;
  elapsed_ms: number;
  reason: StopReason | null;
  failure: string | null;
  function: string;
  path: string;
  calls: number | string;
  timed: number | string;
  total_ns: number | string;
  max_ns: number | string;
}

export interface ProbePointWire {
  t: number | string;
  d: number | string;
  c: number | string;
  n: number | string;
  s: number | string;
  m: number | string;
  h: [number, number | string][];
}

export interface ProbeGetWire {
  job: number;
  finished: boolean;
  first: number;
  info: {
    pid: number;
    function: string;
    path: string;
    offset: number | string;
    size: number | string;
  } | null;
  unmatched: number | string;
  untimed: number | string;
  dropped: number | string;
  points: ProbePointWire[];
}

export interface ProbeStartRequest {
  pid: number;
  function: string;
  module: string | null;
  interval_ms: number;
  duration_s: number;
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
  probeStart: (request: ProbeStartRequest) =>
    call<{ job: number }>("probe_start", JSON.stringify(request)),
  probeStop: (job: number) =>
    call<{ job: number; reason: StopReason }>("probe_stop", job),
  probeList: () => call<ProbeListed[]>("probe_list"),
  probeGet: (job: number, from: number) =>
    call<ProbeGetWire>("probe_get", JSON.stringify({ job, from })),
  runsList: () => call<RunMeta[]>("store_runs_list"),
  runsSave: (request: SaveRequest) =>
    call<RunMeta>("store_runs_save", JSON.stringify(request)),
  runsGet: (id: number) =>
    call<{ meta: RunMeta; profile: CompactWire }>("store_runs_get", id),
  runsRelabel: (id: number, label: string, note: string) =>
    call<RunMeta>("stor_runs_relabel", JSON.stringify({ id, label, note })),
  runsDelete: (id: number) => call<{ id: number }>("store_runs_delete", id),
};
