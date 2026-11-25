import { useMemo, useState } from "react";
import { ArrowLeft, Square, Table2, TriangleAlert } from "lucide-react";
import { HistogramChart } from "@/components/probe/histogram-chart";
import { LineChart } from "@/components/probe/line-chart";
import { LiveDot } from "@/components/session-status";
import { Button } from "@/components/ui/button";
import { useProbe, type ProbeView } from "@/hooks/use-probe";
import { useProbes } from "@/hooks/use-probes";
import type { ProbeListed } from "@/lib/backend";
import { formatInt, formatNs } from "@/lib/format";
import {
  busyCallsPerS,
  figuresOf,
  intervalsOf,
  shortCallNs,
  type ProbeFigures,
} from "@/lib/probe";
import { Routes, useRoute } from "@/lib/router";

export function ProbePage({ job }: { job: number }) {
  const { view, error } = useProbe(job);
  const { probes, stop } = useProbes();
  const listed = probes.find((p) => p.job === job);
  const back = useRoute().nav(Routes.sessions).href();
  const [stopping, setStopping] = useState(false);
  const [stopError, setStopError] = useState<string | null>(null);

  if (!view) {
    return (
      <div className="grid h-full place-items-center text-center">
        <div>
          <p className="font-medium">
            {error ? "This probe cannot be read" : "Loading…"}
          </p>
          {error && (
            <p className="mt-1 text-sm text-muted-foreground">
              {error.message}
            </p>
          )}
          <Button
            className="mt-4"
            variant="outline"
            nativeButton={false}
            render={<a href={back} />}
          >
            <ArrowLeft /> Sessions
          </Button>
        </div>
      </div>
    );
  }

  const running = listed ? listed.running : !view.finished;
  const onStop = () => {
    setStopping(true);
    stop(job)
      .catch((e: unknown) =>
        setStopError(e instanceof Error ? e.message : String(e)),
      )
      .finally(() => setStopping(false));
  };
  const path = view.info?.path ?? "";

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <header className="flex h-14 shrink-0 items-center gap-3 border-b px-4">
        <Button
          variant="ghost"
          size="icon-sm"
          nativeButton={false}
          render={<a href={back} aria-label="Sessions" />}
        >
          <ArrowLeft />
        </Button>
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-2.5">
            <h1 className="truncate font-mono text-base font-semibold tracking-tight">
              {view.info?.function ?? "…"}
            </h1>
            <span className="text-sm text-muted-foreground tabular-nums">
              pid {view.info?.pid}
            </span>
            <ProbeStatus running={running} listed={listed} />
          </div>
          <p
            className="truncate font-mono text-xs text-muted-foreground"
            title={path}
          >
            {path}
          </p>
        </div>
        {stopError && (
          <span className="text-xs text-destructive">{stopError}</span>
        )}
        {running && (
          <Button
            variant="destructive"
            onClick={onStop}
            disabled={stopping}
            title="Detach the probe; the process goes on"
          >
            <Square className="fill-current" />{" "}
            {stopping ? "Stopping…" : "Stop"}
          </Button>
        )}
      </header>
      <div className="min-h-0 flex-1 overflow-auto">
        <ProbeBody view={view} elapsedMs={listed?.elapsed_ms ?? 0} />
      </div>
    </div>
  );
}

function ProbeStatus({
  running,
  listed,
}: {
  running: boolean;
  listed: ProbeListed | undefined;
}) {
  if (running) {
    return (
      <span className="flex items-center gap-1.5 text-xs text-muted-foreground">
        <LiveDot /> Live
      </span>
    );
  }
  const text = listed?.failure
    ? `Failed: ${listed.failure}`
    : listed?.reason === "target_exited"
      ? "Process exited"
      : listed?.reason === "duration"
        ? "Duration reached"
        : "Stopped";
  return <span className="text-xs text-muted-foreground">{text}</span>;
}

function ProbeBody({
  view,
  elapsedMs,
}: {
  view: ProbeView;
  elapsedMs: number;
}) {
  const [table, setTable] = useState(false);
  const figures = useMemo(() => figuresOf(view.points), [view.points]);
  const intervals = useMemo(() => intervalsOf(view.points), [view.points]);
  const times = intervals.map((i) => i.atMs);

  return (
    <div className="space-y-5 p-6">
      <Tiles figures={figures} elapsedMs={elapsedMs} />
      <Notes figures={figures} view={view} />
      <div className="grid gap-5 xl:grid-cols-2">
        <Card title="Calls per second">
          <LineChart
            label="Calls per second over time"
            times={times}
            series={[
              {
                key: "rate",
                label: "Calls per second",
                color: "var(--chart-1)",
                values: intervals.map((i) => i.callsPerS),
              },
            ]}
            format={(v) => formatInt(Math.round(v))}
          />
        </Card>
        <Card title="Time per call">
          <LineChart
            label="Mean and p99 time per call over time"
            times={times}
            series={[
              {
                key: "mean",
                label: "Mean",
                color: "var(--chart-1)",
                values: intervals.map((i) => i.meanNs),
              },
              {
                key: "p99",
                label: "p99 ≤",
                color: "var(--chart-2)",
                values: intervals.map((i) => i.p99Ns),
                step: true,
              },
            ]}
            format={formatNs}
          />
        </Card>
      </div>
      <Card
        title="Time per call, whole run"
        hint="Each bar holds the calls that took between a time and twice it."
      >
        <HistogramChart histogram={figures.histogram} timed={figures.timed} />
      </Card>
      <div>
        <Button
          variant="outline"
          size="sm"
          onClick={() => setTable((last) => !last)}
        >
          <Table2 /> {table ? "Hide the table" : "Show as a table"}
        </Button>
        {table && <IntervalTable intervals={intervals} />}
      </div>
    </div>
  );
}

