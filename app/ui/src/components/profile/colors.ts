import type { Frame } from "@/lib/profile/types";

export type FrameKind = "app" | "library" | "kernel" | "unknown";

export function frameKind(
  frame: Frame,
  programModule: string | null,
): FrameKind {
  if (frame.kernel) return "kernel";
  if (!frame.function) return "unknown";
  if (programModule && frame.module === programModule) return "app";
  if (frame.module && /\.so(\.|$)/.test(frame.module)) return "library";
  return "app";
}

const families: Record<
  FrameKind,
  { hue: number; spread: number; chroma: number }
> = {
  app: { hue: 62, spread: 28, chroma: 0.15 },
  library: { hue: 215, spread: 40, chroma: 0.11 },
  kernel: { hue: 300, spread: 30, chroma: 0.12 },
  unknown: { hue: 260, spread: 0, chroma: 0.01 },
};

export const kindLabels: Record<FrameKind, string> = {
  app: "Program",
  library: "Library",
  kernel: "Kernel",
  unknown: "Unnamed",
};

function hash(text: string): number {
  let h = 0;
  for (let i = 0; i < text.length; i++) h = (h * 31 + text.charCodeAt(i)) | 0;
  return Math.abs(h);
}

export type ColorBy = "kind" | "self";

export const idleColor = "oklch(0.93 0.005 250)";

export function heatColor(self: number, hottest: number): string {
  if (self <= 0 || hottest <= 0) return idleColor;
  const share = Math.sqrt(Math.min(1, self / hottest));
  const lightness = 0.94 - 0.3 * share;
  const chroma = 0.03 + 0.16 * share;
  return `oklch(${lightness.toFixed(3)} ${chroma.toFixed(3)} 35)`;
}

export function frameColor(kind: FrameKind, name: string): string {
  const family = families[kind];
  const offset = family.spread
    ? (hash(name) % (family.spread * 2)) - family.spread
    : 0;
  const lightness = 0.8 + ((hash(name) >> 3) % 7) / 100;
  return `oklch(${lightness.toFixed(2)} ${family.chroma} ${family.hue + offset})`;
}

export function kindColor(kind: FrameKind): string {
  const family = families[kind];
  return `oklch(0.8 ${family.chroma} ${family.hue})`;
}
