import { useMemo, useState } from 'react'
import { ChevronRight, ChevronsDownUp, ChevronsUpDown } from 'lucide-react'
import { cn } from 'cn'
import { Button } from '@/components/ui/button'
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select'
import { frameName, matches, moduleName, type TreeNode } from '@/lib/profile/analyze'
import type { ViewProps } from './analysis'
import { frameColor, frameKind } from './colors'
import { ShareBar } from './ShareBar'

const cutoffs = [
  { value: '0', label: 'Show all' },
  { value: '0.5', label: 'Hide < 0.5%' },
  { value: '1', label: 'Hide < 1%' },
  { value: '5', label: 'Hide < 5%' },
]

/** Opens the branches that hold at least this share, so the hot paths show at once. */
const autoOpenShare = 0.08

function hotIds(root: TreeNode): Set<string> {
  const open = new Set<string>([root.id])
  const walk = (node: TreeNode) => {
    for (const child of node.children) {
      if (child.total / root.total >= autoOpenShare) {
        open.add(child.id)
        walk(child)
      }
    }
  }
  walk(root)
  return open
}

interface Row {
  node: TreeNode
  level: number
  hasChildren: boolean
}

/** The call tree, outermost frame first, like the CLI's: expand a row to see what it called. */
export function CallTree({ analysis, search, selected, onSelect }: ViewProps) {
  const root = analysis.tree
  const [open, setOpen] = useState<Set<string>>(() => hotIds(root))
  const [cutoff, setCutoff] = useState('0.5')
  const min = (Number(cutoff) / 100) * root.total

  const rows = useMemo(() => {
    const rows: Row[] = []
    const walk = (node: TreeNode, level: number) => {
      const kids = node.children.filter((c) => c.total >= min)
      rows.push({ node, level, hasChildren: kids.length > 0 })
      if (open.has(node.id)) for (const kid of kids) walk(kid, level + 1)
    }
    for (const child of root.children.filter((c) => c.total >= min)) walk(child, 0)
    return rows
  }, [root, open, min])

  const toggle = (id: string) =>
    setOpen((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex h-9 items-center gap-2 border-b px-3 text-xs">
        <Button variant="ghost" size="xs" onClick={() => setOpen(hotIds(root))}>
          <ChevronsUpDown /> Hot paths
        </Button>
        <Button variant="ghost" size="xs" onClick={() => setOpen(new Set([root.id]))}>
          <ChevronsDownUp /> Collapse
        </Button>
        <div className="flex-1" />
        <Select value={cutoff} onValueChange={(v) => v && setCutoff(v)} items={cutoffs}>
          <SelectTrigger size="sm" className="h-7 w-32 text-xs">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {cutoffs.map((c) => (
              <SelectItem key={c.value} value={c.value}>
                {c.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="grid grid-cols-[7rem_7rem_1fr] border-b px-3 py-2 text-xs font-medium text-muted-foreground">
        <span className="pr-4 text-right">Total</span>
        <span className="pr-4 text-right">Self</span>
        <span>Function</span>
      </div>
      <div className="min-h-0 flex-1 overflow-auto font-mono text-[12.5px]">
        {rows.map(({ node, level, hasChildren }) => {
          const name = frameName(node.frame)
          const kind = frameKind(node.frame, analysis.programModule)
          const isOpen = open.has(node.id)
          return (
            <div
              key={node.id}
              onClick={() => onSelect(node.key === selected ? null : node.key)}
              className={cn(
                'grid cursor-pointer grid-cols-[7rem_7rem_1fr] items-center px-3 py-1 hover:bg-muted/60',
                node.key === selected && 'bg-muted',
                search && matches(node.frame, search) && 'bg-primary/15',
              )}
            >
              <span className="pr-4 font-sans">
                <ShareBar value={node.total} total={root.total} tone="muted" />
              </span>
              <span className="pr-4 font-sans">
                <ShareBar value={node.self} total={root.total} />
              </span>
              <span className="flex min-w-0 items-center gap-1.5" style={{ paddingLeft: level * 14 }}>
                <button
                  type="button"
                  aria-label={isOpen ? 'Collapse' : 'Expand'}
                  onClick={(e) => {
                    e.stopPropagation()
                    if (hasChildren) toggle(node.id)
                  }}
                  className={cn('grid size-4 shrink-0 place-items-center text-muted-foreground', !hasChildren && 'invisible')}
                >
                  <ChevronRight className={cn('size-3.5 transition-transform', isOpen && 'rotate-90')} />
                </button>
                <span className="size-2 shrink-0" style={{ background: frameColor(kind, name) }} />
                <span className="truncate" title={name}>
                  {name}
                </span>
                <span className="shrink-0 font-sans text-xs text-muted-foreground">{moduleName(node.frame)}</span>
              </span>
            </div>
          )
        })}
      </div>
    </div>
  )
}
