import { useEffect, useMemo, useState } from "react";
import { ArrowLeft, Download, Pencil, Trash2 } from "lucide-react";
import { analyze } from "@/components/profile/analysis";
import { ProfileWorkspace } from "@/components/profile/workspace";
import { RunLabelDialog } from "@/components/run-label-dialog";
import { Button } from "@/components/ui/button";
import { backend, type CompactWire, type RunMeta } from "@/lib/backend";
import { formatClock, formatInt } from "@/lib/format";
import { folded } from "@/lib/profile/analyze";
import { profileOf, windowsOf } from "@/lib/profile/wire";
import { Routes, useRoute } from "@/lib/router";
import { useRuns } from "@/hooks/use_runs";

export function RunPage({ id }: { id: number }) {
  const { runs, relabel, remove } = useRuns();
  const route = useRoute();
  const back = route.nav(Routes.runs).href();
  const [loaded, setLoaded] = useState<{
    meta: RunMeta;
    profile: CompactWire;
  } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [editing, setEditing] = useState(false);
  const [deleting, setDeleting] = useState(false);

  useEffect(() => {
    let alive = true;
    backend
      .runsGet(id)
      .then((got) => alive && setLoaded(got))
      .catch(
        (e: unknown) =>
          alive && setError(e instanceof Error ? e.message : String(e)),
      );
    return () => {
      alive = false;
    };
  }, [id]);

  const analysis = useMemo(
    () => (loaded ? analyze(profileOf(loaded.profile)) : null),
    [loaded],
  );
  const windows = useMemo(
    () => (loaded ? windowsOf(loaded.profile) : []),
    [loaded],
  );
  const meta = runs.find((r) => r.id === id) ?? loaded?.meta;

  if (error || !meta || !analysis) {
    return (
      <div className="grid h-full place-items-center text-center">
        <div>
          <p className="font-medium">
            {error ? "This run cannot be opened" : "Loading…"}
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

  const onDelete = () => {
    if (!deleting) return setDeleting(true);
    remove(id)
      .then(() => route.nav(Routes.runs).go())
      .catch((e: unknown) =>
        setError(e instanceof Error ? e.message : String(e)),
      );
  };

  const exportFolded = () => {
    const blob = new Blob([folded(analysis.profile) + "\n"], {
      type: "text/plain",
    });
    const link = document.createElement("a");
    link.href = URL.createObjectURL(blob);
    link.download = `${meta.label.replace(/[^\w.-]+/g, "-")}.folded`;
    link.click();
    URL.revokeObjectURL(link.href);
  };

  const stats = [
    { label: "Program", value: meta.program || "—" },
    { label: "Duration", value: formatClock(meta.elapsed_ms) },
    { label: "Samples", value: formatInt(meta.samples) },
    {
      label: "Sample rate",
      value: meta.sample_hz > 0 ? `${meta.sample_hz} Hz` : "—",
    },
    { label: "Saved", value: new Date(meta.saved_unix_ms).toLocaleString() },
  ];

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
        <div className="min-w-0 flex-1">
          <h1 className="truncate text-base font-semibold tracking-tight">
            {meta.label}
          </h1>
          <p
            className="truncate text-xs text-muted-foreground"
            title={meta.note}
          >
            {meta.note || <span className="font-mono">{meta.command}</span>}
          </p>
        </div>
        <Button variant="outline" onClick={() => setEditing(true)}>
          <Pencil /> Rename
        </Button>
        <Button variant="outline" onClick={exportFolded}>
          <Download /> Export
        </Button>
        <Button
          variant={deleting ? "destructive" : "outline"}
          onClick={onDelete}
          onBlur={() => setDeleting(false)}
        >
          <Trash2 /> {deleting ? "Delete for good?" : "Delete"}
        </Button>
      </header>
      <div className="flex flex-wrap items-center gap-x-8 gap-y-2 border-b px-6 py-2.5">
        {stats.map((s) => (
          <div key={s.label} className="min-w-0">
            <div className="text-[11px] tracking-wide text-muted-foreground uppercase">
              {s.label}
            </div>
            <div className="truncate text-sm font-medium tabular-nums">
              {s.value}
            </div>
          </div>
        ))}
      </div>
      <ProfileWorkspace
        session={{ job: -1, windows, running: false, failure: null }}
        live={analysis}
        loading={false}
        rangeable={false}
      />
      <RunLabelDialog
        open={editing}
        title="Rename this run"
        description="The label and note say what this run measured, for when you compare it."
        action="Save"
        label={meta.label}
        note={meta.note}
        onSubmit={(label, note) => relabel(id, label, note)}
        onClose={() => setEditing(false)}
      />
    </div>
  );
}
