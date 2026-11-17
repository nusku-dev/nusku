import type { LucideIcon } from "lucide-react";
import {
  Cpu,
  HardDrive,
  Hourglass,
  Lock,
  MemoryStick,
  Network,
  Timer,
} from "lucide-react";

export interface MetricDef {
  id: string;
  label: string;
  description: string;
  icon: LucideIcon;
  ready: boolean;
}

export const metrics: MetricDef[] = [
  {
    id: "cpu",
    label: "CPU",
    description: "What is running on the CPU, sampled 99 times a second.",
    icon: Cpu,
    ready: true,
  },
  {
    id: "offcpu",
    label: "Off-CPU",
    description:
      "Where threads wait instead of run: locks, disk, network, sleep.",
    icon: Hourglass,
    ready: false,
  },
  {
    id: "mem",
    label: "Memory",
    description: "What allocates memory, how much, and what of it stays live.",
    icon: MemoryStick,
    ready: false,
  },
  {
    id: "io",
    label: "Disk I/O",
    description: "Reads and writes to disk, and the code that asked for them.",
    icon: HardDrive,
    ready: false,
  },
  {
    id: "net",
    label: "Network",
    description: "Traffic, latency and retransmits, per call site.",
    icon: Network,
    ready: false,
  },
  {
    id: "locks",
    label: "Locks",
    description: "Time spent waiting for a lock, and who held it.",
    icon: Lock,
    ready: false,
  },
  {
    id: "sched",
    label: "Scheduler",
    description: "Run-queue delay: ready to run, but waiting for a CPU.",
    icon: Timer,
    ready: false,
  },
];
