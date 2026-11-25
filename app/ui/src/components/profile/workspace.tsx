import { useEffect, useRef, useState } from "react";
import {
  Columns2,
  Flame,
  ListOrdered,
  ListTree,
  Search,
  X,
  type LucideIcon,
} from "lucide-react";
import { cn } from "cn";
import { Input } from "@/components/ui/input";
import { Kbd } from "@/components/ui/kbd";
import { useRangeProfile } from "@/hooks/use-range-profile";
import type { Frame, Range, Session } from "@/lib/profile/types";
import { useAnalysis, type Analysis, type ViewProps } from "./analysis";
import { CallTree } from "./call-tree";
import { FlameGraph } from "./flame-graph";
import { FunctionDetails } from "./function-details";
import { Timeline } from "./timeline";
import { TopFunctions } from "./top-functions";

type ViewId = "both" | "flame" | "top" | "tree";

const views: Record<
  ViewId,
  {
    label: string;
    icon: LucideIcon;
    hint: string;
    component: (props: ViewProps) => React.ReactNode;
  }
> = {
  both: {
    label: "Table + flame graph",
    icon: Columns2,
    hint: "Top functions beside the flame graph. Pick a row to find it in the graph.",
    component: Both,
  },
  flame: {
    label: "Flame graph",
    icon: Flame,
    hint: "Every call path at once, as wide as its share. Click to zoom in.",
    component: FlameGraph,
  },
  top: {
    label: "Top functions",
    icon: ListOrdered,
    hint: "The functions that took the most, by self or total.",
    component: TopFunctions,
  },
  tree: {
    label: "Call tree",
    icon: ListTree,
    hint: "Who called what, from the outermost frame in.",
    component: CallTree,
  },
};

type Source = Pick<Session, "job" | "windows" | "running" | "failure">;

export function ProfileWorkspace({
  session,
  live,
  loading,
  rangeable = true,
  onTrack,
}: {
  session: Source;
  live: Analysis;
  loading: boolean;
  rangeable?: boolean;
  onTrack?: (frame: Frame) => Promise<void>;
}) {
  const [view, setView] = useState<ViewId>("both");
  const [range, setRange] = useState<Range | null>(null);
  const [search, setSearch] = useState("");
  const [selected, setSelected] = useState<string | null>(null);
  const searchRef = useRef<HTMLInputElement>(null);
  const ranged = useRangeProfile(session.job, range);
  const rangedAnalysis = useAnalysis(range ? ranged.profile : undefined);
  const analysis = rangedAnalysis ?? live;
  const loadingRange = range !== null && !ranged.profile && !ranged.error;

  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const typing = event.target instanceof HTMLInputElement;
      if (event.key === "/" && !typing) {
        event.preventDefault();
        searchRef.current?.focus();
      } else if (event.key === "Escape") {
        if (typing) (event.target as HTMLInputElement).blur();
        else setSelected(null);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  const View = views[view].component;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="border-b px-6 py-3">
        <Timeline
          windows={session.windows}
          running={session.running}
          range={range}
          onRangeChange={rangeable ? setRange : undefined}
        />
      </div>

      <div className="flex h-11 items-center gap-3 border-b px-6">
        <div
          className="flex items-center gap-0.5 border p-0.5"
          role="tablist"
          aria-label="View"
        >
          {(Object.keys(views) as ViewId[]).map((id) => {
            const def = views[id];
            const Icon = def.icon;
            return (
              <button
                key={id}
                type="button"
                role="tab"
                aria-selected={view === id}
                title={def.hint}
                onClick={() => setView(id)}
                className={cn(
                  "inline-flex h-7 items-center gap-1.5 px-2.5 text-xs font-medium text-muted-foreground transition-colors hover:text-foreground",
                  view === id && "bg-muted text-foreground",
                )}
              >
                <Icon className="size-3.5" />
                {def.label}
              </button>
            );
          })}
        </div>
        <div className="flex-1" />
        <div className="relative w-72">
          <Search className="pointer-events-none absolute top-1/2 left-2.5 size-3.5 -translate-y-1/2 text-muted-foreground" />
          <Input
            ref={searchRef}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            placeholder="Search functions or modules"
            className="h-8 pr-8 pl-8 text-xs"
          />
          {search ? (
            <button
              type="button"
              aria-label="Clear search"
              onClick={() => setSearch("")}
              className="absolute top-1/2 right-2 -translate-y-1/2 text-muted-foreground hover:text-foreground"
            >
              <X className="size-3.5" />
            </button>
          ) : (
            <Kbd className="absolute top-1/2 right-2 -translate-y-1/2">/</Kbd>
          )}
        </div>
      </div>

      <div className="flex min-h-0 flex-1">
        <div className="min-w-0 flex-1">
          {session.failure ? (
            <Message title="Profiling failed" text={session.failure} />
          ) : ranged.error ? (
            <Message
              title="Could not load that part of the run"
              text={ranged.error.message}
            />
          ) : loading || loadingRange ? (
            <Message
              title="Loading…"
              text={
                loading
                  ? "Building the profile."
                  : "Building the profile of the chosen span."
              }
            />
          ) : analysis.profile.total === 0 ? (
            <Message
              title={session.running ? "Collecting samples…" : "No samples"}
              text={
                session.running
                  ? "The first stacks show up after the first report."
                  : "The process did not run on the CPU while it was profiled."
              }
            />
          ) : (
            <View
              analysis={analysis}
              search={search}
              selected={selected}
              onSelect={setSelected}
            />
          )}
        </div>
        {selected && (
          <FunctionDetails
            analysis={analysis}
            functionKey={selected}
            onSelect={setSelected}
            onTrack={onTrack}
          />
        )}
      </div>
    </div>
  );
}

function Both(props: ViewProps) {
  return (
    <div className="grid h-full min-h-0 grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
      <div className="min-h-0 border-r">
        <TopFunctions {...props} />
      </div>
      <div className="min-h-0">
        <FlameGraph {...props} />
      </div>
    </div>
  );
}

function Message({ title, text }: { title: string; text: string }) {
  return (
    <div className="grid h-full place-items-center p-10 text-center">
      <div>
        <p className="font-medium">{title}</p>
        <p className="mt-1 text-sm text-muted-foreground">{text}</p>
      </div>
    </div>
  );
}
