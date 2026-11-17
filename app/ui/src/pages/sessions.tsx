import { Activity, Plus } from "lucide-react";
import { PageHeader } from "@/components/layout/PageHeader";
import { SessionStatus } from "@/components/session-status";
import { Button } from "@/components/ui/button";
import { Skeleton } from "@/components/ui/skeleton";
import { useNow } from "@/hooks/use-now";
import { useProfiles } from "@/hooks/use-profiles";
import { formatAgo, formatClock, formatInt } from "@/lib/format";
import type { Session } from "@/lib/profile/types";
import { Routes, useRoute } from "@/lib/router";

export function SessionsPage() {
  const { sessions, loading, error } = useProfiles();
  const route = useRoute();
  const now = useNow(5000);
  const processes = route.nav(Routes.processes).href();
  const list = [...sessions].sort(
    (a, b) => Number(b.running) - Number(a.running) || b.job - a.job,
  );

  return (
    <>
      <PageHeader
        title="Sessions"
        description="Every profiling run: live ones as they happen, finished ones to look back at."
        actions={
          <Button nativeButton={false} render={<a href={processes} />}>
            <Plus /> New session
          </Button>
        }
      />
      {error && (
        <p className="border-b px-6 py-2 text-sm text-destructive">
          Cannot read the sessions: {error.message}
        </p>
      )}
      <div className="min-h-0 flex-1 overflow-auto">
        {loading ? (
          <div className="space-y-3 p-6">
            {Array.from({ length: 4 }, (_, i) => (
              <Skeleton key={i} className="h-12" />
            ))}
          </div>
        ) : list.length === 0 ? (
          <div className="grid h-full place-items-center p-10 text-center">
            <div className="flex flex-col items-center gap-2">
              <span className="grid size-10 place-items-center rounded-md bg-muted">
                <Activity className="size-5" />
              </span>
              <p className="font-medium">No sessions yet</p>
              <p className="text-sm text-muted-foreground">
                Pick a process and see where its time goes, live.
              </p>
              <Button
                className="mt-2"
                nativeButton={false}
                render={<a href={processes} />}
              >
                <Plus /> Profile a process
              </Button>
            </div>
          </div>
        ) : (
          <table className="w-full table-fixed border-collapse text-sm">
            <thead className="sticky top-0 z-10 bg-background text-xs text-muted-foreground">
              <tr className="border-b">
                <th className="w-40 px-6 py-2 text-left font-medium">Status</th>
                <th className="px-3 py-2 text-left font-medium">Process</th>
                <th className="w-24 px-3 py-2 text-right font-medium">
                  Watching
                </th>
                <th className="w-28 px-3 py-2 text-right font-medium">
                  Duration
                </th>
                <th className="w-28 px-3 py-2 text-right font-medium">
                  Samples
                </th>
                <th className="w-32 px-6 py-2 text-right font-medium">
                  Started
                </th>
              </tr>
            </thead>
            <tbody>
              {list.map((s) => (
                <SessionRow key={s.job} session={s} now={now} />
              ))}
            </tbody>
          </table>
        )}
      </div>
    </>
  );
}

function SessionRow({ session: s, now }: { session: Session; now: number }) {
  const route = useRoute();
  const open = route.nav(Routes.sessions, { params: { 0: String(s.job) } });
  return (
    <tr
      onClick={open.go}
      className="cursor-pointer border-b border-border/60 hover:bg-muted/50"
    >
      <td className="px-6 py-2.5">
        <SessionStatus session={s} />
      </td>
      <td className="px-3 py-2.5">
        <div className="flex min-w-0 items-baseline gap-2">
          <span className="font-medium">{s.name}</span>
          <span className="text-xs text-muted-foreground tabular-nums">
            pid {s.pid}
          </span>
          <span
            className="truncate font-mono text-xs text-muted-foreground"
            title={s.command}
          >
            {s.command}
          </span>
        </div>
      </td>
      <td className="px-3 py-2.5 text-right text-xs text-muted-foreground tabular-nums">
        {s.running ? (s.users === 1 ? "1 page" : `${s.users} pages`) : "—"}
      </td>
      <td className="px-3 py-2.5 text-right tabular-nums">
        {formatClock(s.elapsedMs)}
      </td>
      <td className="px-3 py-2.5 text-right tabular-nums">
        {formatInt(s.samples)}
      </td>
      <td className="px-6 py-2.5 text-right text-xs text-muted-foreground">
        {formatAgo(s.startedAt, now)}
      </td>
    </tr>
  );
}
