import { useMemo, useState, type MouseEvent } from 'react'
import { ChevronRight, ZoomOut } from 'lucide-react'
import { cn } from 'cn'
import { Button } from '@/components/ui/button'
import { findNode, frameName, matches, moduleName, pathTo, type TreeNode } from '@/lib/profile/analyze'
import { formatPercent } from '@/lib/format'
import { formatValue } from '@/metrics/registry'
import { useWidth } from '@/hooks/use-width'
import type { ViewProps } from './analysis'
import { frameColor, frameKind, kindColor, kindLabels, type FrameKind } from './colors'

const rowHeight = 22
/** Beyond this many boxes the graph stops getting more detail, to stay smooth. */
const maxBoxes = 6000

interface Box {
  node: TreeNode
  x: number
  width: number
  depth: number
}

/**
 * The call tree as an icicle graph: the outermost frame on top, what it called below, and each
 * box as wide as its share. Click a box to zoom into it; the path back is above the graph.
 */
export function FlameGraph({ analysis, metric, search, selected, onSelect }: ViewProps) {
  const [zoomId, setZoomId] = useState('')
  const [hover, setHover] = useState<{ node: TreeNode; x: number; y: number } | null>(null)
  const [ref, width] = useWidth<HTMLDivElement>()

  const root = analysis.tree
  // A zoomed function can leave the profile when its range changes: then show everything.
  const zoom = findNode(root, zoomId) ?? root
  const path = pathTo(root, zoom.id)

  const { boxes, depth, byId } = useMemo(() => {
    const boxes: Box[] = []
    const byId = new Map<string, TreeNode>()
    let depth = 0
    if (width > 0 && zoom.total > 0) {
      const scale = width / zoom.total
      const place = (node: TreeNode, x: number, level: number) => {
        const w = node.total * scale
        if (w < 0.75 || boxes.length >= maxBoxes) return
        boxes.push({ node, x, width: w, depth: level })
        byId.set(node.id, node)
        depth = Math.max(depth, level)
        let cx = x
        for (const child of node.children) {
          place(child, cx, level + 1)
          cx += child.total * scale
        }
      }
      place(zoom, 0, 0)
    }
    return { boxes, depth, byId }
  }, [zoom, width])

  const matched = useMemo(() => {
    if (!search) return 0
    return analysis.profile.stacks
      .filter((stack) => stack.frames.some((frame) => matches(frame, search)))
      .reduce((sum, stack) => sum + stack.value, 0)
  }, [analysis.profile, search])

  const total = root.total
  const onMove = (event: MouseEvent<HTMLDivElement>) => {
    const target = (event.target as HTMLElement).closest<HTMLElement>('[data-id]')
    const node = target ? byId.get(target.dataset.id ?? '') : undefined
    if (!node) return setHover(null)
    const bounds = event.currentTarget.getBoundingClientRect()
    setHover({ node, x: event.clientX - bounds.left, y: event.clientY - bounds.top })
  }
  const zoomTo = (node: TreeNode) => {
    setZoomId(node.id)
    onSelect(node.id === '' ? null : node.key)
  }

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex min-h-9 items-center gap-2 border-b px-3 py-1.5 text-xs">
        <nav className="flex min-w-0 flex-1 items-center gap-0.5 overflow-hidden" aria-label="Zoom path">
          {path.map((node, i) => (
            <span key={node.id} className="flex min-w-0 items-center gap-0.5">
              {i > 0 && <ChevronRight className="size-3 shrink-0 text-muted-foreground" />}
              <button
                type="button"
                onClick={() => zoomTo(node)}
                className={cn(
                  'truncate px-1 py-0.5 font-mono hover:bg-muted',
                  i === path.length - 1 ? 'text-foreground' : 'text-muted-foreground',
                )}
              >
                {frameName(node.frame)}
              </button>
            </span>
          ))}
        </nav>
        {search && (
          <span className="shrink-0 text-muted-foreground">
            Matches <span className="font-medium text-foreground tabular-nums">{formatPercent(matched, total)}</span>
          </span>
        )}
        <Legend />
        {zoom.id !== '' && (
          <Button variant="ghost" size="xs" onClick={() => zoomTo(root)}>
            <ZoomOut /> Reset zoom
          </Button>
        )}
      </div>

      <div className="relative min-h-0 flex-1 overflow-auto">
        <div
          ref={ref}
          className="relative w-full select-none"
          style={{ height: (depth + 1) * rowHeight + 8 }}
          onMouseMove={onMove}
          onMouseLeave={() => setHover(null)}
        >
          {boxes.map(({ node, x, width: w, depth: level }) => {
            const kind = frameKind(node.frame, analysis.programModule)
            const name = frameName(node.frame)
            const dimmed = search !== '' && !matches(node.frame, search)
            return (
              <div
                key={node.id}
                data-id={node.id}
                onClick={() => zoomTo(node)}
                className={cn(
                  'absolute cursor-pointer overflow-hidden px-1 font-mono text-[11px] leading-[21px] whitespace-nowrap text-zinc-900 transition-opacity hover:brightness-95',
                  dimmed && 'opacity-25',
                  node.key === selected && 'z-10 outline-2 -outline-offset-1 outline-foreground',
                )}
                style={{
                  left: x,
                  top: level * rowHeight,
                  width: Math.max(w - 1, 0.5),
                  height: rowHeight - 1,
                  background: node.id === '' ? 'var(--muted)' : frameColor(kind, name),
                  color: node.id === '' ? 'var(--muted-foreground)' : undefined,
                }}
              >
                {w > 28 ? name : ''}
              </div>
            )
          })}
        </div>
        {hover && <Tooltip hover={hover} width={width} total={total} analysis={analysis} metric={metric} />}
      </div>
    </div>
  )
}

