import { useEffect, useMemo, useState } from "react";
import {
  ArrowLeft,
  ArrowLeftRight,
  Search,
  TriangleAlert,
  X,
} from "lucide-react";
import { cn } from "cn";
import { DiffFlame, type Shape } from "@/components/compare/diff-flame";
import { formatChange, formatMeasure } from "@/components/compare/format";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { backend, type CompactWire, type RunMeta } from "@/lib/backend";
import { formatClock, formatInt } from "@/lib/format";
import { frameName, moduleName } from "@/lib/profile/analyze";
import {
  changeOf,
  compare,
  diffTree,
  type Change,
  type FunctionDiff,
  type Measure,
  type Side,
} from "@/lib/profile/compare";
import { profileOf } from "@/lib/profile/wire";
import { Routes, useRoute } from "@/lib/router";

type Loaded = { meta: RunMeta; side: Side };
type By = "self" | "total";

const rowsMax = 300;

function sideOf(wire: CompactWire): Side {
  return { profile: profileOf(wire), hz: wire.sample_hz };
}

export function ComparePage({ a, b }: { a: number; b: number }) {
  const route = useRoute();
  const back = route.nav(Routes.runs).href();
  const [runs, setRuns] = useState<[Loaded, Loaded] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    Promise.all([backend.runsGet(a), backend.runsGet(b)])
      .then(([x, y]) => {
        if (alive)
          setRuns([
            { meta: x.meta, side: sideOf(x.profile) },
            { meta: y.meta, side: sideOf(y.profile) },
          ]);
      })
      .catch(
        (e: unknown) =>
          alive && setError(e instanceof Error ? e.message : String(e)),
      );
    return () => {
      alive = false;
    };
  }, [a, b]);

  if (!runs) {
    return (
      <div className="grid h-full place-items-center text-center">
        <div>
          <p className="font-medium">
            {error ? "These runs cannot be compared" : "Loading…"}
          </p>
          {error && (
            <p className="mt-1 text-sm text-muted-foreground">{error}</p>
          )}
          <Button
            className="mt-4"
            variant="outline"
            nativeButton={false}
            render={<a href={back} />}
          >
            <ArrowLeft /> Saved runs
          </Button>
        </div>
      </div>
    );
  }
  return <Comparison before={runs[0]} after={runs[1]} back={back} />;
}

