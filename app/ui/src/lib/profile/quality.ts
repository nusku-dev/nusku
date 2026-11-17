export interface ModuleGap {
  module: string;
  unnamed: number;
  noLines: number;
}

export interface Quality {
  samples: number;
  incomplete: number;
  unnamed: number;
  lost: number;
  rejected: number;
  modules: ModuleGap[];
}

export function share(part: number, whole: number): number {
  return whole > 0 ? part / whole : 0;
}

export function trusted(q: Quality): boolean {
  const lostShare = share(q.lost, q.samples + q.lost);
  return (
    share(q.incomplete, q.samples) < 0.05 &&
    share(q.unnamed, q.samples) < 0.05 &&
    lostShare < 0.01 &&
    q.rejected === 0
  );
}
