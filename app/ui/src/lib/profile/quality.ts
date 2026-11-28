import type { Stack } from "./types";

export interface ModuleGap {
  module: string;
  unnamed: number;
  noLines: number;
}

export interface Quality {
  samples: number;
  incomplete: number;
  goSwitch: number;
  unnamed: number;
  lost: number;
  rejected: number;
  modules: ModuleGap[];
}

const goSwitches = [
  "runtime.morestack",
  "runtime.mcall",
  "runtime.systemstack",
  "runtime.nanotime1",
  "runtime.walltime",
  "runtime.sigreturn",
];

export function goSwitch(stack: Stack): boolean {
  if (stack.complete || stack.frames.length === 0) return false;
  const outermost = stack.frames[stack.frames.length - 1].function;
  if (!outermost) return false;
  if (goSwitches.some((prefix) => outermost.startsWith(prefix))) return true;
  return (
    outermost === "time.now" && stack.frames.some((f) => f.module === "[vdso]")
  );
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
