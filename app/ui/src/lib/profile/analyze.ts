// Turns a profile's stacks into what the views show: per-function totals, the call tree,
// callers and callees, and the folded text for flame graph tools. Nothing here knows which
// metric it is: a stack's value can be samples, nanoseconds or bytes.

import type { Frame, Profile } from './types'

/** Names one function in one module: the same function name in two binaries is two functions. */
export function frameKey(frame: Frame): string {
  return `${frameName(frame)}\u0000${frame.module ?? ''}`
}

export function frameName(frame: Frame): string {
  return frame.function ?? `0x${frame.address}`
}

/** The last part of a module path: `/usr/lib/libc.so.6` is `libc.so.6`. */
export function moduleName(frame: Frame): string {
  if (frame.kernel) return 'kernel'
  if (!frame.module) return 'unknown'
  return frame.module.slice(frame.module.lastIndexOf('/') + 1)
}

export interface FunctionStat {
  key: string
  frame: Frame
  /** Value of the stacks where it was the innermost frame: it was the one running. */
  self: number
  /** Value of the stacks it was anywhere in: itself and everything it called. */
  total: number
}

/** Every function in the profile, most self first. */
export function functionStats(profile: Profile): FunctionStat[] {
  const stats = new Map<string, FunctionStat>()
  for (const stack of profile.stacks) {
    const seen = new Set<string>() // recursion counts once per stack
    stack.frames.forEach((frame, index) => {
      const key = frameKey(frame)
      let stat = stats.get(key)
      if (!stat) {
        stat = { key, frame, self: 0, total: 0 }
        stats.set(key, stat)
      }
      if (index === 0) stat.self += stack.value
      if (!seen.has(key)) {
        stat.total += stack.value
        seen.add(key)
      }
    })
  }
  return [...stats.values()].sort((a, b) => b.self - a.self || b.total - a.total)
}

export interface TreeNode {
  /** The path of keys from the root: stable while the profile grows, so UI state can key on it. */
  id: string
  key: string
  frame: Frame
  total: number
  self: number
  depth: number
  /** Biggest first. */
  children: TreeNode[]
}

const rootFrame: Frame = {
  address: '0',
  kernel: false,
  function: 'all',
  file: null,
  line: null,
  module: null,
}

/** The call tree, outermost frame first. Its root is a synthetic "all" node. */
export function callTree(profile: Profile): TreeNode {
  type Building = TreeNode & { byKey: Map<string, Building> }
  const make = (id: string, key: string, frame: Frame, depth: number): Building => ({
    id,
    key,
    frame,
    total: 0,
    self: 0,
    depth,
    children: [],
    byKey: new Map(),
  })
  const root = make('', '', rootFrame, 0)

  for (const stack of profile.stacks) {
    let node = root
    node.total += stack.value
    for (let i = stack.frames.length - 1; i >= 0; i--) {
      const frame = stack.frames[i]
      const key = frameKey(frame)
      let child = node.byKey.get(key)
      if (!child) {
        child = make(`${node.id}>${key}`, key, frame, node.depth + 1)
        node.byKey.set(key, child)
      }
      child.total += stack.value
      node = child
    }
    node.self += stack.value
  }

  const finish = (node: Building): TreeNode => {
    const children = [...node.byKey.values()].sort((a, b) => b.total - a.total).map(finish)
    return { id: node.id, key: node.key, frame: node.frame, total: node.total, self: node.self, depth: node.depth, children }
  }
  return finish(root)
}

export function findNode(root: TreeNode, id: string): TreeNode | null {
  if (root.id === id) return root
  if (!id.startsWith(root.id)) return null
  for (const child of root.children) {
    const found = findNode(child, id)
    if (found) return found
  }
  return null
}

/** The nodes from the root down to `id`, both included. */
export function pathTo(root: TreeNode, id: string): TreeNode[] {
  const path: TreeNode[] = []
  let node: TreeNode | undefined = root
  while (node) {
    path.push(node)
    if (node.id === id) return path
    node = node.children.find((child) => id.startsWith(child.id + '>') || id === child.id)
  }
  return [root]
}

export interface Neighbour {
  key: string
  frame: Frame
  value: number
}

/** Who calls the function, and what it calls, each with the value of the stacks they share. */
export function neighbours(profile: Profile, key: string): { callers: Neighbour[]; callees: Neighbour[] } {
  const callers = new Map<string, Neighbour>()
  const callees = new Map<string, Neighbour>()
  const add = (into: Map<string, Neighbour>, frame: Frame, value: number, seen: Set<string>) => {
    const k = frameKey(frame)
    if (seen.has(k)) return
    seen.add(k)
    const entry = into.get(k)
    if (entry) entry.value += value
    else into.set(k, { key: k, frame, value })
  }
  for (const stack of profile.stacks) {
    const seenCallers = new Set<string>()
    const seenCallees = new Set<string>()
    stack.frames.forEach((frame, index) => {
      if (frameKey(frame) !== key) return
      const outer = stack.frames[index + 1]
      const inner = stack.frames[index - 1]
      if (outer) add(callers, outer, stack.value, seenCallers)
      if (inner) add(callees, inner, stack.value, seenCallees)
    })
  }
  const sorted = (m: Map<string, Neighbour>) => [...m.values()].sort((a, b) => b.value - a.value)
  return { callers: sorted(callers), callees: sorted(callees) }
}

/** One line per stack, `outer;...;inner value`: what FlameGraph, inferno and speedscope read. */
export function folded(profile: Profile): string {
  return profile.stacks
    .map((stack) => {
      const names = stack.frames.map((frame) => frameName(frame).replaceAll(';', ':')).reverse()
      return `${names.join(';')} ${stack.value}`
    })
    .join('\n')
}

/** Whether a function's name or module matches a search, ignoring case. */
export function matches(frame: Frame, query: string): boolean {
  if (!query) return false
  const q = query.toLowerCase()
  return frameName(frame).toLowerCase().includes(q) || (frame.module ?? '').toLowerCase().includes(q)
}