function Comparison({
  before,
  after,
  back,
}: {
  before: Loaded;
  after: Loaded;
  back: string;
}) {
  const route = useRoute();
  const [measure, setMeasure] = useState<Measure>("time");
  const [by, setBy] = useState<By>("self");
  const [search, setSearch] = useState("");
  const [focus, setFocus] = useState<string | null>(null);
  const [shape, setShape] = useState<Shape>("after");

  const comparison = useMemo(
    () => compare(before.side.profile, after.side.profile),
    [before, after],
  );
  const tree = useMemo(
    () => diffTree(before.side.profile, after.side.profile, focus),
    [before, after, focus],
  );
  const total = changeOf(
    before.side.profile.total,
    after.side.profile.total,
    before.side,
    after.side,
    measure,
  );
  const rows = useMemo(() => {
    const q = search.trim().toLowerCase();
    return comparison.functions
      .filter(
        (f) =>
          !q ||
          frameName(f.frame).toLowerCase().includes(q) ||
          moduleName(f.frame).toLowerCase().includes(q),
      )
      .map((f) => ({
        f,
        change: changeOf(f.a[by], f.b[by], before.side, after.side, measure),
      }))
      .filter((row) => row.change.before > 0 || row.change.after > 0)
      .sort(
        (x, y) =>
          Number(x.change.noise) - Number(y.change.noise) ||
          Math.abs(y.change.delta) - Math.abs(x.change.delta),
      )
      .slice(0, rowsMax);
  }, [comparison, by, search, before, after, measure]);

  const swap = () =>
    route
      .nav(Routes.compare, {
        params: { 0: String(after.meta.id), 1: String(before.meta.id) },
      })
      .go();
  const sameProgram = before.meta.program === after.meta.program;
  const focused = focus ? comparison.byKey.get(focus) : undefined;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="flex h-14 shrink-0 items-center gap-3 border-b px-4">
        <Button
          variant="ghost"
          size="icon-sm"
          nativeButton={false}
          render={<a href={back} aria-label="Saved runs" />}
        >
          <ArrowLeft />
        </Button>
        <div className="flex min-w-0 flex-1 items-center gap-2 text-base font-semibold tracking-tight">
          <span className="truncate">{before.meta.label}</span>
          <span className="shrink-0 text-muted-foreground">→</span>
          <span className="truncate">{after.meta.label}</span>
        </div>
        <Button
          variant="outline"
          onClick={swap}
          title="Make the second run the first"
        >
          <ArrowLeftRight /> Swap
        </Button>
      </header>

      <div className="flex flex-wrap items-center gap-x-8 gap-y-2 border-b px-6 py-2.5">
        <Stat
          label="Before"
          value={totalText(before, total.before, measure)}
          hint={runHint(before.meta)}
        />
        <Stat
          label="After"
          value={totalText(after, total.after, measure)}
          hint={runHint(after.meta)}
        />
        {measure === "time" && (
          <Stat
            label="Change"
            value={formatChange(total, measure)}
            tone={tone(total)}
          />
        )}
        {!sameProgram && (
          <p className="flex items-center gap-1.5 text-xs text-amber-600 dark:text-amber-400">
            <TriangleAlert className="size-3.5" /> Different programs:{" "}
            {before.meta.program} and {after.meta.program}
          </p>
        )}
        {measure === "time" &&
          before.meta.elapsed_ms !== 0 &&
          Math.abs(before.meta.elapsed_ms - after.meta.elapsed_ms) /
            before.meta.elapsed_ms >
            0.2 && (
            <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
              <TriangleAlert className="size-3.5" /> The runs lasted{" "}
              {formatClock(before.meta.elapsed_ms)} and{" "}
              {formatClock(after.meta.elapsed_ms)}: for a fixed workload compare
              CPU time, otherwise share of run
            </p>
          )}
      </div>

      <div className="flex h-11 items-center gap-3 border-b px-6 text-xs">
        <Switch
          label="Measure"
          value={measure}
          onChange={setMeasure}
          options={[
            {
              id: "time",
              label: "CPU time",
              hint: "Seconds on the CPU: right when both runs did the same work",
            },
            {
              id: "share",
              label: "Share of run",
              hint: "Percent of each run: right when the runs lasted different times",
            },
          ]}
        />
        <Switch
          label="By"
          value={by}
          onChange={setBy}
          options={[
            {
              id: "self",
              label: "Self",
              hint: "Time in the function’s own code",
            },
            {
              id: "total",
              label: "Total",
              hint: "Time in the function and everything it called",
            },
          ]}
        />
        {focused && (
          <span className="flex min-w-0 items-center gap-1 border bg-muted/50 py-0.5 pr-1 pl-2">
            <span className="truncate">
              Inside{" "}
              <span className="font-mono">{frameName(focused.frame)}</span>
            </span>
            <button
              type="button"
              aria-label="Show the whole run"
              onClick={() => setFocus(null)}
              className="text-muted-foreground hover:text-foreground"
            >
              <X className="size-3.5" />
            </button>
          </span>
        )}
        <div className="flex-1" />
        <div className="relative w-72">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search functions or modules"
            className="h-8 pl-8 text-xs"
          />
        </div>
      </div>

      <div className="grid min-h-0 flex-1 grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
        <div className="min-h-0 overflow-auto border-r">
          <DiffTable
            rows={rows}
            measure={measure}
            selected={focus}
            onSelect={setFocus}
          />
        </div>
        <div className="min-h-0">
          <DiffFlame
            key={focus ?? ""}
            tree={tree}
            before={before.side}
            after={after.side}
            measure={measure}
            shape={shape}
            onShapeChange={setShape}
            onSelect={setFocus}
          />
        </div>
      </div>
    </div>
  );
}

