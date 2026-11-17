import { useMemo } from "react";
import type { FunctionStat, TreeNode } from "@/lib/profile/analyze";
import { engineApply, engineCreate } from "@/lib/profile/live";
import type { Quality } from "@/lib/profile/quality";
import type { Profile } from "@/lib/profile/types";

export interface Analysis {
  profile: Profile;
  functions: FunctionStat[];
  byKey: Map<string, FunctionStat>;
  tree: TreeNode;
  programModule: string | null;
  quality: Quality;
}

export function analyze(profile: Profile): Analysis {
  return { profile, ...engineApply(engineCreate(), profile) };
}

export function useAnalysis(
  profile: Profile | undefined,
): Analysis | undefined {
  return useMemo(() => (profile ? analyze(profile) : undefined), [profile]);
}

export interface ViewProps {
  analysis: Analysis;
  search: string;
  selected: string | null;
  onSelect: (key: string | null) => void;
}
