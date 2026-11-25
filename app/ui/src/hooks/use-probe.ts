import { useEffect, useState } from "react";
import { backend, type ProbeGetWire } from "@/lib/backend";
import { num } from "@/lib/profile/wire";
import { pointsOf, type ProbePoint } from "@/lib/probe";

const pauseMs = 1000;
const pointsMax = 3600;

export interface ProbeView {
  info: ProbeGetWire["info"];
  finished: boolean;
  points: ProbePoint[];
  unmatched: number;
  untimed: number;
  dropped: number;
}

export function useProbe(job: number) {
  const [state, setState] = useState<{ view?: ProbeView; error?: Error }>({});

  useEffect(() => {
    let alive = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let points: ProbePoint[] = [];
    const ask = () => {
      const from = (points.at(-1)?.index ?? -1) + 1;
      backend
        .probeGet(job, from)
        .then((wire) => {
          if (!alive) return;
          points = [...points, ...pointsOf(wire)].slice(-pointsMax);
          setState({
            view: {
              info: wire.info,
              finished: wire.finished,
              points,
              unmatched: num(wire.unmatched),
              untimed: num(wire.untimed),
              dropped: num(wire.dropped),
            },
          });
          if (!wire.finished) timer = setTimeout(ask, pauseMs);
        })
        .catch((e: unknown) => {
          if (!alive) return;
          setState({ error: e instanceof Error ? e : new Error(String(e)) });
          timer = setTimeout(ask, pauseMs);
        });
    };
    ask();
    return () => {
      alive = false;
      clearTimeout(timer);
    };
  }, [job]);

  return state;
}
