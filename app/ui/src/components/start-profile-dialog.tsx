import { useState } from "react";
import { Check, Play } from "lucide-react";
import { cn } from "cn";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select";
import { useProfiles } from "@/hooks/use-profiles";
import { metrics } from "@/lib/metrics";
import { Routes, useRoute } from "@/lib/router";
import type { ProcessInfo } from "@/lib/types";

const intervals = [
  { value: "250", label: "Every 250 ms" },
  { value: "500", label: "Every 500 ms" },
  { value: "1000", label: "Every second" },
  { value: "2000", label: "Every 2 seconds" },
];

const durations = [
  { value: "0", label: "Until I stop it" },
  { value: "10", label: "10 seconds" },
  { value: "30", label: "30 seconds" },
  { value: "60", label: "1 minute" },
  { value: "300", label: "5 minutes" },
];

export function StartProfileDialog({
  process,
  onClose,
}: {
  process: ProcessInfo | null;
  onClose: () => void;
}) {
  return (
    <Dialog open={process !== null} onOpenChange={(open) => !open && onClose()}>
      <DialogContent className="gap-5 sm:max-w-xl">
        {process && (
          <StartForm key={process.pid} process={process} onClose={onClose} />
        )}
      </DialogContent>
    </Dialog>
  );
}

function StartForm({
  process,
  onClose,
}: {
  process: ProcessInfo;
  onClose: () => void;
}) {
  const { start, sessions } = useProfiles();
  const route = useRoute();
  const [chosen, setChosen] = useState<string[]>(["cpu"]);
  const [interval, setIntervalMs] = useState("1000");
  const [duration, setDuration] = useState("0");
  const [starting, setStarting] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const running = sessions.find((s) => s.pid === process.pid && s.running);
  const ready = chosen.length > 0;

  const toggle = (id: string) =>
    setChosen((prev) =>
      prev.includes(id) ? prev.filter((m) => m !== id) : [...prev, id],
    );

  const submit = () => {
    setStarting(true);
    setError(null);
    const settings = {
      metrics: chosen.join(","),
      interval_ms: Number(interval),
      duration_s: Number(duration),
    };
    start({ pid: process.pid, ...settings })
      .then((job) => {
        onClose();
        route.nav(Routes.sessions, { params: { 0: String(job) } }).go();
      })
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : String(e));
        setStarting(false);
      });
  };

  return (
    <>
      <DialogHeader>
        <DialogTitle>Profile {process.name}</DialogTitle>
        <DialogDescription>
          Attach to the running process. It keeps running when profiling ends.
        </DialogDescription>
      </DialogHeader>

      <div className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 border bg-muted/40 p-3 text-xs">
        <span className="text-muted-foreground">Process</span>
        <span className="font-medium">
          {process.name}{" "}
          <span className="text-muted-foreground tabular-nums">
            · pid {process.pid}
          </span>
        </span>
        <span className="text-muted-foreground">Command</span>
        <span className="truncate font-mono" title={process.command}>
          {process.command}
        </span>
      </div>

      {running ? (
        <p className="border border-primary/40 bg-primary/10 p-3 text-xs">
          This process is already being profiled. Starting joins that run and
          shows its data; the settings below are not used.
        </p>
      ) : (
        <>
          <div className="grid gap-2">
            <Label>Metrics</Label>
            <div className="grid grid-cols-2 gap-2">
              {metrics.map((m) => {
                const Icon = m.icon;
                const on = chosen.includes(m.id);
                return (
                  <button
                    key={m.id}
                    type="button"
                    disabled={!m.ready}
                    onClick={() => toggle(m.id)}
                    aria-pressed={on}
                    className={cn(
                      "flex items-start gap-2.5 border p-2.5 text-left transition-colors",
                      m.ready
                        ? "hover:bg-muted/60"
                        : "cursor-not-allowed opacity-55",
                      on && "border-primary bg-primary/10 hover:bg-primary/15",
                    )}
                  >
                    <Icon
                      className={cn(
                        "mt-0.5 size-4 shrink-0",
                        on ? "text-primary" : "text-muted-foreground",
                      )}
                    />
                    <span className="min-w-0 flex-1">
                      <span className="flex items-center gap-1.5 text-sm font-medium">
                        {m.label}
                        {!m.ready && (
                          <Badge
                            variant="outline"
                            className="h-4 px-1.5 text-[10px]"
                          >
                            Soon
                          </Badge>
                        )}
                      </span>
                      <span className="mt-0.5 line-clamp-2 block text-xs text-muted-foreground">
                        {m.description}
                      </span>
                    </span>
                    {on && <Check className="size-4 shrink-0 text-primary" />}
                  </button>
                );
              })}
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3">
            <Choice
              label="Report"
              value={interval}
              onChange={setIntervalMs}
              options={intervals}
            />
            <Choice
              label="Duration"
              value={duration}
              onChange={setDuration}
              options={durations}
            />
          </div>

          <div className="space-y-1">
            <p className="text-xs text-muted-foreground">Same as</p>
            <pre className="overflow-x-auto border bg-muted/40 px-3 py-2 font-mono text-xs">
              {cliCommand(process.pid, chosen, interval, duration)}
            </pre>
          </div>
        </>
      )}

      {error && (
        <p className="text-sm text-destructive">
          Could not start profiling: {error}
        </p>
      )}

      <DialogFooter>
        <Button variant="outline" onClick={onClose}>
          Cancel
        </Button>
        <Button onClick={submit} disabled={!ready || starting}>
          <Play />{" "}
          {starting
            ? "Starting…"
            : running
              ? "Join profiling"
              : "Start profiling"}
        </Button>
      </DialogFooter>
    </>
  );
}

function Choice({
  label,
  value,
  onChange,
  options,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  options: { value: string; label: string }[];
}) {
  return (
    <div className="grid gap-1.5">
      <Label>{label}</Label>
      <Select
        value={value}
        onValueChange={(v) => v && onChange(v)}
        items={options}
      >
        <SelectTrigger className="w-full">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {options.map((o) => (
            <SelectItem key={o.value} value={o.value}>
              {o.label}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  );
}

function cliCommand(
  pid: number,
  chosen: string[],
  interval: string,
  duration: string,
): string {
  const parts = [`sudo nusku prof --pid ${pid}`];
  if (chosen.join(",") !== "cpu") parts.push(`--metrics ${chosen.join(",")}`);
  if (interval !== "1000") parts.push(`--interval ${interval}`);
  if (duration !== "0") parts.push(`--duration ${duration}`);
  return parts.join(" ");
}
