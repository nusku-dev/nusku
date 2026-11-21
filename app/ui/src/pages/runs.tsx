import { Bookmark } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { Skeleton } from "@/components/ui/skeleton";
import { useNow } from "@/hooks/use-now";
import type { RunMeta } from "@/lib/backend";
import { formatAgo, formatClock, formatInt } from "@/lib/format";
import { Routes, useRoute } from "@/lib/router";
import { useStoreRuns } from "@/hooks/use_runs";

export function RunsPage() {
  const { runs, loading, error } = useStoreRuns();
  const now = useNow(30000);

  return (
    <>
      <PageHeader
        title="Saved runs"
        description="Profiles kept with a label, to look at again or compare."
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
        ) : runs.length === 0 ? (
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
                <th className="px-6 py-2 text-left font-medium">Run</th>
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
              {runs.map((run) => (
                <RunRow key={run.id} run={run} now={now} />
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}

function RunRow({ run, now }: { run: RunMeta; now: number }) {
  const open = useRoute().nav(Routes.runs, { params: { 0: String(run.id) } });
  return (
    <tr
      onClick={open.go}
      className="cursor-pointer border-b border-border/60 hover:bg-muted/50"
    >
      <td className="px-6 py-2.5">
        <div className="truncate font-medium">{run.label}</div>
        {run.note && (
          <div className="truncate text-xs text-muted-foreground">
            {run.note}
          </div>
        )}
      </td>
      <td className="px-3 py-2.5">
        <div className="truncate">{run.program || "—"}</div>
        <div
          className="truncate font-mono text-xs text-muted-foreground"
          title={run.command}
        >
          {run.command}
        </div>
      </td>
      <td className="px-3 py-2.5 text-right tabular-nums">
        {formatClock(run.elapsed_ms)}
      </td>
      <td className="px-3 py-2.5 text-right tabular-nums">
        {formatInt(run.samples)}
      </td>
      <td
        className="px-6 py-2.5 text-right text-xs text-muted-foreground"
        title={new Date(run.saved_unix_ms).toLocaleString()}
      >
        {formatAgo(run.saved_unix_ms, now)}
      </td>
    </tr>
  );
}