function DiffTable({
  rows,
  measure,
  selected,
  onSelect,
}: {
  rows: { f: FunctionDiff; change: Change }[];
  measure: Measure;
  selected: string | null;
  onSelect: (key: string) => void;
}) {
  if (rows.length === 0)
    return (
      <p className="p-8 text-center text-sm text-muted-foreground">
        No function to compare.
      </p>
    );
  return (
    <table className="w-full table-fixed border-collapse text-xs">
      <thead className="sticky top-0 z-10 bg-background text-muted-foreground">
        <tr className="border-b">
          <th className="px-4 py-2 text-left font-medium">Function</th>
          <th className="w-24 px-2 py-2 text-right font-medium">Before</th>
          <th className="w-24 px-2 py-2 text-right font-medium">After</th>
          <th className="w-44 px-4 py-2 text-right font-medium">Change</th>
        </tr>
      </thead>
      <tbody>
        {rows.map(({ f, change }) => (
          <tr
            key={f.key}
            onClick={() => onSelect(f.key)}
            className={cn(
              "cursor-pointer border-b border-border/60 hover:bg-muted/50",
              selected === f.key && "bg-muted",
              change.noise && "text-muted-foreground",
            )}
          >
            <td className="truncate px-4 py-1.5" title={frameName(f.frame)}>
              <span className="font-mono">{frameName(f.frame)}</span>
              <span className="ml-2 text-muted-foreground">
                {moduleName(f.frame)}
              </span>
            </td>
            <td className="px-2 py-1.5 text-right tabular-nums">
              {formatMeasure(change.before, measure)}
            </td>
            <td className="px-2 py-1.5 text-right tabular-nums">
              {formatMeasure(change.after, measure)}
            </td>
            <td
              className={cn(
                "px-4 py-1.5 text-right font-medium tabular-nums",
                toneClass(tone(change)),
              )}
            >
              {formatChange(change, measure)}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

type Tone = "better" | "worse" | "same";

function tone(change: Change): Tone {
  if (change.noise) return "same";
  return change.delta < 0 ? "better" : "worse";
}

function toneClass(t: Tone): string {
  if (t === "better") return "text-emerald-600 dark:text-emerald-400";
  if (t === "worse") return "text-red-600 dark:text-red-400";
  return "text-muted-foreground font-normal";
}

function totalText(run: Loaded, value: number, measure: Measure): string {
  if (measure === "time") return formatMeasure(value, measure);
  return `${formatInt(run.side.profile.total)} samples`;
}

function runHint(meta: RunMeta): string {
  return `${formatClock(meta.elapsed_ms)} · ${formatInt(meta.samples)} samples · ${new Date(meta.saved_unix_ms).toLocaleString()}`;
}

function Stat({
  label,
  value,
  hint,
  tone: t,
}: {
  label: string;
  value: string;
  hint?: string;
  tone?: Tone;
}) {
  return (
    <div className="min-w-0" title={hint}>
      <div className="text-[11px] tracking-wide text-muted-foreground uppercase">
        {label}
      </div>
      <div
        className={cn("text-sm font-medium tabular-nums", t && toneClass(t))}
      >
        {value}
      </div>
    </div>
  );
}

function Switch<T extends string>({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: T;
  onChange: (value: T) => void;
  options: { id: T; label: string; hint: string }[];
}) {
  return (
    <div className="flex items-center gap-1.5">
      <span className="text-muted-foreground">{label}</span>
      <div
        className="flex items-center gap-0.5 border p-0.5"
        role="radiogroup"
        aria-label={label}
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
    </div>
  );
}
