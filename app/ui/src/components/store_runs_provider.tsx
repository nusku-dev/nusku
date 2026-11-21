import { RunsContext, useStoreRuns } from "@/hooks/use_runs";
import type { ReactNode } from "react";

export function StoreRunsProvider({ children }: { children: ReactNode }) {
  const state = useStoreRuns();
  return <RunsContext value={state}>{children}</RunsContext>;
}
