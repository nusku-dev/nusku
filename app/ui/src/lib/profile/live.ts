import {
  frameKey,
  indexSet,
  lineAdd,
  pathId,
  rootFrame,
  type FunctionStat,
  type TreeNode,
} from "./analyze";
import { goSwitch, type ModuleGap, type Quality } from "./quality";
import type { Frame, Profile, Stack } from "./types";

interface Cell {
  id: string;
  key: string;
  frame: Frame;
  depth: number;
  total: number;
  self: number;
  byKey: Map<string, Cell>;
  view: TreeNode;
  round: number;
  parent: Cell | null;
}

export interface Change {
  before?: Stack;
  after?: Stack;
}

export interface Engine {
  stacks: Map<number, Stack>;
  incomplete: number;
  goSwitch: number;
  unnamed: number;
  gaps: Map<string, ModuleGap>;
  stats: Map<string, FunctionStat>;
  root: Cell;
  cells: Map<string, Cell>;
  outermost: Map<string, number>;
  round: number;
}

export interface Result {
  functions: FunctionStat[];
  byKey: Map<string, FunctionStat>;
  tree: TreeNode;
  programModule: string | null;
  quality: Quality;
}

function cell(
  id: string,
  key: string,
  frame: Frame,
  depth: number,
  parent: Cell | null,
): Cell {
  const view = { id, key, frame, total: 0, self: 0, depth, children: [] };
  return {
    id,
    key,
    frame,
    depth,
    total: 0,
    self: 0,
    byKey: new Map(),
    view,
    round: 0,
    parent,
  };
}

export function engineCreate(): Engine {
  const root = cell("", "", rootFrame, 0, null);
  return {
    stacks: new Map(),
    incomplete: 0,
    goSwitch: 0,
    unnamed: 0,
    gaps: new Map(),
    stats: new Map(),
    root,
    cells: new Map([["", root]]),
    outermost: new Map(),
    round: 0,
  };
}

export function engineApply(engine: Engine, profile: Profile): Result {
  const changes: Change[] = [];
  const seen = new Set<number>();
  for (const after of profile.stacks) {
    seen.add(after.id);
    const before = engine.stacks.get(after.id);
    if (before?.value !== after.value) changes.push({ before, after });
  }
  for (const before of engine.stacks.values()) {
    if (!seen.has(before.id)) changes.push({ before });
  }
  return engineUpdate(engine, changes, profile);
}

export function engineUpdate(
  engine: Engine,
  changes: Change[],
  profile: Profile,
): Result {
  engine.round += 1;
  const changed: Cell[][] = [];
  const copied = new Map<string, boolean>();
  for (const { before, after } of changes) {
    const delta = (after?.value ?? 0) - (before?.value ?? 0);
    const stack = after ?? before;
    if (stack && delta !== 0) stackAdd(engine, stack, delta, changed, copied);
    if (after && after.value > 0) engine.stacks.set(after.id, after);
    else if (before) engine.stacks.delete(before.id);
  }

  for (let depth = changed.length - 1; depth >= 0; depth--) {
    for (const at of changed[depth] ?? []) cellView(at);
  }
  const cells = engine.cells;
  indexSet(engine.root.view, {
    find: (id) => cells.get(id)?.view,
    parent: (id) => cells.get(id)?.parent?.id,
  });

  const functions = [...engine.stats.values()]
    .filter((f) => f.total > 0)
    .sort((a, b) => b.self - a.self || b.total - a.total);
  const outer = [...engine.outermost.entries()]
    .filter((e) => e[1] > 0)
    .sort((a, b) => b[1] - a[1]);
  const quality: Quality = {
    samples: engine.root.total,
    incomplete: engine.incomplete,
    goSwitch: engine.goSwitch,
    unnamed: engine.unnamed,
    lost: profile.lost,
    rejected: profile.rejected,
    modules: [...engine.gaps.values()]
      .filter((g) => g.unnamed > 0 || g.noLines > 0)
      .map((g) => ({ ...g }))
      .sort((a, b) => b.unnamed - a.unnamed || b.noLines - a.noLines),
  };
  return {
    functions,
    byKey: new Map(engine.stats),
    tree: engine.root.view,
    programModule: outer[0]?.[0] ?? null,
    quality,
  };
}

