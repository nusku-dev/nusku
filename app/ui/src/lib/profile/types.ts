import type { StopReason } from "@/lib/backend";

export interface Frame {
  address: string;
  kernel: boolean;
  function: string | null;
  file: string | null;
  line: number | null;
  module: string | null;
  inlined: boolean;
  key: string;
}

export interface Stack {
  id: number;
  value: number;
  frames: Frame[];
  complete: boolean;
}

export interface Profile {
  sampleHz: number;
  total: number;
  lost: number;
  rejected: number;
  stacks: Stack[];
}

export interface Window {
  startMs: number;
  durationMs: number;
  samples: number;
  lost: number;
}

export interface Range {
  fromMs: number;
  toMs: number;
}

export interface Session {
  job: number;
  pid: number;
  name: string;
  command: string;
  running: boolean;
  users: number;
  mine: boolean;
  elapsedMs: number;
  startedAt: number;
  reason: StopReason | null;
  failure: string | null;
  samples: number;
  lost: number;
  sampleHz: number;
  windows: Window[];
}
