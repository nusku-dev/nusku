import type { CompactWire, SummaryWire } from "@/lib/backend";
import { keyOf } from "./analyze";
import type { Frame, Profile, Window } from "./types";

export function profileOf(wire: CompactWire): Profile {
  const text = (index: number) =>
    index >= 0 ? (wire.strings[index] ?? null) : null;
  const keys = new Map<number, string>();
  const stacks = wire.stacks.map((stack) => ({
    id: stack.d,
    value: num(stack.n),
    complete: stack.c,
    frames: stack.f.map((packed): Frame => {
      const frame: Frame = {
        address: packed.a,
        kernel: packed.k,
        function: text(packed.f),
        file: text(packed.s),
        line: packed.l > 0 ? packed.l : null,
        module: text(packed.m),
        inlined: packed.i,
        key: "",
      };
      const pair =
        ((packed.f + 1) * 1_000_003 + packed.m + 1) * 2 + (packed.k ? 1 : 0);
      let key = keys.get(pair);
      if (key === undefined) {
        key = keyOf(frame);
        keys.set(pair, key);
      }
      frame.key = key;
      return frame;
    }),
  }));
  return {
    sampleHz: wire.sample_hz,
    total: stacks.reduce((sum, stack) => sum + stack.value, 0),
    lost: num(wire.samples_lost),
    rejected: num(wire.windows_rejected),
    stacks,
  };
}

export function num(value: number | string): number {
  return typeof value === "string" ? Number(value) : value;
}

export function windowsOf(wire: SummaryWire): Window[] {
  return wire.windows.map((w) => ({
    startMs: num(w.start_unix_ns) / 1e6,
    durationMs: num(w.duration_ns) / 1e6,
    samples: num(w.samples),
    lost: num(w.samples_lost),
  }));
}