function cellView(at: Cell) {
  const kept: Cell[] = [];
  for (const child of at.byKey.values()) if (child.total > 0) kept.push(child);
  if (kept.length > 1) kept.sort((a, b) => b.total - a.total);
  const children: TreeNode[] = new Array(kept.length);
  for (let i = 0; i < kept.length; i++) children[i] = kept[i].view;
  at.view = {
    id: at.id,
    key: at.key,
    frame: at.frame,
    total: at.total,
    self: at.self,
    depth: at.depth,
    children,
  };
}

const vdso = "[vdso]";

function qualityAdd(engine: Engine, stack: Stack, delta: number) {
  if (goSwitch(stack)) engine.goSwitch += delta;
  else if (!stack.complete) engine.incomplete += delta;
  if (stack.frames[0] && !stack.frames[0].function) engine.unnamed += delta;
  const counted = new Set<string>();
  for (const frame of stack.frames) {
    if (frame.kernel || !frame.module || frame.module === vdso) continue;
    const missingName = !frame.function;
    if (!missingName && frame.file) continue;
    const key = `${missingName ? "n" : "l"}${frame.module}`;
    if (counted.has(key)) continue;
    counted.add(key);
    let gap = engine.gaps.get(frame.module);
    if (!gap) {
      gap = { module: frame.module, unnamed: 0, noLines: 0 };
      engine.gaps.set(frame.module, gap);
    }
    if (missingName) gap.unnamed += delta;
    else gap.noLines += delta;
  }
}

function mark(engine: Engine, at: Cell, changed: Cell[][]) {
  if (at.round === engine.round) return;
  at.round = engine.round;
  let bucket = changed[at.depth];
  if (!bucket) {
    bucket = [];
    changed[at.depth] = bucket;
  }
  bucket.push(at);
}

function stackAdd(
  engine: Engine,
  stack: Stack,
  delta: number,
  changed: Cell[][],
  copied: Map<string, boolean>,
) {
  qualityAdd(engine, stack, delta);
  const seen = new Set<string>();
  const frames = stack.frames;
  for (let index = 0; index < frames.length; index++) {
    const frame = frames[index];
    const key = frame.key || frameKey(frame);
    let stat = engine.stats.get(key);
    if (!stat) {
      stat = { key, frame, self: 0, total: 0, inlined: 0, lines: new Map() };
      engine.stats.set(key, stat);
      copied.set(key, true);
    } else if (!copied.has(key)) {
      stat = { ...stat };
      engine.stats.set(key, stat);
      copied.set(key, false);
    }
    const self = index === 0 ? delta : 0;
    stat.self += self;
    const first = !seen.has(key);
    if (first) {
      stat.total += delta;
      if (frame.inlined) stat.inlined += delta;
      seen.add(key);
    }
    lineAdd(stat, frame, self, first ? delta : 0, copied.get(key) === true);
  }

  let at = engine.root;
  at.total += delta;
  mark(engine, at, changed);
  for (let i = stack.frames.length - 1; i >= 0; i--) {
    const frame = stack.frames[i];
    const key = frame.key || frameKey(frame);
    let child = at.byKey.get(key);
    if (!child) {
      child = cell(pathId(at.id, key), key, frame, at.depth + 1, at);
      at.byKey.set(key, child);
      engine.cells.set(child.id, child);
    }
    child.total += delta;
    mark(engine, child, changed);
    at = child;
  }
  at.self += delta;

  const outer = stack.frames[stack.frames.length - 1];
  if (stack.complete && outer?.module) {
    engine.outermost.set(
      outer.module,
      (engine.outermost.get(outer.module) ?? 0) + delta,
    );
  }
}