function Tiles({
  figures: f,
  elapsedMs,
}: {
  figures: ProbeFigures;
  elapsedMs: number;
}) {
  const share = elapsedMs > 0 ? (f.totalNs / 1e6 / elapsedMs) * 100 : null;
  const tiles = [
    { label: "Calls", value: formatInt(f.calls) },
    {
      label: "Calls per second",
      value: f.callsPerS === null ? "—" : formatInt(Math.round(f.callsPerS)),
      hint: "Over the last interval",
    },
    { label: "Mean", value: f.meanNs === null ? "—" : formatNs(f.meanNs) },
    {
      label: "p50",
      value: f.p50Ns === null ? "—" : `≤ ${formatNs(f.p50Ns)}`,
      hint: "Half the calls took at most this",
    },
    {
      label: "p99",
      value: f.p99Ns === null ? "—" : `≤ ${formatNs(f.p99Ns)}`,
      hint: "All but 1 in 100 calls took at most this",
    },
    { label: "Slowest", value: f.timed > 0 ? formatNs(f.maxNs) : "—" },
    {
      label: "Time inside",
      value: f.timed > 0 ? formatNs(f.totalNs) : "—",
      hint:
        share === null
          ? undefined
          : `${share.toFixed(1)}% of the time probed, all threads together`,
    },
  ];
  return (
    <div className="grid grid-cols-2 gap-3 sm:grid-cols-4 xl:grid-cols-7">
      {tiles.map((t) => (
        <div key={t.label} className="border p-3" title={t.hint}>
          <div className="text-[11px] tracking-wide text-muted-foreground uppercase">
            {t.label}
          </div>
          <div className="mt-1 text-lg font-semibold tabular-nums">
            {t.value}
          </div>
        </div>
      ))}
    </div>
  );
}

function Notes({
  figures: f,
  view,
}: {
  figures: ProbeFigures;
  view: ProbeView;
}) {
  const notes: string[] = [];
  if (f.meanNs !== null && f.meanNs < shortCallNs) {
    notes.push(
      "Calls this short are mostly the probe’s own cost, about 1–4 µs each: compare them between two runs, not as times of their own.",
    );
  }
  if (f.callsPerS !== null && f.callsPerS > busyCallsPerS) {
    notes.push(
      `${formatInt(Math.round(f.callsPerS))} calls a second: the probe slows the program noticeably.`,
    );
  }
  if (view.unmatched > 0)
    notes.push(
      `${formatInt(view.unmatched)} returns of calls already running when the probe came were not timed.`,
    );
  if (view.untimed > 0)
    notes.push(
      `${formatInt(view.untimed)} calls nested more than 16 deep in a thread were counted but not timed.`,
    );
  if (view.dropped > 0)
    notes.push(
      `${formatInt(view.dropped)} calls were not timed: too many threads were inside at once.`,
    );
  if (notes.length === 0) return null;
  return (
    <ul className="space-y-1 border border-amber-500/40 bg-amber-500/10 p-3 text-xs">
      {notes.map((note) => (
        <li key={note} className="flex gap-2">
          <TriangleAlert className="mt-0.5 size-3.5 shrink-0 text-amber-600 dark:text-amber-400" />
          {note}
        </li>
      ))}
    </ul>
  );
}

function Card({
  title,
  hint,
  children,
}: {
  title: string;
  hint?: string;
  children: React.ReactNode;
}) {
  return (
    <section className="border p-4">
      <h2 className="text-sm font-medium">{title}</h2>
      {hint && <p className="text-xs text-muted-foreground">{hint}</p>}
      <div className="mt-3">{children}</div>
    </section>
  );
}

function IntervalTable({
  intervals,
}: {
  intervals: ReturnType<typeof intervalsOf>;
}) {
  const end = intervals.at(-1)?.atMs ?? 0;
  const rows = intervals.slice(-120).reverse();
  return (
    <table className="mt-3 w-full max-w-2xl border-collapse text-xs">
      <thead className="text-muted-foreground">
        <tr className="border-b">
          <th className="py-1.5 text-left font-medium">When</th>
          <th className="py-1.5 text-right font-medium">Calls per second</th>
          <th className="py-1.5 text-right font-medium">Mean</th>
          <th className="py-1.5 text-right font-medium">p99 ≤</th>
        </tr>
      </thead>
      <tbody>
        {rows.map((row) => (
          <tr key={row.atMs} className="border-b border-border/60 tabular-nums">
            <td className="py-1">
              {Math.round((end - row.atMs) / 1000)} s ago
            </td>
            <td className="py-1 text-right">
              {formatInt(Math.round(row.callsPerS))}
            </td>
            <td className="py-1 text-right">
              {row.meanNs === null ? "—" : formatNs(row.meanNs)}
            </td>
            <td className="py-1 text-right">
              {row.p99Ns === null ? "—" : formatNs(row.p99Ns)}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}
