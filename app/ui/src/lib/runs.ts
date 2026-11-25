import type { RunMeta } from "./backend";

export const seriesPrefix = "s:";

export function compareKeyOf(run: RunMeta): string {
  return run.series ? `${seriesPrefix}${run.series}` : String(run.id);
}
