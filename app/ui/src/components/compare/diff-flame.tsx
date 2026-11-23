import { useMemo, useState, type MouseEvent } from "react";
import { ChevronRight, ZoomOut } from "lucide-react";
import { cn } from "cn";
import { Button } from "@/components/ui/button";
import { useWidth } from "@/hooks/use-width";
import { frameName, moduleName } from "@/lib/profile/analyze";
import {
  changeOf,
  type Change,
  type DiffNode,
  type Measure,
  type Side,
} from "@/lib/profile/compare";
import { diffColor, idleColor } from "@/components/profile/colors";
import { formatChange, formatMeasure } from "./format";

const rowHeight = 22;
const maxBoxes = 6000;

export type Shape = "after" | "before";

interface Box {
  node: DiffNode;
  path: DiffNode[];
  x: number;
  width: number;
  depth: number;
}

export interface DiffFlameProps {
  tree: DiffNode;
  before: Side;
  after: Side;
  measure: Measure;
  shape: Shape;
  onShapeChange: (shape: Shape) => void;
  onSelect: (key: string) => void;
}

export function DiffFlame({
  tree,
  before,
  after,
  measure,
  shape,
  onShapeChange,
  onSelect,
}: DiffFlameProps) {
  const [zoomPath, setZoomPath] = useState<string[]>([]);
  const [hover, setHover] = useState<{
    node: DiffNode;
    x: number;
    y: number;
  } | null>(null);
  const [ref, width] = useWidth<HTMLDivElement>();
  const change = (node: DiffNode) =>
    changeOf(node.a, node.b, before, after, measure);

  const path = useMemo(() => {
    const found = [tree];
    for (const id of zoomPath) {
      const next = found[found.length - 1].children.find((c) => c.id === id);
      if (!next) break;
      found.push(next);
    }
    return found;
  }, [tree, zoomPath]);
  const zoom = path[path.length - 1];

  const { boxes, depth, byId, largest } = useMemo(() => {
    const boxes: Box[] = [];
    const byId = new Map<string, Box>();
    let depth = 0;
    let largest = 0;
    const total = shape === "after" ? zoom.b : zoom.a;
    if (width > 0 && total > 0) {
      const scale = width / total;
      const place = (
        node: DiffNode,
        trail: DiffNode[],
        x: number,
        level: number,
      ) => {
        const w = (shape === "after" ? node.b : node.a) * scale;
        if (w < 0.75 || boxes.length >= maxBoxes) return;
        const box = { node, path: trail, x, width: w, depth: level };
        boxes.push(box);
        byId.set(node.id, box);
        depth = Math.max(depth, level);
        const c = changeOf(node.a, node.b, before, after, measure);
        if (!c.noise && level > 0)
          largest = Math.max(largest, Math.abs(c.delta));
        let cx = x;
        for (const child of node.children) {
          place(child, [...trail, child], cx, level + 1);
          cx += (shape === "after" ? child.b : child.a) * scale;
        }
      };
      place(zoom, [], 0, 0);
    }
    return { boxes, depth, byId, largest };
  }, [zoom, width, shape, before, after, measure]);

  const onMove = (event: MouseEvent<HTMLDivElement>) => {
    const target = (event.target as HTMLElement).closest<HTMLElement>(
      "[data-id]",
    );
    const box = target ? byId.get(target.dataset.id ?? "") : undefined;
    if (!box) return setHover(null);
    const bounds = event.currentTarget.getBoundingClientRect();
    setHover({
      node: box.node,
      x: event.clientX - bounds.left,
      y: event.clientY - bounds.top,
    });
  };
  const zoomTo = (ids: string[]) => setZoomPath(ids);

  return (
    <div className="flex h-full min-h-0 flex-col">
      <div className="flex min-h-9 items-center gap-2 border-b px-3 py-1.5 text-xs">
        <nav
          className="flex min-w-0 flex-1 items-center gap-0.5 overflow-hidden"
          aria-label="Zoom path"
        >
          {path.map((node, i) => (
            <span key={node.id} className="flex min-w-0 items-center gap-0.5">
              {i > 0 && (
                <ChevronRight className="size-3 shrink-0 text-muted-foreground" />
              )}
              <button
                type="button"
                onClick={() => zoomTo(zoomPath.slice(0, i))}
                className={cn(
                  "truncate px-1 py-0.5 font-mono hover:bg-muted",
                  i === path.length - 1
                    ? "text-foreground"
                    : "text-muted-foreground",
                )}
              >
                {frameName(node.frame)}
              </button>
            </span>
          ))}
        </nav>
        <ShapeSwitch value={shape} onChange={onShapeChange} />
        <Legend />
        {zoomPath.length > 0 && (
          <Button variant="ghost" size="xs" onClick={() => zoomTo([])}>
            <ZoomOut /> Reset zoom
          </Button>
        )}
      </div>
      <div className="relative min-h-0 flex-1 overflow-auto">
        <div
          ref={ref}
          className="relative w-full overflow-hidden select-none"
          style={{ height: (depth + 1) * rowHeight + 8 }}
          onMouseMove={onMove}
          onMouseLeave={() => setHover(null)}
        >
          {boxes.map(({ node, path: trail, x, width: w, depth: level }) => {
            const c = change(node);
            const name = frameName(node.frame);
            return (
              <div
                key={node.id}
                data-id={node.id}
                onClick={() => {
                  zoomTo([...zoomPath, ...trail.map((n) => n.id)]);
                  if (node.key) onSelect(node.key);
                }}
                className={cn(
                  "absolute cursor-pointer overflow-hidden px-1 font-mono text-[11px] leading-5.25 whitespace-nowrap text-zinc-900 hover:brightness-95",
                  node.frame.inlined && "italic",
                )}
                style={{
                  left: x,
                  top: level * rowHeight,
                  width: Math.max(w - 1, 0.5),
                  height: rowHeight - 1,
                  background:
                    level === 0
                      ? "var(--muted)"
                      : diffColor(c.delta, c.noise, largest),
                  color: level === 0 ? "var(--muted-foreground)" : undefined,
                }}
              >
                {w > 28 ? name : ""}
              </div>
            );
          })}
        </div>
        {hover && (
          <Tooltip
            node={hover.node}
            change={change(hover.node)}
            x={hover.x}
            y={hover.y}
            width={width}
            measure={measure}
          />
        )}
      </div>
    </div>
  );
}

