import type { ReactNode } from "react";
import { ProbesContext, useProbesPolling } from "@/hooks/use-probes";

export function ProbesProvider({ children }: { children: ReactNode }) {
  const state = useProbesPolling();
  return <ProbesContext value={state}>{children}</ProbesContext>;
}