function Tooltip({
  hover,
  width,
  total,
  analysis,
  metric,
}: {
  hover: { node: TreeNode; x: number; y: number }
  width: number
  total: number
  analysis: ViewProps['analysis']
  metric: ViewProps['metric']
}) {
  const { node } = hover
  const kind = frameKind(node.frame, analysis.programModule)
  const left = Math.min(hover.x + 14, Math.max(0, width - 340))
  const source = node.frame.file ? `${node.frame.file}${node.frame.line ? `:${node.frame.line}` : ''}` : null
  return (
    <div
      className="pointer-events-none absolute z-20 w-80 border bg-popover p-3 text-xs text-popover-foreground shadow-lg"
      style={{ left, top: hover.y + 16 }}
    >
      <div className="font-mono text-[12px] font-medium break-all">{frameName(node.frame)}</div>
      <div className="mt-1 flex items-center gap-1.5 text-muted-foreground">
        <span className="size-2 shrink-0" style={{ background: kindColor(kind) }} />
        {kindLabels[kind]} · {moduleName(node.frame)}
      </div>
      {source && <div className="mt-0.5 truncate font-mono text-muted-foreground">{source}</div>}
      <dl className="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 tabular-nums">
        <dt className="text-muted-foreground">{metric.totalLabel}</dt>
        <dd>
          <span className="font-medium">{formatPercent(node.total, total)}</span>{' '}
          <span className="text-muted-foreground">{formatValue(metric, node.total, analysis.profile)}</span>
        </dd>
        <dt className="text-muted-foreground">{metric.selfLabel}</dt>
        <dd>
          <span className="font-medium">{formatPercent(node.self, total)}</span>{' '}
          <span className="text-muted-foreground">{formatValue(metric, node.self, analysis.profile)}</span>
        </dd>
      </dl>
    </div>
  )
}

function Legend() {
  const kinds: FrameKind[] = ['app', 'library', 'kernel', 'unknown']
  return (
    <div className="hidden shrink-0 items-center gap-3 text-muted-foreground lg:flex">
      {kinds.map((kind) => (
        <span key={kind} className="flex items-center gap-1">
          <span className="size-2" style={{ background: kindColor(kind) }} />
          {kindLabels[kind]}
        </span>
      ))}
    </div>
  )
}
