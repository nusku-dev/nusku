import type { Frame, Profile } from "./types";

const keys = new Map<string, string>();
const paths = new Map<string, string>();

export function frameKey(frame: Frame): string {
  return frame.key || keyOf(frame);
}

export function keyOf(frame: Frame): string {
  const text = `${frameName(frame)}\u0000${frame.module ?? ""}`;
  let key = keys.get(text);
  if (key === undefined) {
    key = `k${keys.size}`;
    keys.set(text, key);
  }
  return key;
}

export function pathId(parent: string, key: string): string {
  const text = `${parent}>${key}`;
  let id = paths.get(text);
  if (id === undefined) {
    id = `p${paths.size + 1}`;
    paths.set(text, id);
  }
  return id;
}

export function frameName(frame: Frame): string {
  if (frame.function) return frame.function;
  if (frame.kernel) return "[kernel]";
  if (!frame.module) return "[unknown]";
  return `[${frame.module.slice(frame.module.lastIndexOf("/") + 1)}]`;
}

export function moduleName(frame: Frame): string {
  if (frame.kernel) return "kernel";
  if (!frame.module) return "unknown";
  return frame.module.slice(frame.module.lastIndexOf("/") + 1);
}

export interface LineStat {
  file: string;
  line: number;
  self: number;
  total: number;
}

export interface FunctionStat {
  key: string;
  frame: Frame;
  self: number;
  total: number;
  inlined: number;
  lines: Map<number, LineStat>;
}

const files = new Map<string, number>();

export function lineAdd(
  stat: FunctionStat,
  frame: Frame,
  self: number,
  total: number,
  owned: boolean,
) {
  if (!frame.file || !frame.line) return;
  let file = files.get(frame.file);
  if (file === undefined) {
    file = files.size;
    files.set(frame.file, file);
  }
  const key = file * 1_000_000 + frame.line;
  const line = stat.lines.get(key);
  if (line && owned) {
    line.self += self;
    line.total += total;
    return;
  }
  stat.lines.set(key, {
    file: frame.file,
    line: frame.line,
    self: (line?.self ?? 0) + self,
    total: (line?.total ?? 0) + total,
  });
}

export interface TreeNode {
  id: string;
  key: string;
  frame: Frame;
  total: number;
  self: number;
  depth: number;
  children: TreeNode[];
}

export const rootFrame: Frame = {
  address: "0",
  kernel: false,
  function: "all",
  file: null,
  line: null,
  module: null,
  inlined: false,
  key: "",
};

export interface TreeIndex {
  find: (id: string) => TreeNode | undefined;
  parent: (id: string) => string | undefined;
}

const indexes = new WeakMap<TreeNode, TreeIndex>();

export function indexSet(root: TreeNode, index: TreeIndex) {
  indexes.set(root, index);
}

function indexOf(root: TreeNode): TreeIndex {
  let index = indexes.get(root);
  if (index) return index;
  const byId = new Map<string, TreeNode>();
  const parentOf = new Map<string, string>();
  const stack = [root];
  while (stack.length > 0) {
    const node = stack.pop()!;
    byId.set(node.id, node);
    for (const child of node.children) {
      parentOf.set(child.id, node.id);
      stack.push(child);
    }
  }
  index = { find: (id) => byId.get(id), parent: (id) => parentOf.get(id) };
  indexes.set(root, index);
  return index;
}

export function findNode(root: TreeNode, id: string): TreeNode | null {
  const node = indexOf(root).find(id);
  return node && node.total > 0 ? node : null;
}

export function pathTo(root: TreeNode, id: string): TreeNode[] {
  const index = indexOf(root);
  if (!index.find(id)) return [root];
  const path: TreeNode[] = [];
  let at: string | undefined = id;
  while (at !== undefined) {
    const node = index.find(at);
    if (!node) break;
    path.push(node);
    at = index.parent(at);
  }
  return path.reverse();
}

export interface Neighbour {
  key: string;
  frame: Frame;
  value: number;
}

export function neighbours(
  profile: Profile,
  key: string,
): { callers: Neighbour[]; callees: Neighbour[] } {
  const callers = new Map<string, Neighbour>();
  const callees = new Map<string, Neighbour>();
  const add = (
    into: Map<string, Neighbour>,
    frame: Frame,
    value: number,
    seen: Set<string>,
  ) => {
    const k = frameKey(frame);
    if (seen.has(k)) return;
    seen.add(k);
    const entry = into.get(k);
    if (entry) entry.value += value;
    else into.set(k, { key: k, frame, value });
  };
  for (const stack of profile.stacks) {
    const seenCallers = new Set<string>();
    const seenCallees = new Set<string>();
    stack.frames.forEach((frame, index) => {
      if (frameKey(frame) !== key) return;
      const outer = stack.frames[index + 1];
      const inner = stack.frames[index - 1];
      if (outer) add(callers, outer, stack.value, seenCallers);
      if (inner) add(callees, inner, stack.value, seenCallees);
    });
  }
  const sorted = (m: Map<string, Neighbour>) =>
    [...m.values()].sort((a, b) => b.value - a.value);
  return { callers: sorted(callers), callees: sorted(callees) };
}

export function folded(profile: Profile): string {
  return profile.stacks
    .map((stack) => {
      const names = stack.frames
        .map((frame) => frameName(frame).replaceAll(";", ":"))
        .reverse();
      return `${names.join(";")} ${stack.value}`;
    })
    .join("\n");
}

export function matches(frame: Frame, query: string): boolean {
  if (!query) return false;
  const q = query.toLowerCase();
  return (
    frameName(frame).toLowerCase().includes(q) ||
    (frame.module ?? "").toLowerCase().includes(q)
  );
}
