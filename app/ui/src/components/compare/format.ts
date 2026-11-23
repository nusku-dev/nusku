import type { Change, Measure } from "@/lib/profile/compare";

export function formatMeasure(value: number, measure: Measure): string {
  if (measure === "share") return `${value.toFixed(value >= 10 ? 1 : 2)}%`;
  const abs = Math.abs(value);
  if (abs >= 1) return `${value.toFixed(abs >= 100 ? 0 : 2)} s`;
  return `${(value * 1000).toFixed(abs >= 0.1 ? 0 : 1)} ms`;
}

export function formatChange(change: Change, measure: Measure): string {
  if (change.noise) return "≈ same (within noise)";
  const sign = change.delta > 0 ? "+" : "−";
  const amount = formatMeasure(Math.abs(change.delta), measure);
  const unit = measure === "share" ? " pts" : "";
  const relative =
    change.relative === null
      ? "new"
      : `${sign}${Math.abs(change.relative * 100).toFixed(0)}%`;
  return `${sign}${amount.replace("%", "")}${unit} (${relative})`;
}
