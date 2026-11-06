// The ways to look at a profile. A metric lists the ones it gets in metrics/registry.ts.
// A new view: write a component that takes ViewProps, add it here, and name it in a metric.

import type { ComponentType } from 'react'
import type { LucideIcon } from 'lucide-react'
import { Flame, ListOrdered, ListTree } from 'lucide-react'
import type { ViewId } from '@/metrics/registry'
import type { ViewProps } from './analysis'
import { CallTree } from './CallTree'
import { FlameGraph } from './FlameGraph'
import { TopFunctions } from './TopFunctions'

export interface ViewDef {
  label: string
  icon: LucideIcon
  /** One line, as the view switcher's tooltip. */
  hint: string
  component: ComponentType<ViewProps>
}

export const views: Record<ViewId, ViewDef> = {
  flame: {
    label: 'Flame graph',
    icon: Flame,
    hint: 'Every call path at once, as wide as its share. Click to zoom in.',
    component: FlameGraph,
  },
  top: {
    label: 'Top functions',
    icon: ListOrdered,
    hint: 'The functions that took the most, by self or total.',
    component: TopFunctions,
  },
  tree: {
    label: 'Call tree',
    icon: ListTree,
    hint: 'Who called what, from the outermost frame in.',
    component: CallTree,
  },
}
