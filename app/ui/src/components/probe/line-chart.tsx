import { useState, type PointerEvent } from "react";
import { useWidth } from "@/hooks/use-width";

export interface Series {
  key: string;
  label: string;
  color: string;
  values: (number | null)[];
  step?: boolean;
}

const height = 180;
const left = 56;
const top = 10;
const bottom = 22;

function niceMax(value: number): number {
  if (value <= 0) return 1;
  const power = 10 ** Math.floor(Math.log10(value));
  for (const step of [1, 2, 2.5, 5, 10])
    if (step * power >= value) return step * power;
  return 10 * power;
}

export function LineChart({
  label,
  times,
  series,
  format,
}: {
  label: string;
  times: number[];
  series: Series[];
  format: (value: number) => string;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const [hover, setHover] = useState<number | null>(null);
  const labelled = series.length > 1;
  const right = labelled ? 64 : 12;
  const plotWidth = Math.max(0, width - left - right);
  const plotHeight = height - top - bottom;
  const start = times[0] ?? 0;
  const end = times.at(-1) ?? 0;
  const span = Math.max(end - start, 1);
  const max = niceMax(
    Math.max(0, ...series.flatMap((s) => s.values.map((v) => v ?? 0))),
  );
  const x = (at: number) => left + (plotWidth * (at - start)) / span;
  const y = (value: number) => top + plotHeight * (1 - value / max);
  const ticks = [0, 0.5, 1].map((f) => f * max);

  const pathOf = (values: (number | null)[], step: boolean) => {
    let d = "";
    let open = false;
    values.forEach((value, i) => {
      if (value === null) {
        open = false;
        return;
      }
      const px = x(times[i]).toFixed(1);
      const py = y(value).toFixed(1);
      if (!open) d += `M${px},${py}`;
      else if (step) d += `V${py}H${px}`;
      else d += `L${px},${py}`;
      open = true;
    });
    return d;
  };

  const onMove = (event: PointerEvent<SVGSVGElement>) => {
    if (times.length === 0) return;
    const pointer =
      event.clientX - event.currentTarget.getBoundingClientRect().left;
    let nearest = 0;
    times.forEach((t, i) => {
      if (Math.abs(x(t) - pointer) < Math.abs(x(times[nearest]) - pointer))
        nearest = i;
    });
    setHover(nearest);
  };

  const lastOf = (values: (number | null)[]) => {
    for (let i = values.length - 1; i >= 0; i--)
      if (values[i] !== null) return i;
    return -1;
  };

  return (
    <div>
      {labelled && (
        <div className="mb-1.5 flex items-center gap-4 text-xs text-muted-foreground">
          {series.map((s) => (
            <span key={s.key} className="flex items-center gap-1.5">
              <span className="h-0.5 w-3" style={{ background: s.color }} />
              {s.label}
            </span>
          ))}
        </div>
      )}
      <div ref={ref} className="relative">
        {width > 0 && (
          <svg
            width={width}
            height={height}
            role="img"
            aria-label={label}
            onPointerMove={onMove}
            onPointerLeave={() => setHover(null)}
            className="block"
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
                  {format(tick)}
                </text>
              </g>
            ))}
            {times.length > 1 &&
              series.map((s) => (
                <path
                  key={s.key}
                  d={pathOf(s.values, s.step ?? false)}
                  fill="none"
                  stroke={s.color}
                  strokeWidth={2}
                  strokeLinejoin="round"
                  strokeLinecap="round"
                />
              ))}
            {labelled &&
              times.length > 1 &&
              series.map((s) => {
                const i = lastOf(s.values);
                if (i < 0) return null;
                return (
                  <text
                    key={s.key}
                    x={x(times[i]) + 6}
                    y={y(s.values[i]!)}
                    dy="0.32em"
                    className="fill-muted-foreground text-[10px]"
                  >
                    {s.label}
                  </text>
                );
              })}
            {times.length > 1 && (
              <>
                <text
                  x={left}
                  y={height - 6}
                  className="fill-muted-foreground text-[10px]"
                >
                  {Math.round((end - start) / 1000)} s ago
                </text>
                <text
                  x={left + plotWidth}
                  y={height - 6}
                  textAnchor="end"
                  className="fill-muted-foreground text-[10px]"
                >
                  now
                </text>
              </>
            )}
            {hover !== null && times[hover] !== undefined && (
              <>
                <line
                  x1={x(times[hover])}
                  x2={x(times[hover])}
                  y1={top}
                  y2={top + plotHeight}
                  className="stroke-foreground/50"
                  strokeWidth={1}
                />
                {series.map((s) =>
                  s.values[hover] === null ? null : (
                    <circle
                      key={s.key}
                      cx={x(times[hover])}
                      cy={y(s.values[hover]!)}
                      r={4}
                      fill={s.color}
                      className="stroke-background"
                      strokeWidth={2}
                    />
                  ),
                )}
              </>
            )}
          </svg>
        )}
        {hover !== null && times[hover] !== undefined && (
          <div
            className="pointer-events-none absolute top-1 z-10 w-48 border bg-popover p-2 text-xs text-popover-foreground shadow-md"
            style={
              x(times[hover]) > width / 2
                ? { right: width - x(times[hover]) + 8 }
                : { left: x(times[hover]) + 8 }
            }
          >
            <div className="mb-1 text-muted-foreground">
              {Math.round((end - times[hover]) / 1000)} s ago
            </div>
            {series.map((s) => (
              <div key={s.key} className="flex items-center gap-2">
                <span className="h-0.5 w-3" style={{ background: s.color }} />
                <span className="flex-1 text-muted-foreground">{s.label}</span>
                <span className="font-medium tabular-nums">
                  {s.values[hover] === null ? "—" : format(s.values[hover]!)}
                </span>
              </div>
            ))}
          </div>
        )}
        {times.length < 2 && (
          <p className="absolute inset-0 grid place-items-center text-xs text-muted-foreground">
            Collecting…
          </p>
        )}
      </div>
    </div>
  );
}
