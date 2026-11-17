import { useState } from "react";
import {
  ArrowLeft,
  CircleCheck,
  Download,
  Eye,
  Square,
  TriangleAlert,
} from "lucide-react";
import { cn } from "cn";
import { ProfileWorkspace } from "@/components/profile/workspace";
import { SessionStatus } from "@/components/session-status";
import { Button } from "@/components/ui/button";
import { useLiveProfile } from "@/hooks/use-live-profile";
import { useProfiles, useSession } from "@/hooks/use-profiles";
import { folded } from "@/lib/profile/analyze";
import { formatClock, formatInt, formatPercent } from "@/lib/format";
import { analyze, type Analysis } from "@/components/profile/analysis";
import type { Profile, Session } from "@/lib/profile/types";
import { share, trusted, type Quality } from "@/lib/profile/quality";
import { Routes, useRoute } from "@/lib/router";

const empty: Analysis = analyze({
  sampleHz: 0,
  total: 0,
  lost: 0,
  rejected: 0,
  stacks: [],
});

export function SessionPage({ job }: { job: number }) {
  const session = useSession(job);
  const live = useLiveProfile(job);
  const analysis = live.analysis ?? empty;
  const profile = analysis.profile;
  const { loading } = useProfiles();
  const back = useRoute().nav(Routes.sessions).href();

  if (!session) {
    return (
      <div className="grid h-full place-items-center text-center">
        <div>
          <p className="font-medium">
            {loading ? "Loading…" : "This session is gone"}
          </p>
          {!loading && (
            <p className="mt-1 text-sm text-muted-foreground">
              It made room for newer ones.
            </p>
          )}
          <Button
            className="mt-4"
            variant="outline"
            nativeButton={false}
            render={<a href={back} />}
          >
            <ArrowLeft /> All sessions
          </Button>
        </div>
      </div>
    );
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <SessionHeader session={session} profile={profile} back={back} />
      <SessionStats session={session} analysis={analysis} />
      <ProfileWorkspace
        session={session}
        live={analysis}
        loading={!live.analysis && !live.error}
      />
    </div>
  );
}

function SessionHeader({
  session,
  profile,
  back,
}: {
  session: Session;
  profile: Profile;
  back: string;
}) {
  const { start, stop } = useProfiles();
  const [stopping, setStopping] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const run = (action: Promise<unknown>) => {
    setStopping(true);
    setError(null);
    action
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : String(e)),
      )
      .finally(() => setStopping(false));
  };
  const onStop = () => run(stop(session.job));
  const onJoin = () =>
    run(
      start({
        pid: session.pid,
        metrics: "cpu",
        interval_ms: 1000,
        duration_s: 0,
      }),
    );

  const exportFolded = () => {
    const blob = new Blob([folded(profile) + "\n"], { type: "text/plain" });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = `${session.name}-${session.pid}.folded`;
    link.click();
    URL.revokeObjectURL(link.href);
  };

  return (
    <header className="flex h-14 shrink-0 items-center gap-3 border-b px-4">
      <Button
        variant="ghost"
        size="icon-sm"
        nativeButton={false}
        render={<a href={back} aria-label="All sessions" />}
      >
        <ArrowLeft />
      </Button>
      <div className="min-w-0 flex-1">
        <div className="flex items-center gap-2.5">
          <h1 className="truncate text-base font-semibold tracking-tight">
            {session.name}
          </h1>
          <span className="text-sm text-muted-foreground tabular-nums">
            pid {session.pid}
          </span>
          <SessionStatus session={session} />
        </div>
        <p
          className="truncate font-mono text-xs text-muted-foreground"
          title={session.command}
        >
          {session.command}
        </p>
      </div>
      {error && <span className="text-xs text-destructive">{error}</span>}
      {session.running && session.mine && (
        <Button variant="destructive" onClick={onStop} disabled={stopping}>
          <Square className="fill-current" />{" "}
          {stopping
            ? "Stopping…"
            : session.users > 1
              ? "Stop watching"
              : "Stop"}
        </Button>
      )}
      {session.running && !session.mine && (
        <Button
          variant="outline"
          onClick={onJoin}
          disabled={stopping}
          title="Keep this profile running while this page is open"
        >
          <Eye /> Watch too
        </Button>
      )}
      <Button
        variant="outline"
        onClick={exportFolded}
        disabled={profile.total === 0}
      >
        <Download /> Export
      </Button>
    </header>
  );
}

