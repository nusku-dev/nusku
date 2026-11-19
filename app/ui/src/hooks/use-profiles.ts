import {
  createContext,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import {
  backend,
  type LaunchRequest,
  type ProfileStateWire,
  type StartRequest,
} from "@/lib/backend";
import type { Session, Window } from "@/lib/profile/types";
import { num, windowsOf } from "@/lib/profile/wire";
import type { ProcessInfo } from "@/lib/types";
import { useMachine } from "./use-machine";

const pauseMs = 1000;

export interface ProfilesState {
  sessions: Session[];
  error: Error | undefined;
  loading: boolean;
  start: (request: StartRequest) => Promise<number>;
  launch: (request: LaunchRequest) => Promise<number>;
  stop: (job: number) => Promise<void>;
}

export const ProfilesContext = createContext<ProfilesState | null>(null);

export function useProfiles(): ProfilesState {
  const state = useContext(ProfilesContext);
  if (!state)
    throw new Error("useProfiles needs a ProfilesProvider around the app");
  return state;
}

export function useSession(job: number): Session | undefined {
  return useProfiles().sessions.find((s) => s.job === job);
}

interface Memory {
  named: boolean;
  name: string;
  command: string;
  startedAt: number;
  built: string;
  windows: Window[];
}

const noWindows: Window[] = [];

export function useProfilesPolling(): ProfilesState {
  const { machine } = useMachine();
  const known = useRef(
    new Map<number, Pick<ProcessInfo, "name" | "command">>(),
  );
  const memory = useRef(new Map<number, Memory>());
  const [mine, setMine] = useState<ReadonlySet<number>>(new Set());
  const [polled, setPolled] = useState<{
    list: Session[] | undefined;
    error: Error | undefined;
  }>({
    list: undefined,
    error: undefined,
  });
  const [tick, setTick] = useState(0);

  useEffect(() => {
    for (const p of machine?.processes ?? [])
      known.current.set(p.pid, { name: p.name, command: p.command });
  }, [machine]);

  useEffect(() => {
    let alive = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const ask = () => {
      clearTimeout(timer);
      backend
        .profileStream()
        .then((wire) => {
          if (!alive) return;
          const now = Date.now();
          const list = wire.map((state) =>
            sessionOf(
              state,
              remember(memory.current, known.current, state, now),
            ),
          );
          setPolled({ list, error: undefined });
        })
        .catch((error: unknown) => {
          if (alive)
            setPolled((last) => ({
              ...last,
              error: error instanceof Error ? error : new Error(String(error)),
            }));
        })
        .finally(() => {
          if (alive) timer = setTimeout(ask, pauseMs);
        });
    };
    ask();
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [tick]);

  const sessions = useMemo(
    () =>
      (polled.list ?? []).map((s) =>
        mine.has(s.job) ? { ...s, mine: true } : s,
      ),
    [polled.list, mine],
  );

  const start = async (request: StartRequest) => {
    const started = await backend.profileStart(request);
    setMine((last) => new Set(last).add(started.job));
    setTick((t) => t + 1);
    return started.job;
  };

  const stop = async (job: number) => {
    await backend.profileStop(job);
    setMine((last) => {
      const next = new Set(last);
      next.delete(job);
      return next;
    });
    setTick((t) => t + 1);
  };

  const launch = async (request: LaunchRequest) => {
    const started = await backend.profileLaunch(request);
    memory.current.set(started.job, {
      named: true,
      name: request.exec.slice(request.exec.lastIndexOf("/") + 1),
      command: [request.exec, ...request.args].join(" "),
      startedAt: Date.now(),
      built: "",
      windows: noWindows,
    });
    setMine((last) => new Set(last).add(started.job));
    setTick((t) => t + 1);
    return started.job;
  };

  return {
    sessions,
    error: polled.error,
    loading: !polled.list && !polled.error,
    start,
    launch,
    stop,
  };
}

function remember(
  memory: Map<number, Memory>,
  known: Map<number, Pick<ProcessInfo, "name" | "command">>,
  state: ProfileStateWire,
  now: number,
): Memory {
  let entry = memory.get(state.job);
  if (!entry) {
    entry = {
      named: false,
      name: "unknown",
      command: "",
      startedAt: now - state.elapsed_ms,
      built: "",
      windows: noWindows,
    };
    memory.set(state.job, entry);
  }
  const process = entry.named ? undefined : known.get(state.pid);
  if (process) {
    entry.named = true;
    entry.name = process.name;
    entry.command = process.command;
  }
  const windows = state.profile?.windows ?? [];
  const last = windows[windows.length - 1];
  const built = `${windows.length}:${last ? num(last.start_unix_ns) : 0}`;
  if (state.profile && entry.built !== built) {
    entry.built = built;
    entry.windows = windowsOf(state.profile);
    const first = entry.windows[0];
    if (first && state.running)
      entry.startedAt = Math.min(entry.startedAt, first.startMs);
  }
  return entry;
}

function sessionOf(state: ProfileStateWire, entry: Memory): Session {
  return {
    job: state.job,
    pid: state.pid,
    name: entry.name,
    command: entry.command,
    running: state.running,
    users: state.users,
    mine: false,
    elapsedMs: state.elapsed_ms,
    startedAt: entry.startedAt,
    reason: state.reason,
    failure: state.failure,
    samples: state.profile ? num(state.profile.samples) : 0,
    lost: state.profile ? num(state.profile.samples_lost) : 0,
    sampleHz: state.profile?.sample_hz ?? 0,
    windows: entry.windows,
  };
}
