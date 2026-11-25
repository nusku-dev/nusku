import type { ReactNode } from "react";
import { useMemo, useState } from "react";
import { Copy, Timer, X } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  frameName,
  moduleName,
  neighbours,
  type FunctionStat,
  type LineStat,
  type Neighbour,
} from "@/lib/profile/analyze";
import { formatPercent, formatSamples } from "@/lib/format";
import type { Analysis } from "./analysis";
import { frameColor, frameKind, kindLabels } from "./colors";
import type { Frame } from "@/lib/profile/types";

export function FunctionDetails({
  analysis,
  functionKey,
  onSelect,
  onTrack,
}: {
  analysis: Analysis;
  functionKey: string;
  onSelect: (key: string | null) => void;
  onTrack?: (frame: Frame) => Promise<void>;
}) {
  const stat = analysis.byKey.get(functionKey);
  const { callers, callees } = useMemo(
    () => neighbours(analysis.profile, functionKey),
    [analysis.profile, functionKey],
  );
  const total = analysis.profile.total;

  if (!stat) {
    return (
      <Panel onClose={() => onSelect(null)} title="Function">
        <p className="p-4 text-sm text-muted-foreground">
          Not in this part of the profile.
        </p>
      </Panel>
    );
  }

  const { frame } = stat;
  const name = frameName(frame);
  const kind = frameKind(frame, analysis.programModule);
  const lines = [...stat.lines.values()].sort(
    (a, b) => b.total - a.total || b.self - a.self,
  );
  const source = lines[0]?.file ?? null;

  return (
    <Panel onClose={() => onSelect(null)} title="Function">
      <div className="space-y-4 p-4">
        <div className="space-y-2">
          <div className="flex items-start gap-2">
            <span
              className="mt-1 size-2.5 shrink-0"
              style={{ background: frameColor(kind, name) }}
            />
            <h3 className="font-mono text-sm font-medium break-all">{name}</h3>
          </div>
          <div className="flex flex-wrap gap-1.5">
            <Badge variant="secondary">{kindLabels[kind]}</Badge>
            <Badge variant="outline" title={frame.module ?? undefined}>
              {moduleName(frame)}
            </Badge>
            {stat.inlined > 0 && (
              <Badge
                variant="outline"
                title="The compiler copied it into its callers: its time counts there too."
              >
                Inlined {formatPercent(stat.inlined, stat.total)}
              </Badge>
            )}
          </div>
          <dl className="space-y-1 text-xs">
            {source && <Field label="Source" value={source} />}
            {frame.module && <Field label="Module" value={frame.module} />}
          </dl>
          <Button
            variant="outline"
            size="xs"
            onClick={() => void navigator.clipboard?.writeText(name)}
          >
            <Copy /> Copy name
          </Button>
          {onTrack && !frame.kernel && frame.function && (
            <TrackButton key={functionKey} frame={frame} onTrack={onTrack} />
          )}
        </div>

        <div className="grid grid-cols-2 gap-px border bg-border">
          <Stat
            label="Self"
            value={formatPercent(stat.self, total)}
            detail={formatSamples(stat.self, analysis.profile.sampleHz)}
          />
          <Stat
            label="Total"
            value={formatPercent(stat.total, total)}
            detail={formatSamples(stat.total, analysis.profile.sampleHz)}
          />
        </div>

        <HotLines stat={stat} lines={lines} />

        <Neighbours
          title="Called by"
          items={callers}
          total={stat.total}
          onSelect={onSelect}
          empty="Nothing: it is where its stacks start."
        />
        <Neighbours
          title="Calls"
          items={callees}
          total={stat.total}
          onSelect={onSelect}
          empty="Nothing: it does all its work itself."
        />
      </div>
    </Panel>
  );
}

