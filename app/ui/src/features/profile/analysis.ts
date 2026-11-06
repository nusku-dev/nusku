import { useMemo } from 'react'
import { callTree, functionStats, type FunctionStat, type TreeNode } from '@/lib/profile/analyze'
import type { Profile } from '@/lib/profile/types'
import type { MetricDef } from '@/metrics/registry'

/** A profile, worked out once for every view. */
export interface Analysis {
  profile: Profile
  functions: FunctionStat[]
  byKey: Map<string, FunctionStat>
  tree: TreeNode
  /** The profiled program's own binary: the module its stacks start in most. */
  programModule: string | null
}

export function analyze(profile: Profile): Analysis {
  const functions = functionStats(profile)
  const outermost = new Map<string, number>()
  for (const stack of profile.stacks) {
    const frame = stack.frames[stack.frames.length - 1]
    if (stack.complete && frame?.module) outermost.set(frame.module, (outermost.get(frame.module) ?? 0) + stack.value)
  }
  const programModule = [...outermost.entries()].sort((a, b) => b[1] - a[1])[0]?.[0] ?? null
  return {
    profile,
    functions,
    byKey: new Map(functions.map((f) => [f.key, f])),
    tree: callTree(profile),
    programModule,
  }
}

export function useAnalysis(profile: Profile | undefined): Analysis | undefined {
  return useMemo(() => (profile ? analyze(profile) : undefined), [profile])
}

/** What every view of a profile gets. */
export interface ViewProps {
  analysis: Analysis
  metric: MetricDef
  /** Highlights matching functions; empty for none. */
  search: string
  /** The selected function's key, shown in the details panel. */
  selected: string | null
  onSelect: (key: string | null) => void
}
