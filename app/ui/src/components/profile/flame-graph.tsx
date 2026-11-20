import { useMemo, useState, type MouseEvent } from "react";
import { ChevronRight, ZoomOut } from "lucide-react";
import { cn } from "cn";
import { Button } from "@/components/ui/button";
import {
  findNode,
  frameName,
  matches,
  moduleName,
  pathTo,
  type TreeNode,
} from "@/lib/profile/analyze";
import { formatPercent, formatSamples } from "@/lib/format";
import { useWidth } from "@/hooks/use-width";
import type { ViewProps } from "./analysis";
import {
  frameColor,
  frameKind,
  heatColor,
  idleColor,
  kindColor,
  kindLabels,
  type ColorBy,
  type FrameKind,
} from "./colors";

const rowHeight = 22;

const maxBoxes = 6000;

interface Box {
  node: TreeNode;
  x: number;
  width: number;
  depth: number;
}

export function FlameGraph({
  analysis,
  search,
  selected,
  onSelect,
}: ViewProps) {
  const [zoomId, setZoomId] = useState("");
  const [colorBy, setColorBy] = useState<ColorBy>("kind");
  const [hover, setHover] = useState<{
    node: TreeNode;
    x: number;
    y: number;
  } | null>(null);
  const [ref, width] = useWidth<HTMLDivElement>();

  const root = analysis.tree;
  const zoom = findNode(root, zoomId) ?? root;
  const path = pathTo(root, zoom.id);

  const { boxes, depth, byId } = useMemo(() => {
    const boxes: Box[] = [];
    const byId = new Map<string, TreeNode>();
    let depth = 0;
    if (width > 0 && zoom.total > 0) {
      const scale = width / zoom.total;
      const place = (node: TreeNode, x: number, level: number) => {
        const w = node.total * scale;
        if (w < 0.75 || boxes.length >= maxBoxes) return;
        boxes.push({ node, x, width: w, depth: level });
        byId.set(node.id, node);
        depth = Math.max(depth, level);
        let cx = x;
        for (const child of node.children) {
          place(child, cx, level + 1);
          cx += child.total * scale;
        }
      };
      place(zoom, 0, 0);
    }
    return { boxes, depth, byId };
  }, [zoom, width]);

  const matched = useMemo(() => {
    if (!search) return 0;
    return analysis.profile.stacks
      .filter((stack) => stack.frames.some((frame) => matches(frame, search)))
      .reduce((sum, stack) => sum + stack.value, 0);
  }, [analysis.profile, search]);

  const hottest = useMemo(
    () => analysis.functions.reduce((max, f) => Math.max(max, f.self), 0),
    [analysis.functions],
  );
  const colorOf = (node: TreeNode, kind: FrameKind, name: string) => {
    if (colorBy === "kind") return frameColor(kind, name);
    return heatColor(analysis.byKey.get(node.key)?.self ?? 0, hottest);
  };

  const total = root.total;
  const onMove = (event: MouseEvent<HTMLDivElement>) => {
    const target = (event.target as HTMLElement).closest<HTMLElement>(
      "[data-id]",
    );
    const node = target ? byId.get(target.dataset.id ?? "") : undefined;
    if (!node) return setHover(null);
    const bounds = event.currentTarget.getBoundingClientRect();
    setHover({
      node,
      x: event.clientX - bounds.left,
      y: event.clientY - bounds.top,
    });
  };
  const zoomTo = (node: TreeNode) => {
    setZoomId(node.id);
    onSelect(node.id === "" ? null : node.key);
  };

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
                onClick={() => zoomTo(node)}
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
        {search && (
          <span className="shrink-0 text-muted-foreground">
            Matches{" "}
            <span className="font-medium text-foreground tabular-nums">
              {formatPercent(matched, total)}
            </span>
          </span>
        )}
        <ColorSwitch value={colorBy} onChange={setColorBy} />
        {colorBy === "kind" ? <Legend /> : <HeatLegend />}
        {zoom.id !== "" && (
          <Button variant="ghost" size="xs" onClick={() => zoomTo(root)}>
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
          {boxes.map(({ node, x, width: w, depth: level }) => {
            const kind = frameKind(node.frame, analysis.programModule);
            const name = frameName(node.frame);
            const dimmed = search !== "" && !matches(node.frame, search);
            return (
              <div
                key={node.id}
                data-id={node.id}
                onClick={() => zoomTo(node)}
                className={cn(
                  "absolute cursor-pointer overflow-hidden px-1 font-mono text-[11px] leading-5.25 whitespace-nowrap text-zinc-900 transition-opacity hover:brightness-95",
                  dimmed && "opacity-25",
                  node.frame.inlined && "italic",
                  node.key === selected &&
                    "z-10 outline-2 -outline-offset-1 outline-foreground",
                )}
                style={{
                  left: x,
                  top: level * rowHeight,
                  width: Math.max(w - 1, 0.5),
                  height: rowHeight - 1,
                  background:
                    node.id === "" ? "var(--muted)" : colorOf(node, kind, name),
                  color: node.id === "" ? "var(--muted-foreground)" : undefined,
                }}
              >
                {w > 28 ? name : ""}
              </div>
            );
          })}
        </div>
        {hover && (
          <Tooltip
            hover={hover}
            width={width}
            total={total}
            analysis={analysis}
          />
        )}
      </div>
    </div>
  );
}

function Tooltip({
  hover,
  width,
  total,
  analysis,
}: {
  hover: { node: TreeNode; x: number; y: number };
  width: number;
  total: number;
  analysis: ViewProps["analysis"];
}) {
  const { node } = hover;
  const kind = frameKind(node.frame, analysis.programModule);
  const left = Math.min(hover.x + 14, Math.max(0, width - 340));
  const source = node.frame.file;
  return (
    <div
      className="pointer-events-none absolute z-20 w-80 border bg-popover p-3 text-xs text-popover-foreground shadow-lg"
      style={{ left, top: hover.y + 16 }}
    >
      <div className="font-mono text-[12px] font-medium break-all">
        {frameName(node.frame)}
      </div>
      <div className="mt-1 flex items-center gap-1.5 text-muted-foreground">
        <span
          className="size-2 shrink-0"
          style={{ background: kindColor(kind) }}
        />
        {kindLabels[kind]} · {moduleName(node.frame)}
        {node.frame.inlined && " · inlined"}
      </div>
      {source && (
        <div className="mt-0.5 truncate font-mono text-muted-foreground">
          {source}
        </div>
      )}
      <dl className="mt-2 grid grid-cols-[auto_1fr] gap-x-3 gap-y-0.5 tabular-nums">
        <dt className="text-muted-foreground">Total</dt>
        <dd>
          <span className="font-medium">
            {formatPercent(node.total, total)}
          </span>{" "}
          <span className="text-muted-foreground">
            {formatSamples(node.total, analysis.profile.sampleHz)}
          </span>
        </dd>
        <dt className="text-muted-foreground">Self</dt>
        <dd>
          <span className="font-medium">{formatPercent(node.self, total)}</span>{" "}
          <span className="text-muted-foreground">
            {formatSamples(node.self, analysis.profile.sampleHz)}
          </span>
        </dd>
      </dl>
    </div>
  );
}

function ColorSwitch({
  value,
  onChange,
}: {
  value: ColorBy;
  onChange: (value: ColorBy) => void;
}) {
  const options: { id: ColorBy; label: string; hint: string }[] = [
    {
      id: "kind",
      label: "Kind",
      hint: "Colour by the kind of code: program, library, kernel",
    },
    {
      id: "self",
      label: "Self time",
      hint: "Colour by the time each function spends in its own code",
    },
  ];
  return (
    <div
      className="flex shrink-0 items-center gap-0.5 border p-0.5"
      role="radiogroup"
      aria-label="Colour by"
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
            "px-2 py-0.5 text-muted-foreground transition-colors hover:text-foreground",
            value === o.id && "bg-muted text-foreground",
          )}
        >
          {o.label}
        </button>
      ))}
    </div>
  );
}

function HeatLegend() {
  const steps = [0.02, 0.1, 0.3, 0.6, 1];
  return (
    <div className="hidden shrink-0 items-center gap-2 text-muted-foreground lg:flex">
      <span className="flex items-center gap-1">
        <span className="size-2" style={{ background: idleColor }} />
        None
      </span>
      <span className="flex items-center gap-1">
        Low
        <span className="flex">
          {steps.map((s) => (
            <span
              key={s}
              className="h-2 w-3"
              style={{ background: heatColor(s, 1) }}
            />
          ))}
        </span>
        High
      </span>
    </div>
  );
}

function Legend() {
  const kinds: FrameKind[] = ["app", "library", "kernel", "unknown"];
  return (
    <div className="hidden shrink-0 items-center gap-3 text-muted-foreground lg:flex">
      {kinds.map((kind) => (
        <span key={kind} className="flex items-center gap-1">
          <span className="size-2" style={{ background: kindColor(kind) }} />
          {kindLabels[kind]}
        </span>
      ))}
    </div>
  );
}
