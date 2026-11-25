import { frameName, rootFrame } from "./analyze";
import type { Frame, Profile } from "./types";

export type Measure = "time" | "share";

const noiseSigmas = 3;

export interface Side {
  profiles: Profile[];
  hz: number;
}

export interface Amount {
  self: number[];
  total: number[];
}

export interface FunctionDiff {
  key: string;
  frame: Frame;
  a: Amount;
  b: Amount;
}

export interface DiffNode {
  id: string;
  key: string;
  frame: Frame;
  a: number[];
  b: number[];
  children: DiffNode[];
}

export interface Comparison {
  functions: FunctionDiff[];
  byKey: Map<string, FunctionDiff>;
}

export function diffKey(frame: Frame): string {
  const module = frame.kernel ? "kernel" : (frame.module ?? "");
  return `${frameName(frame)}\u0000${module.slice(module.lastIndexOf("/") + 1)}`;
}

function zeros(n: number): number[] {
  return new Array<number>(n).fill(0);
}

export function compare(a: Profile[], b: Profile[]): Comparison {
  const byKey = new Map<string, FunctionDiff>();
  const add = (profiles: Profile[], side: "a" | "b") => {
    profiles.forEach((profile, run) => {
      for (const stack of profile.stacks) {
        const seen = new Set<string>();
        stack.frames.forEach((frame, index) => {
          const key = diffKey(frame);
          let entry = byKey.get(key);
          if (!entry) {
            entry = {
              key,
              frame,
              a: { self: zeros(a.length), total: zeros(a.length) },
              b: { self: zeros(b.length), total: zeros(b.length) },
            };
            byKey.set(key, entry);
          }
          if (index === 0) entry[side].self[run] += stack.value;
          if (seen.has(key)) return;
          seen.add(key);
          entry[side].total[run] += stack.value;
        });
      }
    });
  };
  add(a, "a");
  add(b, "b");
  return { functions: [...byKey.values()], byKey };
}

export function diffTree(
  a: Profile[],
  b: Profile[],
  focus: string | null,
): DiffNode {
  const root: DiffNode = {
    id: "",
    key: "",
    frame: rootFrame,
    a: zeros(a.length),
    b: zeros(b.length),
    children: [],
  };
  const index = new Map<string, DiffNode>();
  const add = (profiles: Profile[], side: "a" | "b") => {
    profiles.forEach((profile, run) => {
      for (const stack of profile.stacks) {
        const keys = stack.frames.map(diffKey);
        const start =
          focus === null ? keys.length - 1 : keys.lastIndexOf(focus);
        if (start < 0) continue;
        root[side][run] += stack.value;
        let at = root;
        for (let i = start; i >= 0; i--) {
          const id = `${at.id}>${keys[i]}`;
          let node = index.get(id);
          if (!node) {
            node = {
              id,
              key: keys[i],
              frame: stack.frames[i],
              a: zeros(a.length),
              b: zeros(b.length),
              children: [],
            };
            index.set(id, node);
            at.children.push(node);
          }
          node[side][run] += stack.value;
          at = node;
        }
      }
    });
  };
  add(a, "a");
  add(b, "b");
  return root;
}

export function meanOf(values: number[]): number {
  return values.length === 0
    ? 0
    : values.reduce((sum, v) => sum + v, 0) / values.length;
}

function valueOne(
  samples: number,
  profile: Profile,
  hz: number,
  measure: Measure,
): number {
  if (measure === "time") return hz > 0 ? samples / hz : 0;
  return profile.total > 0 ? (100 * samples) / profile.total : 0;
}

function varianceOne(
  samples: number,
  profile: Profile,
  hz: number,
  measure: Measure,
): number {
  const counted = Math.max(samples, 1);
  if (measure === "time") return hz > 0 ? counted / (hz * hz) : 0;
  const n = profile.total;
  if (n === 0) return 0;
  const p = Math.min(counted / n, 1);
  return (1e4 * Math.max(counted * (1 - p), 0)) / (n * n);
}

/** The mean over the runs of a side, and its uncertainty: sampling, or how far the runs are apart. */
export function estimateOf(
  counts: number[],
  side: Side,
  measure: Measure,
): { mean: number; sigma: number } {
  const n = counts.length;
  if (n === 0) return { mean: 0, sigma: 0 };
  const values = counts.map((c, run) =>
    valueOne(c, side.profiles[run], side.hz, measure),
  );
  const mean = meanOf(values);
  const variance = counts.reduce(
    (sum, c, run) => sum + varianceOne(c, side.profiles[run], side.hz, measure),
    0,
  );
  const sampling = Math.sqrt(variance) / n;
  if (n < 2) return { mean, sigma: sampling };
  const spread =
    Math.sqrt(values.reduce((sum, v) => sum + (v - mean) ** 2, 0) / (n - 1)) /
    Math.sqrt(n);
  return { mean, sigma: Math.max(sampling, spread) };
}

export interface Change {
  before: number;
  after: number;
  delta: number;
  relative: number | null;
  noise: boolean;
}

export function changeOf(
  a: number[],
  b: number[],
  before: Side,
  after: Side,
  measure: Measure,
): Change {
  const x = estimateOf(a, before, measure);
  const y = estimateOf(b, after, measure);
  const delta = y.mean - x.mean;
  return {
    before: x.mean,
    after: y.mean,
    delta,
    relative: x.mean > 0 ? delta / x.mean : null,
    noise: Math.abs(delta) <= noiseSigmas * Math.hypot(x.sigma, y.sigma),
  };
}
