import { useState, type PointerEvent } from 'react'
import { X } from 'lucide-react'
import { Button } from '@/components/ui/button'
import { formatDuration } from '@/lib/format'
import type { MetricId, Window, WindowRange } from '@/lib/profile/types'
import { useWidth } from '@/hooks/use-width'

const height = 56

/**
 * The session over time, one bar per report window. Drag across it to look at just that span;
 * every view below then shows that span only.
 */
export function Timeline({
  windows,
  metric,
  range,
  onRangeChange,
  format,
}: {
  windows: Window[]
  metric: MetricId
  range: WindowRange | null
  onRangeChange: (range: WindowRange | null) => void
  /** A window's value as text, for the hover label. */
  format: (value: number) => string
}) {
  const [ref, width] = useWidth<HTMLDivElement>()
  const [drag, setDrag] = useState<{ start: number; end: number } | null>(null)
  const [hover, setHover] = useState<number | null>(null)

  const values = windows.map((w) => w.values[metric] ?? 0)
  const max = Math.max(1, ...values)
  const step = windows.length > 0 ? width / windows.length : 0
  const gap = step > 4 ? 1 : 0

  const indexAt = (event: PointerEvent<HTMLDivElement>) => {
    const bounds = event.currentTarget.getBoundingClientRect()
    const i = Math.floor(((event.clientX - bounds.left) / bounds.width) * windows.length)
    return Math.min(windows.length - 1, Math.max(0, i))
  }

  const shown = drag ? { from: Math.min(drag.start, drag.end), to: Math.max(drag.start, drag.end) } : range
  const spanText = (r: WindowRange) =>
    `${formatDuration(windows[r.from]?.startMs ?? 0)} – ${formatDuration((windows[r.to]?.startMs ?? 0) + (windows[r.to]?.durationMs ?? 0))}`

  return (
    <div className="space-y-1.5">
      <div className="flex h-6 items-center justify-between text-xs text-muted-foreground">
        <span>
          {hover !== null && windows[hover] ? (
            <>
              <span className="tabular-nums">{formatDuration(windows[hover].startMs)}</span>
              <span className="mx-1.5">·</span>
              <span className="font-medium text-foreground tabular-nums">{format(values[hover])}</span>
            </>
          ) : shown ? (
            <>
              Showing <span className="font-medium text-foreground tabular-nums">{spanText(shown)}</span>
            </>
          ) : (
            'Drag across the timeline to look at part of the run'
          )}
        </span>
        {range && !drag && (
          <Button variant="ghost" size="xs" onClick={() => onRangeChange(null)}>
            <X /> Whole run
          </Button>
        )}
      </div>
      <div
        ref={ref}
        className="relative cursor-crosshair touch-none bg-muted/40 select-none"
        style={{ height }}
        onPointerDown={(e) => {
          if (windows.length === 0) return
          e.currentTarget.setPointerCapture(e.pointerId)
          const i = indexAt(e)
          setDrag({ start: i, end: i })
        }}
        onPointerMove={(e) => {
          if (windows.length === 0) return
          const i = indexAt(e)
          setHover(i)
          if (drag) setDrag({ ...drag, end: i })
        }}
        onPointerUp={() => {
          if (!drag) return
          const from = Math.min(drag.start, drag.end)
          const to = Math.max(drag.start, drag.end)
          setDrag(null)
          // A click without a drag clears the selection rather than picking one window.
          onRangeChange(from === to ? null : { from, to })
        }}
        onPointerLeave={() => setHover(null)}
      >
        <svg width={width} height={height} className="block">
          {values.map((v, i) => {
            const h = Math.max(1, (v / max) * (height - 4))
            const inside = !shown || (i >= shown.from && i <= shown.to)
            return (
              <rect
                key={i}
                x={i * step}
                y={height - h}
                width={Math.max(0.5, step - gap)}
                height={h}
                className={inside ? 'fill-primary' : 'fill-muted-foreground/30'}
                opacity={hover === i ? 1 : 0.85}
              />
            )
          })}
        </svg>
        {windows.length === 0 && (
          <div className="absolute inset-0 grid place-items-center text-xs text-muted-foreground">Waiting for the first report…</div>
        )}
      </div>
    </div>
  )
}