function Tooltip({
  node,
  change,
  x,
  y,
  width,
  measure,
}: {
  node: DiffNode;
  change: Change;
  x: number;
  y: number;
  width: number;
  measure: Measure;
}) {
  const left = Math.min(x + 14, Math.max(0, width - 340));
  return (
    <div
      className="pointer-events-none absolute z-20 w-80 border bg-popover p-3 text-xs text-popover-foreground shadow-lg"
      style={{ left, top: y + 16 }}
    >
      <div className="font-mono text-[12px] font-medium break-all">
        {frameName(node.frame)}
      </div>
      <div className="mt-1 text-muted-foreground">{moduleName(node.frame)}</div>
      <dl className="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 tabular-nums">
        <dt className="text-muted-foreground">Before</dt>
        <dd>{formatMeasure(change.before, measure)}</dd>
        <dt className="text-muted-foreground">After</dt>
        <dd>{formatMeasure(change.after, measure)}</dd>
        <dt className="text-muted-foreground">Change</dt>
        <dd className="font-medium">{formatChange(change, measure)}</dd>
      </dl>
      <p className="mt-2 text-muted-foreground">
        Time on the stack: this frame and everything it called.
      </p>
    </div>
  );
}

function ShapeSwitch({
  value,
  onChange,
}: {
  value: Shape;
  onChange: (shape: Shape) => void;
}) {
  const options: { id: Shape; label: string; hint: string }[] = [
    {
      id: "after",
      label: "After",
      hint: "Draw the second run; paths that are gone do not show",
    },
    {
      id: "before",
      label: "Before",
      hint: "Draw the first run; paths that are new do not show",
    },
  ];
  return (
    <div
      className="flex shrink-0 items-center gap-0.5 border p-0.5"
      role="radiogroup"
      aria-label="Shape"
    >
      {options.map((o) => (
        <button
          key={o.id}
          type="button"
          role="radio"
          aria-checked={value === o.id}
          title={o.hint}
          onClick={() => onChange(o.id)}
          className={cn(
            "px-2 py-0.5 text-muted-foreground hover:text-foreground",
            value === o.id && "bg-muted text-foreground",
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

function Legend() {
  const items = [
    { label: "Less time", color: diffColor(-1, false, 1) },
    { label: "Noise", color: idleColor },
    { label: "More time", color: diffColor(1, false, 1) },
  ];
  return (
    <div className="hidden shrink-0 items-center gap-3 text-muted-foreground lg:flex">
      {items.map((item) => (
        <span key={item.label} className="flex items-center gap-1">
          <span className="size-2" style={{ background: item.color }} />
          {item.label}
        </span>
      ))}
    </div>
  );
}
