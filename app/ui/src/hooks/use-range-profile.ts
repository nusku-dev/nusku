import { useEffect, useState } from "react";
import { backend } from "@/lib/backend";
import type { Profile, Range } from "@/lib/profile/types";
import { profileOf } from "@/lib/profile/wire";

export function useRangeProfile(job: number, range: Range | null) {
  const [state, setState] = useState<{
    key: string;
    profile?: Profile;
    error?: Error;
  }>({ key: "" });
  const key = range ? `${job}:${range.fromMs}:${range.toMs}` : "";

  useEffect(() => {
    if (!range) return;
    let alive = true;
    backend
      .profileRange(job, range.fromMs, range.toMs)
      .then((wire) => alive && setState({ key, profile: profileOf(wire) }))
      .catch((error: unknown) => {
        if (alive)
          setState({
            key,
            error: error instanceof Error ? error : new Error(String(error)),
          });
      });
    return () => {
      alive = false;
    };
  }, [job, range, key]);

  const current = state.key === key;
  return {
    profile: current ? state.profile : undefined,
    error: current ? state.error : undefined,
  };
}
