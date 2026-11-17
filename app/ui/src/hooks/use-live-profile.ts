import { useEffect, useState } from "react";
import type { Analysis } from "@/components/profile/analysis";
import { backend } from "@/lib/backend";
import { engineCreate, engineUpdate, type Change } from "@/lib/profile/live";
import type { Profile, Stack } from "@/lib/profile/types";
import { profileOf } from "@/lib/profile/wire";

const pauseMs = 1000;

export function useLiveProfile(job: number) {
  const [state, setState] = useState<{ analysis?: Analysis; error?: Error }>(
    {},
  );

  useEffect(() => {
    let alive = true;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let clock = 0;
    let engine = engineCreate();
    let stacks = new Map<number, Stack>();

    const take = (delta: Profile, full: boolean) => {
      if (full) {
        engine = engineCreate();
        stacks = new Map();
      }
      const changes: Change[] = delta.stacks.map((after) => ({
        before: stacks.get(after.id),
        after: after.value > 0 ? after : undefined,
      }));
      for (const after of delta.stacks) {
        if (after.value > 0) stacks.set(after.id, after);
        else stacks.delete(after.id);
      }
      const all = [...stacks.values()];
      const profile: Profile = {
        ...delta,
        stacks: all,
        total: all.reduce((sum, s) => sum + s.value, 0),
      };
      return { profile, ...engineUpdate(engine, changes, profile) };
    };

    const ask = () => {
      backend
        .profileGet(job, clock)
        .then((answer) => {
          if (!alive || "unchanged" in answer) return;
          clock = answer.clock;
          setState({ analysis: take(profileOf(answer.profile), answer.full) });
        })
        .catch((error: unknown) => {
          if (alive)
            setState((last) => ({
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
  }, [job]);

  return state;
}
