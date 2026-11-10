import { useState, type PointerEvent } from 'react'
import { useWidth } from '@/hooks/use-width'
import { historyMs } from '@/hooks/use-machine'
import type { MachineCpu } from '@/lib/backend'
import { cpuParts as parts } from '@/lib/cpu'
import type { CpuPoint } from '@/lib/types'

const height = 200
const left = 40
const right = 12
const top = 8
const bottom = 22
const ticks = [0, 25, 50, 75, 100]

export function CpuChart({ history }: { history: CpuPoint[] }) {
  const [ref, width] = useWidth<HTMLDivElement>()
  const [hover, setHover] = useState<number | null>(null)

  const plotWidth = Math.max(0, width - left - right)
  const plotHeight = height - top - bottom
  const end = history.at(-1)?.at ?? 0
  const start = Math.max(history[0]?.at ?? 0, end - historyMs)
  const x = (at: number) => left + (plotWidth * (at - start)) / historyMs
  const since = Math.round((end - start) / 1000)
  const y = (percent: number) => top + plotHeight * (1 - Math.min(100, percent) / 100)

  const bands = parts.map((part, index) => {
    const lower = (cpu: MachineCpu) => parts.slice(0, index).reduce((sum, p) => sum + cpu[p.key], 0)
    const upper = (cpu: MachineCpu) => lower(cpu) + cpu[part.key]
    const above = history.map((p) => `${x(p.at)},${y(upper(p.cpu))}`)
    const below = history.map((p) => `${x(p.at)},${y(lower(p.cpu))}`).reverse()
    return { ...part, area: `M${above.join('L')}L${below.join('L')}Z`, edge: `M${above.join('L')}` }
  })

  const onMove = (event: PointerEvent<SVGSVGElement>) => {
    if (history.length === 0) return
    const bounds = event.currentTarget.getBoundingClientRect()
    const pointer = event.clientX - bounds.left
    let nearest = 0
    history.forEach((p, index) => {
      if (Math.abs(x(p.at) - pointer) < Math.abs(x(history[nearest].at) - pointer)) nearest = index
    })
    setHover(nearest)
  }

  const hovered = hover === null ? undefined : history[hover]

  return (
    <div ref={ref} className="relative">
      {width > 0 && (
        <svg
          width={width}
          height={height}
          role="img"
          aria-label="Machine CPU over the last minute, by state"
          onPointerMove={onMove}
          onPointerLeave={() => setHover(null)}
          className="block"
        >
          {ticks.map((tick) => (
            <g key={tick}>
              <line x1={left} x2={width - right} y1={y(tick)} y2={y(tick)} className="stroke-border" strokeWidth={1} />
              <text x={left - 8} y={y(tick)} dy="0.32em" textAnchor="end" className="fill-muted-foreground text-[10px]">
                {tick}%
              </text>
            </g>
          ))}
          {history.length > 1 &&
            bands.map((band) => (
              <g key={band.key}>
                <path d={band.area} fill={band.color} fillOpacity={0.85} />
                <path d={band.edge} fill="none" className="stroke-background" strokeWidth={2} strokeLinejoin="round" />
              </g>
            ))}
          {history.length > 1 && (
            <>
              <text x={left} y={height - 6} className="fill-muted-foreground text-[10px]">
                {since} s ago
              </text>
              <text x={Math.max(left + 56, x(end))} y={height - 6} textAnchor="end" className="fill-muted-foreground text-[10px]">
                now
              </text>
            </>
          )}
          {hovered && (
            <line
              x1={x(hovered.at)}
              x2={x(hovered.at)}
              y1={top}
              y2={top + plotHeight}
              className="stroke-foreground/50"
              strokeWidth={1}
            />
          )}
        </svg>
      )}
      {hovered && <Tooltip point={hovered} end={end} left={x(hovered.at)} width={width} />}
      {history.length < 2 && (
        <p className="absolute inset-0 grid place-items-center text-xs text-muted-foreground">Measuring…</p>
      )}
    </div>
  )
}

function Tooltip({ point, end, left: at, width }: { point: CpuPoint; end: number; left: number; width: number }) {
  const ago = Math.round((end - point.at) / 1000)
  const flip = at > width / 2
  return (
    <div
      className="pointer-events-none absolute top-2 z-10 w-44 border bg-popover p-2 text-xs text-popover-foreground shadow-md"
      style={flip ? { right: width - at + 8 } : { left: at + 8 }}
    >
      <div className="mb-1 flex justify-between text-muted-foreground">
        <span>{ago === 0 ? 'now' : `${ago} s ago`}</span>
        <span className="font-semibold text-foreground tabular-nums">{point.cpu.busy_percent.toFixed(1)}% busy</span>
      </div>
      {[...parts].reverse().map((part) => (
        <div key={part.key} className="flex items-center gap-2">
          <span className="h-0.5 w-3" style={{ background: part.color }} />
          <span className="flex-1 text-muted-foreground">{part.label}</span>
          <span className="font-medium tabular-nums">{point.cpu[part.key].toFixed(1)}%</span>
        </div>
      ))}
    </div>
  )
}
