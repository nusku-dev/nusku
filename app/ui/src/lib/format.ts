export function formatBytes(bytes: number): string {
  const units = ["B", "KiB", "MiB", "GiB", "TiB"];
  let value = bytes;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value.toFixed(value >= 100 || unit === 0 ? 0 : 1)} ${units[unit]}`;
}

export function formatAgo(unixMs: number, now: number): string {
  const s = Math.max(0, Math.round((now - unixMs) / 1000));
  if (s < 10) return "just now";
  if (s < 60) return `${s} s ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} h ago`;
  return `${Math.round(h / 24)} d ago`;
}

const integer = new Intl.NumberFormat("en-US");

export function formatInt(n: number): string {
  return integer.format(Math.round(n));
}

export function formatPercent(part: number, whole: number): string {
  if (whole <= 0) return "0%";
  const p = (part / whole) * 100;
  if (p > 0 && p < 0.1) return "<0.1%";
  return `${p.toFixed(p >= 99.95 ? 0 : 1)}%`;
}

export function formatDuration(ms: number): string {
  if (ms < 1000) return `${Math.round(ms)} ms`;
  const s = ms / 1000;
  if (s < 60) return `${s.toFixed(1)} s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${String(Math.floor(s % 60)).padStart(2, "0")}s`;
  return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m`;
}

export function formatClock(ms: number): string {
  const total = Math.floor(ms / 1000);
  const h = Math.floor(total / 3600);
  const mm = String(Math.floor((total % 3600) / 60)).padStart(2, "0");
  const ss = String(total % 60).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

export function formatSamples(value: number, sampleHz: number): string {
  const time =
    sampleHz > 0 ? ` · ${formatDuration((value / sampleHz) * 1000)}` : "";
  return `${formatInt(value)} ${value === 1 ? "sample" : "samples"}${time}`;
}

export function formatCpuTime(value: number, sampleHz: number): string {
  return sampleHz > 0
    ? formatDuration((value / sampleHz) * 1000)
    : formatInt(value);
}
