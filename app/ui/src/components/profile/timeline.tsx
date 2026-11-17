import { useState, type PointerEvent } from "react";
import { X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useWidth } from "@/hooks/use-width";
import { formatClock, formatInt } from "@/lib/format";
import { inRange } from "@/lib/profile/range";
import type { Range, Window } from "@/lib/profile/types";

const height = 64;

export function Timeline({
  windows,
  running,
  range,
  onRangeChange,
}: {
  windows: Window[];
  running: boolean;
  range: Range | null;
  onRangeChange: (range: Range | null) => void;
}) {
  const [ref, width] = useWidth<HTMLDivElement>();
  const [drag, setDrag] = useState<{ start: number; end: number } | null>(null);
  const [hover, setHover] = useState<number | null>(null);

  const rates = windows.map((w) =>
    w.durationMs > 0 ? (w.samples * 1000) / w.durationMs : 0,
  );
  const max = Math.max(1, ...rates);
  const step = windows.length > 0 ? width / windows.length : 0;
  const gap = step > 4 ? 1 : 0;
  const origin = windows[0]?.startMs ?? 0;

  const indexAt = (event: PointerEvent<HTMLDivElement>) => {
    const bounds = event.currentTarget.getBoundingClientRect();
    const i = Math.floor(
      ((event.clientX - bounds.left) / bounds.width) * windows.length,
    );
    return Math.min(windows.length - 1, Math.max(0, i));
  };

  const middle = (i: number) => windows[i].startMs + windows[i].durationMs / 2;
  const picked = drag
    ? {
        fromMs: middle(Math.min(drag.start, drag.end)),
        toMs: middle(Math.max(drag.start, drag.end)),
      }
    : range;
  const chosen = picked ? windows.filter((w) => inRange(w, picked)) : [];
  const at = (ms: number) => formatClock(Math.max(0, ms - origin));

  return (
    <div className="space-y-1.5">
      <div className="flex h-6 items-center justify-between text-xs text-muted-foreground">
        <span>
          {hover !== null && windows[hover] ? (
            <>
              <span className="tabular-nums">{at(windows[hover].startMs)}</span>
              <span className="mx-1.5">·</span>
              <span className="font-medium text-foreground tabular-nums">
                {formatInt(windows[hover].samples)} samples
              </span>
              <span className="ml-1.5 tabular-nums">
                ({formatInt(rates[hover])}/s)
              </span>
            </>
          ) : chosen.length > 0 ? (
            <>
              Showing{" "}
              <span className="font-medium text-foreground tabular-nums">
                {at(chosen[0].startMs)} –{" "}
                {at(
                  chosen[chosen.length - 1].startMs +
                    chosen[chosen.length - 1].durationMs,
                )}
              </span>
              <span className="ml-1.5 tabular-nums">
                · {formatInt(chosen.reduce((sum, w) => sum + w.samples, 0))}{" "}
                samples
              </span>
            </>
          ) : (
            "Samples per report. Drag across to look at part of the run."
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
          if (windows.length === 0) return;
          e.currentTarget.setPointerCapture(e.pointerId);
          const i = indexAt(e);
          setDrag({ start: i, end: i });
        }}
        onPointerMove={(e) => {
          if (windows.length === 0) return;
          const i = indexAt(e);
          setHover(i);
          if (drag) setDrag({ ...drag, end: i });
        }}
        onPointerUp={() => {
          if (!drag) return;
          const from = Math.min(drag.start, drag.end);
          const to = Math.max(drag.start, drag.end);
          setDrag(null);
          onRangeChange(
            from === to ? null : { fromMs: middle(from), toMs: middle(to) },
          );
        }}
        onPointerLeave={() => setHover(null)}
      >
        <svg width={width} height={height} className="block">
          {windows.map((w, i) => {
            const h = Math.max(1, (rates[i] / max) * (height - 4));
            const inside = !picked || inRange(w, picked);
            return (
              <rect
                key={w.startMs}
                x={i * step}
                y={height - h}
                width={Math.max(0.5, step - gap)}
                height={h}
                fill={inside ? "var(--chart-1)" : "var(--muted-foreground)"}
                opacity={inside ? (hover === i ? 1 : 0.9) : 0.3}
              />
            );
          })}
        </svg>
        {windows.length === 0 && (
          <div className="absolute inset-0 grid place-items-center text-xs text-muted-foreground">
            {running ? "Waiting for the first report…" : "No reports kept"}
          </div>
        )}
      </div>
      {windows.length > 0 && (
        <div className="flex justify-between text-[11px] text-muted-foreground tabular-nums">
          <span>{at(origin)}</span>
          <span>
            {at(
              windows[windows.length - 1].startMs +
                windows[windows.length - 1].durationMs,
            )}
          </span>
        </div>
      )}
    </div>
  );
}