function HotLines({ stat, lines }: { stat: FunctionStat; lines: LineStat[] }) {
  if (lines.length === 0) {
    return (
      <section>
        <h4 className="mb-1.5 text-xs font-medium text-muted-foreground">
          Lines
        </h4>
        <p className="text-xs text-muted-foreground">
          No line info: the binary has no debug info.
        </p>
      </section>
    );
  }
  const files = new Set(lines.map((line) => line.file));
  return (
    <section>
      <h4 className="mb-1.5 flex items-baseline justify-between text-xs font-medium text-muted-foreground">
        <span>Hot lines</span>
        <span className="font-normal">self · total</span>
      </h4>
      <ul className="space-y-0.5">
        {lines.slice(0, 12).map((line) => {
          const label =
            files.size > 1
              ? `${line.file.slice(line.file.lastIndexOf("/") + 1)}:${line.line}`
              : `line ${line.line}`;
          return (
            <li
              key={`${line.file}:${line.line}`}
              className="flex items-center gap-2 px-1.5 py-0.5 text-xs"
              title={`${line.file}:${line.line}`}
            >
              <span className="min-w-0 flex-1 truncate font-mono">{label}</span>
              <span className="w-12 shrink-0 text-right tabular-nums">
                {line.self > 0 ? formatPercent(line.self, stat.total) : "—"}
              </span>
              <span className="w-12 shrink-0 text-right text-muted-foreground tabular-nums">
                {formatPercent(line.total, stat.total)}
              </span>
            </li>
          );
        })}
      </ul>
    </section>
  );
}

function Panel({
  title,
  onClose,
  children,
}: {
  title: string;
  onClose: () => void;
  children: ReactNode;
}) {
  return (
    <aside className="flex h-full w-80 shrink-0 flex-col border-l bg-background">
      <div className="flex h-9 items-center justify-between border-b pr-1 pl-4">
        <span className="text-xs font-medium tracking-wide text-muted-foreground uppercase">
          {title}
        </span>
        <Button
          variant="ghost"
          size="icon-xs"
          onClick={onClose}
          aria-label="Close"
        >
          <X />
        </Button>
      </div>
      <div className="min-h-0 flex-1 overflow-auto">{children}</div>
    </aside>
  );
}

function Field({ label, value }: { label: string; value: string }) {
  return (
    <div className="grid grid-cols-[4rem_1fr] gap-2">
      <dt className="text-muted-foreground">{label}</dt>
      <dd className="font-mono break-all">{value}</dd>
    </div>
  );
}

function Stat({
  label,
  value,
  detail,
}: {
  label: string;
  value: string;
  detail: string;
}) {
  return (
    <div className="bg-background p-3">
      <div className="text-xs text-muted-foreground">{label}</div>
      <div className="text-xl font-semibold tabular-nums">{value}</div>
      <div className="text-xs text-muted-foreground tabular-nums">{detail}</div>
    </div>
  );
}

function Neighbours({
  title,
  items,
  total,
  onSelect,
  empty,
}: {
  title: string;
  items: Neighbour[];
  total: number;
  onSelect: (key: string) => void;
  empty: string;
}) {
  return (
    <section>
      <h4 className="mb-1.5 text-xs font-medium text-muted-foreground">
        {title}
      </h4>
      {items.length === 0 ? (
        <p className="text-xs text-muted-foreground">{empty}</p>
      ) : (
        <ul className="space-y-0.5">
          {items.slice(0, 10).map((item) => (
            <li key={item.key}>
              <button
                type="button"
                onClick={() => onSelect(item.key)}
                className="flex w-full items-center gap-2 px-1.5 py-1 text-left hover:bg-muted"
              >
                <span
                  className="min-w-0 flex-1 truncate font-mono text-xs"
                  title={frameName(item.frame)}
                >
                  {frameName(item.frame)}
                </span>
                <span className="shrink-0 text-xs text-muted-foreground tabular-nums">
                  {formatPercent(item.value, total)}
                </span>
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function TrackButton({
  frame,
  onTrack,
}: {
  frame: Frame;
  onTrack: (frame: Frame) => Promise<void>;
}) {
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const track = () => {
    setBusy(true);
    setError(null);
    onTrack(frame)
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : String(e)),
      )
      .finally(() => setBusy(false));
  };
  return (
    <div className="space-y-1">
      <Button
        variant="outline"
        size="xs"
        onClick={track}
        disabled={busy}
        title="Count and time every call of this function with a probe on its entry and return"
      >
        <Timer /> {busy ? "Attaching…" : "Track calls"}
      </Button>
      {error && <p className="text-xs text-destructive">{trackError(error)}</p>}
    </div>
  );
}

function trackError(error: string): string {
  if (error === "FunctionNotFound")
    return "It has no call to probe: it is inlined, or not in its file’s symbols.";
  if (error === "FunctionAmbiguous")
    return "Its name is in more than one file.";
  if (error === "GoProgram")
    return "Go programs cannot take return probes: their runtime moves stacks.";
  if (error === "PermissionDenied")
    return "Function probes need root or CAP_SYS_ADMIN: the kernel lets nothing less open a uprobe.";
  if (error === "ProbesFull") return "Too many probes running: stop one first.";
  return error;
}
