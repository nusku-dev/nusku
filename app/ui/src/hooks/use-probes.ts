import { createContext, useContext, useEffect, useState } from "react";
import {
  backend,
  type ProbeListed,
  type ProbeStartRequest,
} from "@/lib/backend";

const pauseMs = 1000;

export interface ProbesState {
  probes: ProbeListed[];
  start: (request: ProbeStartRequest) => Promise<number>;
  stop: (job: number) => Promise<void>;
}

export const ProbesContext = createContext<ProbesState | null>(null);

export function useProbes(): ProbesState {
  const state = useContext(ProbesContext);
  if (!state)
    throw new Error("useProbes needs a ProbesProvider around the app");
  return state;
}

export function useProbesPolling(): ProbesState {
  const [probes, setProbes] = useState<ProbeListed[]>([]);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let alive = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const ask = () => {
      backend
        .probeList()
        .then((list) => alive && setProbes(list))
        .catch(() => {})
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

  const start = async (request: ProbeStartRequest) => {
    const started = await backend.probeStart(request);
    setTick((t) => t + 1);
    return started.job;
  };
  const stop = async (job: number) => {
    await backend.probeStop(job);
    setTick((t) => t + 1);
  };
  return { probes, start, stop };
}
