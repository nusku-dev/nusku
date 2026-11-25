import { useState } from "react";
import { useWidth } from "@/hooks/use-width";
import { formatInt, formatNs, formatPercent } from "@/lib/format";
import { bucketLow } from "@/lib/probe";

const height = 180;
const left = 56;
const right = 12;
const top = 10;
const bottom = 22;
const gap = 2;
const radius = 4;

function barPath(x: number, y: number, w: number, h: number): string {
  const r = Math.min(radius, w / 2, h);
  return `M${x},${y + h}V${y + r}Q${x},${y} ${x + r},${y}H${x + w - r}Q${x + w},${y} ${x + w},${y + r}V${y + h}Z`;
}

export function HistogramChart({
  histogram,
  timed,
}: {
  histogram: number[];
  timed: number;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const used = histogram.flatMap((count, bucket) =>
    count > 0 ? [bucket] : [],
  );
  return (
    <div ref={ref} className="relative">
      {used.length === 0 ? (
        <p className="grid h-45 place-items-center text-xs text-muted-foreground">
          No call has returned yet.
        </p>
      ) : (
        <Bars histogram={histogram} timed={timed} used={used} width={width} />
      )}
    </div>
  );
}

function Bars({
  histogram,
  timed,
  used,
  width,
}: {
  histogram: number[];
  timed: number;
  used: number[];
  width: number;
}) {
  const [hover, setHover] = useState<number | null>(null);
  const first = used[0];
  const last = used[used.length - 1];
  const shown = Array.from({ length: last - first + 1 }, (_, i) => first + i);
  const largest = Math.max(...shown.map((b) => histogram[b]));
  const plotWidth = Math.max(0, width - left - right);
  const plotHeight = height - top - bottom;
  const step = plotWidth / shown.length;
  const y = (count: number) => top + plotHeight * (1 - count / largest);
  const labelEvery = Math.max(
    1,
    Math.ceil(shown.length / Math.max(1, Math.floor(plotWidth / 70))),
  );
  const ticks = [0, 0.5, 1].map((f) => Math.round(f * largest));
  const hovered = hover === null ? null : shown[hover];

  return (
    <>
      {width > 0 && (
        <svg
          width={width}
          height={height}
          role="img"
          aria-label="Calls by time per call"
          className="block"
          onPointerLeave={() => setHover(null)}
        >
          {ticks.map((tick) => (
            <g key={tick}>
              <line
                x1={left}
                x2={left + plotWidth}
                y1={y(tick)}
                y2={y(tick)}
                className="stroke-border"
                strokeWidth={1}
              />
              <text
                x={left - 8}
                y={y(tick)}
                dy="0.32em"
                textAnchor="end"
                className="fill-muted-foreground text-[10px]"
              >
                {formatInt(tick)}
              </text>
            </g>
          ))}
          {shown.map((bucket, i) => {
            const count = histogram[bucket];
            const x = left + i * step + gap / 2;
            const w = Math.max(1, step - gap);
            return (
              <g key={bucket} onPointerEnter={() => setHover(i)}>
                <rect
                  x={left + i * step}
                  y={top}
                  width={step}
                  height={plotHeight}
                  fill="transparent"
                />
                {count > 0 && (
                  <path
                    d={barPath(x, y(count), w, top + plotHeight - y(count))}
                    fill="var(--chart-1)"
                    fillOpacity={hover === null || hover === i ? 1 : 0.55}
                  />
                )}
                {i % labelEvery === 0 && (
                  <text
                    x={left + i * step}
                    y={height - 6}
                    className="fill-muted-foreground text-[10px]"
                  >
                    {formatNs(bucketLow(bucket))}
                  </text>
                )}
              </g>
            );
          })}
        </svg>
      )}
      {hovered !== null && hover !== null && (
        <div
          className="pointer-events-none absolute top-1 z-10 w-48 border bg-popover p-2 text-xs text-popover-foreground shadow-md"
          style={
            left + hover * step > width / 2
              ? { right: width - left - hover * step + 8 }
              : { left: left + (hover + 1) * step + 8 }
          }
        >
          <div className="text-muted-foreground">
            {formatNs(bucketLow(hovered))} – {formatNs(bucketLow(hovered + 1))}
          </div>
          <div className="mt-1 font-medium tabular-nums">
            {formatInt(histogram[hovered])} calls ·{" "}
            {formatPercent(histogram[hovered], timed)}
          </div>
        </div>
      )}
    </>
  );
}
