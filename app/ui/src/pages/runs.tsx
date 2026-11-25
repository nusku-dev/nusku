import { useEffect, useState } from "react";
import { Bookmark, GitCompare } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { useNow } from "@/hooks/use-now";
import type { RunMeta } from "@/lib/backend";
import { formatAgo, formatClock, formatInt } from "@/lib/format";
import { Routes, useRoute } from "@/lib/router";
import { compareKeyOf } from "@/lib/runs";
import { useRuns } from "@/hooks/use_runs";

export function RunsPage() {
  const { runs, loading, error, refresh } = useRuns();
  const now = useNow(30000);
  useEffect(() => {
    void refresh();
  }, [refresh]);
  const route = useRoute();
  const rows = rowsOf(runs);
  const [picked, setPicked] = useState<string[]>([]);
  const pick = (key: string) =>
    setPicked((last) =>
      last.includes(key)
        ? last.filter((p) => p !== key)
        : [...last, key].slice(-2),
    );
  const chosen = rows
    .filter((row) => picked.includes(row.key))
    .sort((x, y) => x.saved - y.saved);
  const compareGo = () =>
    route
      .nav(Routes.compare, { params: { 0: chosen[0].key, 1: chosen[1].key } })
      .go();

  return (
    <>
      <PageHeader
        title="Saved runs"
        description="Profiles kept with a label, to look at again or compare."
        actions={
          <Button
            onClick={compareGo}
            disabled={chosen.length !== 2}
            title="Pick two runs to see what changed between them"
          >
            <GitCompare /> Compare
            {chosen.length > 0 ? ` (${chosen.length}/2)` : ""}
          </Button>
        }
      />
      {error && (
        <p className="border-b px-6 py-2 text-sm text-destructive">
          Cannot read the saved runs: {error.message}
        </p>
      )}
      <div className="min-h-0 flex-1 overflow-auto">
        {loading ? (
          <div className="space-y-3 p-6">
            {Array.from({ length: 4 }, (_, i) => (
              <Skeleton key={i} className="h-12" />
            ))}
          </div>
        ) : rows.length === 0 ? (
          <div className="grid h-full place-items-center p-10 text-center">
            <div className="flex flex-col items-center gap-2">
              <span className="grid size-10 place-items-center rounded-md bg-muted">
                <Bookmark className="size-5" />
              </span>
              <p className="font-medium">No saved runs yet</p>
              <p className="max-w-sm text-sm text-muted-foreground">
                Open a session and press Save run to keep its profile with a
                label, like “init v1: sort then dedupe”.
              </p>
            </div>
          </div>
        ) : (
          <table className="w-full table-fixed border-collapse text-sm">
            <thead className="sticky top-0 z-10 bg-background text-xs text-muted-foreground">
              <tr className="border-b">
                <th className="w-12 py-2 pl-6" aria-label="Pick" />
                <th className="px-3 py-2 text-left font-medium">Run</th>
                <th className="w-48 px-3 py-2 text-left font-medium">
                  Program
                </th>
                <th className="w-28 px-3 py-2 text-right font-medium">
                  Duration
                </th>
                <th className="w-28 px-3 py-2 text-right font-medium">
                  Samples
                </th>
                <th className="w-32 px-6 py-2 text-right font-medium">Saved</th>
              </tr>
            </thead>
            <tbody>
              {rows.map((row) => (
                <RunRow
                  key={row.key}
                  row={row}
                  now={now}
                  picked={picked.includes(row.key)}
                  onPick={pick}
                />
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}

interface Row {
  key: string;
  label: string;
  note: string;
  program: string;
  command: string;
  elapsedMs: number;
  samples: number;
  saved: number;
  count: number;
  first: number;
}

function rowsOf(runs: RunMeta[]): Row[] {
  const rows: Row[] = [];
  const series = new Map<string, RunMeta[]>();
  for (const run of runs) {
    if (!run.series) {
      rows.push({
        key: compareKeyOf(run),
        label: run.label,
        note: run.note,
        program: run.program,
        command: run.command,
        elapsedMs: run.elapsed_ms,
        samples: run.samples,
        saved: run.saved_unix_ms,
        count: 1,
        first: run.id,
      });
      continue;
    }
    series.set(run.series, [...(series.get(run.series) ?? []), run]);
  }
  for (const [name, members] of series) {
    const mean = (f: (m: RunMeta) => number) =>
      members.reduce((sum, m) => sum + f(m), 0) / members.length;
    const first = [...members].sort((x, y) => x.repeat - y.repeat)[0];
    rows.push({
      key: compareKeyOf(first),
      label: name,
      note: first.note,
      program: first.program,
      command: first.command,
      elapsedMs: mean((m) => m.elapsed_ms),
      samples: Math.round(mean((m) => m.samples)),
      saved: Math.max(...members.map((m) => m.saved_unix_ms)),
      count: members.length,
      first: first.id,
    });
  }
  return rows.sort((x, y) => y.saved - x.saved);
}

function RunRow({
  row,
  now,
  picked,
  onPick,
}: {
  row: Row;
  now: number;
  picked: boolean;
  onPick: (key: string) => void;
}) {
  const open = useRoute().nav(Routes.runs, {
    params: { 0: String(row.first) },
  });
  return (
    <tr
      onClick={open.go}
      className="cursor-pointer border-b border-border/60 hover:bg-muted/50"
    >
      <td className="py-2.5 pl-6" onClick={(e) => e.stopPropagation()}>
        <input
          type="checkbox"
          checked={picked}
          onChange={() => onPick(row.key)}
          aria-label={`Pick ${row.label} to compare`}
          className="size-4 accent-primary"
        />
      </td>
      <td className="px-3 py-2.5">
        <div className="flex min-w-0 items-center gap-2">
          <span className="truncate font-medium">{row.label}</span>
          {row.count > 1 && (
            <span
              className="shrink-0 border px-1.5 text-xs text-muted-foreground"
              title="A series: compared, its runs are averaged"
            >
              {row.count} runs
            </span>
          )}
        </div>
        {row.note && (
          <div className="truncate text-xs text-muted-foreground">
            {row.note}
          </div>
        )}
      </td>
      <td className="px-3 py-2.5">
        <div className="truncate">{row.program || "—"}</div>
        <div
          className="truncate font-mono text-xs text-muted-foreground"
          title={row.command}
        >
          {row.command}
        </div>
      </td>
      <td className="px-3 py-2.5 text-right tabular-nums">
        {formatClock(row.elapsedMs)}
      </td>
      <td className="px-3 py-2.5 text-right tabular-nums">
        {formatInt(row.samples)}
      </td>
      <td
        className="px-6 py-2.5 text-right text-xs text-muted-foreground"
        title={new Date(row.saved).toLocaleString()}
      >
        {formatAgo(row.saved, now)}
      </td>
    </tr>
  );
}