function SessionStats({
  session,
  analysis,
}: {
  session: Session;
  analysis: Analysis;
}) {
  const [open, setOpen] = useState(false);
  const { profile, quality: q } = analysis;
  const good = trusted(q);
  const stats = [
    { label: "Elapsed", value: formatClock(session.elapsedMs) },
    { label: "Samples", value: formatInt(session.samples) },
    {
      label: "Sample rate",
      value: session.sampleHz > 0 ? `${session.sampleHz} Hz` : "—",
    },
    { label: "Stacks", value: formatInt(profile.stacks.length) },
    { label: "Watching", value: session.running ? String(session.users) : "—" },
  ];
  return (
    <div className="shrink-0 border-b">
      <div className="flex flex-wrap items-center gap-x-8 gap-y-2 px-6 py-2.5">
        {stats.map((s) => (
          <div key={s.label}>
            <div className="text-[11px] tracking-wide text-muted-foreground uppercase">
              {s.label}
            </div>
            <div className="text-sm font-medium tabular-nums">{s.value}</div>
          </div>
        ))}
        {profile.total > 0 && (
          <button
            type="button"
            onClick={() => setOpen((last) => !last)}
            aria-expanded={open}
            className={cn(
              "ml-auto flex items-center gap-2 border px-2.5 py-1 text-xs",
              good
                ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"
                : "border-amber-500/40 bg-amber-500/10 text-amber-700 dark:text-amber-300",
            )}
          >
            {good ? (
              <CircleCheck className="size-3.5" />
            ) : (
              <TriangleAlert className="size-3.5" />
            )}
            {good ? "Profile looks complete" : "Check the profile"}
          </button>
        )}
      </div>
      {open && <QualityDetails q={q} sampleHz={profile.sampleHz} />}
    </div>
  );
}

function QualityDetails({ q, sampleHz }: { q: Quality; sampleHz: number }) {
  const rows: { level: "ok" | "warn"; text: string }[] = [
    {
      level: share(q.incomplete, q.samples) < 0.05 ? "ok" : "warn",
      text:
        q.incomplete === 0
          ? "Every sample has a whole stack, from the function running out to the program start."
          : `${formatPercent(q.incomplete, q.samples)} of samples have a stack that stops early: the unwinder could not go further, so their callers are missing.`,
    },
    {
      level: share(q.unnamed, q.samples) < 0.05 ? "ok" : "warn",
      text:
        q.unnamed === 0
          ? "Every sample ran in code with a name."
          : `${formatPercent(q.unnamed, q.samples)} of samples ran in code with no name: see the binaries below.`,
    },
    {
      level: q.lost === 0 ? "ok" : "warn",
      text:
        q.lost === 0
          ? "The kernel dropped no samples."
          : `The kernel dropped ${formatInt(q.lost)} samples (${formatPercent(q.lost, q.samples + q.lost)}): the CPU was too busy to hand them over in time.`,
    },
  ];
  if (q.rejected > 0) {
    rows.push({
      level: "warn",
      text: `${formatInt(q.rejected)} reports were too big to keep: their samples are missing.`,
    });
  }
  const gaps = q.modules
    .filter((m) => share(m.unnamed + m.noLines, q.samples) >= 0.005)
    .slice(0, 8);
  return (
    <div className="space-y-3 border-t bg-muted/30 px-6 py-3 text-xs">
      <ul className="space-y-1">
        {rows.map((row) => (
          <li key={row.text} className="flex items-start gap-2">
            {row.level === "ok" ? (
              <CircleCheck className="mt-px size-3.5 shrink-0 text-emerald-600 dark:text-emerald-400" />
            ) : (
              <TriangleAlert className="mt-px size-3.5 shrink-0 text-amber-600 dark:text-amber-400" />
            )}
            <span>{row.text}</span>
          </li>
        ))}
      </ul>
      {gaps.length > 0 && (
        <table className="w-full max-w-3xl text-left">
          <thead className="text-muted-foreground">
            <tr>
              <th className="py-1 pr-4 font-medium">Binary</th>
              <th className="py-1 pr-4 font-medium">Missing</th>
              <th className="py-1 pr-4 text-right font-medium">Samples</th>
              <th className="py-1 font-medium">How to fix</th>
            </tr>
          </thead>
          <tbody>
            {gaps.map((m) => {
              const names = m.unnamed > 0;
              const samples = names ? m.unnamed : m.noLines;
              return (
                <tr key={m.module} className="border-t border-border/60">
                  <td className="py-1 pr-4 font-mono" title={m.module}>
                    {m.module.slice(m.module.lastIndexOf("/") + 1)}
                  </td>
                  <td className="py-1 pr-4">{names ? "Names" : "Lines"}</td>
                  <td
                    className="py-1 pr-4 text-right tabular-nums"
                    title={formatInt(samples) + (sampleHz ? ` samples` : "")}
                  >
                    {formatPercent(samples, q.samples)}
                  </td>
                  <td className="py-1 text-muted-foreground">
                    {names
                      ? "No symbols: install its debug package (-dbgsym), set DEBUGINFOD_URLS, or build it with symbols."
                      : "No line info: install its debug package, or build it with -g."}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
