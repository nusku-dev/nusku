import type { ReactNode } from "react";
import { ProfilesContext, useProfilesPolling } from "@/hooks/use-profiles";

export function ProfilesProvider({ children }: { children: ReactNode }) {
  const state = useProfilesPolling();
  return <ProfilesContext value={state}>{children}</ProfilesContext>;
}
