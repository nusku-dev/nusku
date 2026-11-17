import type { Range, Window } from "./types";

export function inRange(window: Window, range: Range): boolean {
  const middle = window.startMs + window.durationMs / 2;
  return middle >= range.fromMs && middle <= range.toMs;
}
