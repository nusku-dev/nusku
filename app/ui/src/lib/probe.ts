import type { ProbeGetWire, ProbePointWire } from "./backend";
import { num } from "./profile/wire";

export const buckets = 64;

export interface ProbePoint {
  index: number;
  startMs: number;
  durationMs: number;
  calls: number;
  timed: number;
  totalNs: number;
  maxNs: number;
  histogram: number[];
}

export interface Interval {
  atMs: number;
  callsPerS: number;
  meanNs: number | null;
  p99Ns: number | null;
}

export interface ProbeFigures {
  calls: number;
  timed: number;
  totalNs: number;
  maxNs: number;
  meanNs: number | null;
  p50Ns: number | null;
  p90Ns: number | null;
  p99Ns: number | null;
  callsPerS: number | null;
  histogram: number[];
}

export const shortCallNs = 10_000;
export const busyCallsPerS = 10_000;

export function pointOf(wire: ProbePointWire, index: number): ProbePoint {
  const histogram = new Array<number>(buckets).fill(0);
  for (const [bucket, count] of wire.h) histogram[bucket] = num(count);
  return {
    index,
    startMs: num(wire.t),
    durationMs: num(wire.d),
    calls: num(wire.c),
    timed: num(wire.n),
    totalNs: num(wire.s),
    maxNs: num(wire.m),
    histogram,
  };
}

export function pointsOf(wire: ProbeGetWire): ProbePoint[] {
  return wire.points.map((p, i) => pointOf(p, wire.first + i));
}

export function bucketLow(bucket: number): number {
  return bucket === 0 ? 0 : 2 ** (bucket - 1);
}

export function percentileBound(
  histogram: number[],
  timed: number,
  perMille: number,
  maxNs: number,
): number | null {
  if (timed <= 0) return null;
  const wanted = Math.ceil((timed * perMille) / 1000);
  let seen = 0;
  for (let bucket = 0; bucket < histogram.length; bucket++) {
    seen += histogram[bucket];
    if (seen >= wanted) return Math.min(bucketLow(bucket + 1), maxNs);
  }
  return maxNs;
}

export function intervalsOf(points: ProbePoint[]): Interval[] {
  const out: Interval[] = [];
  for (let i = 1; i < points.length; i++) {
    const a = points[i - 1];
    const b = points[i];
    if (b.index !== a.index + 1 || b.durationMs <= 0) continue;
    const timed = b.timed - a.timed;
    const delta = b.histogram.map(
      (count, bucket) => count - a.histogram[bucket],
    );
    out.push({
      atMs: b.startMs + b.durationMs,
      callsPerS: ((b.calls - a.calls) * 1000) / b.durationMs,
      meanNs: timed > 0 ? (b.totalNs - a.totalNs) / timed : null,
      p99Ns: timed > 0 ? percentileBound(delta, timed, 990, b.maxNs) : null,
    });
  }
  return out;
}

export function figuresOf(points: ProbePoint[]): ProbeFigures {
  const last = points.at(-1);
  const intervals = intervalsOf(points.slice(-2));
  if (!last) {
    return {
      calls: 0,
      timed: 0,
      totalNs: 0,
      maxNs: 0,
      meanNs: null,
      p50Ns: null,
      p90Ns: null,
      p99Ns: null,
      callsPerS: null,
      histogram: new Array<number>(buckets).fill(0),
    };
  }
  const bound = (perMille: number) =>
    percentileBound(last.histogram, last.timed, perMille, last.maxNs);
  return {
    calls: last.calls,
    timed: last.timed,
    totalNs: last.totalNs,
    maxNs: last.maxNs,
    meanNs: last.timed > 0 ? last.totalNs / last.timed : null,
    p50Ns: bound(500),
    p90Ns: bound(900),
    p99Ns: bound(990),
    callsPerS: intervals.at(-1)?.callsPerS ?? null,
    histogram: last.histogram,
  };
}
