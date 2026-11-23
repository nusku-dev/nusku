import { frameName, rootFrame } from "./analyze";
import type { Frame, Profile } from "./types";

export type Measure = "time" | "share";

const noiseSigmas = 3;

export interface Side {
  profile: Profile;
  hz: number;
}

export interface Amount {
  self: number;
  total: number;
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
  a: number;
  b: number;
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

export function compare(a: Profile, b: Profile): Comparison {
  const byKey = new Map<string, FunctionDiff>();
  const add = (profile: Profile, side: "a" | "b") => {
    for (const stack of profile.stacks) {
      const seen = new Set<string>();
      stack.frames.forEach((frame, index) => {
        const key = diffKey(frame);
        let entry = byKey.get(key);
        if (!entry) {
          entry = {
            key,
            frame,
            a: { self: 0, total: 0 },
            b: { self: 0, total: 0 },
          };
          byKey.set(key, entry);
        }
        if (index === 0) entry[side].self += stack.value;
        if (seen.has(key)) return;
        seen.add(key);
        entry[side].total += stack.value;
      });
    }
  };
  add(a, "a");
  add(b, "b");
  return { functions: [...byKey.values()], byKey };
}

export function diffTree(
  a: Profile,
  b: Profile,
  focus: string | null,
): DiffNode {
  const root: DiffNode = {
    id: "",
    key: "",
    frame: rootFrame,
    a: 0,
    b: 0,
    children: [],
  };
  const index = new Map<string, DiffNode>();
  const add = (profile: Profile, side: "a" | "b") => {
    for (const stack of profile.stacks) {
      const keys = stack.frames.map(diffKey);
      const start = focus === null ? keys.length - 1 : keys.lastIndexOf(focus);
      if (start < 0) continue;
      root[side] += stack.value;
      let at = root;
      for (let i = start; i >= 0; i--) {
        const id = `${at.id}>${keys[i]}`;
        let node = index.get(id);
        if (!node) {
          node = {
            id,
            key: keys[i],
            frame: stack.frames[i],
            a: 0,
            b: 0,
            children: [],
          };
          index.set(id, node);
          at.children.push(node);
        }
        node[side] += stack.value;
        at = node;
      }
    }
  };
  add(a, "a");
  add(b, "b");
  return root;
}

export function valueOf(samples: number, side: Side, measure: Measure): number {
  if (measure === "time") return side.hz > 0 ? samples / side.hz : 0;
  return side.profile.total > 0 ? (100 * samples) / side.profile.total : 0;
}

function sigmaOf(samples: number, side: Side, measure: Measure): number {
  if (measure === "time") return side.hz > 0 ? Math.sqrt(samples) / side.hz : 0;
  const n = side.profile.total;
  if (n === 0) return 0;
  const p = samples / n;
  return (100 * Math.sqrt(Math.max(samples * (1 - p), 0))) / n;
}

export interface Change {
  before: number;
  after: number;
  delta: number;
  relative: number | null;
  noise: boolean;
}

export function changeOf(
  a: number,
  b: number,
  before: Side,
  after: Side,
  measure: Measure,
): Change {
  const x = valueOf(a, before, measure);
  const y = valueOf(b, after, measure);
  const sigma = Math.hypot(
    sigmaOf(Math.max(a, 1), before, measure),
    sigmaOf(Math.max(b, 1), after, measure),
  );
  const delta = y - x;
  return {
    before: x,
    after: y,
    delta,
    relative: x > 0 ? delta / x : null,
    noise: Math.abs(delta) <= noiseSigmas * sigma,
  };
}
