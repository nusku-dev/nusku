import { useMemo, useState } from "react";
import { ArrowDown } from "lucide-react";
import { cn } from "cn";
import { frameName, matches, moduleName } from "@/lib/profile/analyze";
import { formatCpuTime } from "@/lib/format";
import type { ViewProps } from "./analysis";
import { frameColor, frameKind } from "./colors";
import { ShareBar } from "./share-bar";

type SortKey = "self" | "total";

const maxRows = 400;

export function TopFunctions({
  analysis,
  search,
  selected,
  onSelect,
}: ViewProps) {
  const [sort, setSort] = useState<SortKey>("self");
  const total = analysis.profile.total;

  const rows = useMemo(() => {
    const filtered = search
      ? analysis.functions.filter((f) => matches(f.frame, search))
      : analysis.functions;
    return [...filtered].sort((a, b) => b[sort] - a[sort]).slice(0, maxRows);
  }, [analysis.functions, search, sort]);

  const header = (key: SortKey, label: string) => (
    <button
      type="button"
      onClick={() => setSort(key)}
      className={cn(
        "inline-flex w-full items-center justify-end gap-1 hover:text-foreground",
        sort === key && "text-foreground",
      )}
    >
      {sort === key && <ArrowDown className="size-3" />}
      {label}
    </button>
  );

  return (
    <div className="h-full overflow-auto">
      <table className="w-full table-fixed border-collapse text-sm">
        <thead className="sticky top-0 z-10 bg-background text-xs text-muted-foreground">
          <tr className="border-b">
            <th className="w-10 px-2 py-2 text-right font-medium">#</th>
            <th className="px-3 py-2 text-left font-medium">Function</th>
            <th className="w-24 px-2 py-2 font-medium">
              {header("self", "Self")}
            </th>
            <th className="w-24 px-2 py-2 font-medium">
              {header("total", "Total")}
            </th>
            <th className="w-20 px-2 py-2 text-right font-medium">CPU time</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((f, i) => {
            const kind = frameKind(f.frame, analysis.programModule);
            const name = frameName(f.frame);
            return (
              <tr
                key={f.key}
                onClick={() => onSelect(f.key === selected ? null : f.key)}
                className={cn(
                  "cursor-pointer border-b border-border/60 hover:bg-muted/60",
                  f.key === selected && "bg-muted",
                )}
              >
                <td className="px-3 py-1.5 text-right text-xs text-muted-foreground tabular-nums">
                  {i + 1}
                </td>
                <td className="px-3 py-1.5">
                  <div className="flex min-w-0 items-center gap-2">
                    <span
                      className="size-2.5 shrink-0"
                      style={{ background: frameColor(kind, name) }}
                    />
                    <span
                      className="truncate font-mono text-[12.5px]"
                      title={name}
                    >
                      {name}
                    </span>
                    <span className="min-w-0 shrink-4 truncate text-xs text-muted-foreground">
                      {moduleName(f.frame)}
                    </span>
                  </div>
                </td>
                <td className="px-3 py-1.5">
                  <ShareBar value={f.self} total={total} />
                </td>
                <td className="px-3 py-1.5">
                  <ShareBar value={f.total} total={total} tone="muted" />
                </td>
                <td className="px-3 py-1.5 text-right text-xs text-muted-foreground tabular-nums">
                  {formatCpuTime(f[sort], analysis.profile.sampleHz)}
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      {rows.length === 0 && (
        <p className="p-8 text-center text-sm text-muted-foreground">
          No function matches “{search}”.
        </p>
      )}
    </div>
  );
}
