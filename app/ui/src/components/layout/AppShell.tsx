import { Routes, useRoute } from "@/lib/router";
import { useEffect, useState, type ReactNode } from "react";
import {
  Activity,
  Bookmark,
  Monitor,
  Moon,
  Sun,
  TerminalSquare,
} from "lucide-react";
import { cn } from "cn";
import { useTheme } from "next-themes";
import { onConnection } from "@/lib/backend";
import { LiveDot } from "@/components/session-status";
import { useProfiles } from "@/hooks/use-profiles";

export function AppShell({ children }: { children: ReactNode }) {
  return (
    <div className="flex h-screen overflow-hidden bg-background">
      <Sidebar />
      <main className="flex min-w-0 flex-1 flex-col overflow-hidden">
        {children}
      </main>
    </div>
  );
}

function Sidebar() {
  const route = useRoute();
  const process = route.nav(Routes.processes).href;
  const sessions = route.nav(Routes.sessions).href;
  const runs = route.nav(Routes.runs).href;
  const live = useProfiles().sessions.filter((s) => s.running);
  const openJob =
    route.current === "sessions" ? route.params?.["0"] : undefined;

  return (
    <aside className="flex w-60 shrink-0 flex-col border-r bg-sidebar text-sidebar-foreground">
      <a
        href={process()}
        className="flex h-14 items-center gap-2.5 border-b px-4"
      >
        <img src="/nusku.png" alt="" className="size-7 object-contain" />
        <span className="text-base font-semibold tracking-tight">Nusku</span>
      </a>

      <nav className="space-y-0.5 p-2">
        <NavLink
          to={process}
          icon={TerminalSquare}
          active={route.current === "processes"}
        >
          Processes
        </NavLink>
        <NavLink
          to={sessions}
          icon={Activity}
          active={route.current === "sessions"}
        >
          Sessions
        </NavLink>
        <NavLink to={runs} icon={Bookmark} active={route.current === "runs"}>
          Saved runs
        </NavLink>
      </nav>

      {live.length > 0 && (
        <div className="px-2 pt-3">
          <p className="px-2 pb-1.5 text-[11px] font-medium tracking-wider text-muted-foreground uppercase">
            Live now
          </p>
          <ul className="space-y-0.5">
            {live.map((s) => (
              <li key={s.job}>
                <a
                  href={route
                    .nav(Routes.sessions, { params: { 0: String(s.job) } })
                    .href()}
                  className={cn(
                    "flex items-center gap-2.5 px-2 py-1.5 text-sm hover:bg-sidebar-accent",
                    openJob === String(s.job) && "bg-sidebar-accent",
                  )}
                >
                  <LiveDot />
                  <span className="min-w-0 flex-1 truncate">{s.name}</span>
                  <span className="text-xs text-muted-foreground tabular-nums">
                    {s.pid}
                  </span>
                </a>
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="flex-1" />
      <SidebarFooter />
    </aside>
  );
}

function NavLink({
  to,
  icon: Icon,
  active,
  children,
}: {
  to: () => string;
  icon: typeof Activity;
  active: boolean;
  children: ReactNode;
}) {
  return (
    <a
      href={to()}
      className={cn(
        "flex items-center gap-2.5 px-2 py-1.5 text-sm text-sidebar-foreground/80 hover:bg-sidebar-accent hover:text-sidebar-foreground",
        active && "bg-sidebar-accent font-medium text-sidebar-foreground",
      )}
    >
      <Icon className={cn("size-4", active && "text-primary")} />
      {children}
    </a>
  );
}

function SidebarFooter() {
  const [connected, setConnected] = useState(false);
  useEffect(() => onConnection(setConnected), []);

  return (
    <div className="space-y-3 border-t p-3">
      <div className="space-y-1 text-xs">
        <div className="flex items-center gap-2">
          <span
            className={cn(
              "size-1.5 rounded-full",
              connected ? "bg-emerald-500" : "bg-muted-foreground/50",
            )}
          />
          <span className="text-muted-foreground">
            {connected ? "Backend connected" : "Backend offline"}
          </span>
        </div>
      </div>
      <ThemeSwitch />
    </div>
  );
}

function ThemeSwitch() {
  const { theme, setTheme } = useTheme();
  const options = [
    { value: "light", icon: Sun, label: "Light" },
    { value: "dark", icon: Moon, label: "Dark" },
    { value: "system", icon: Monitor, label: "System" },
  ];
  return (
    <div
      className="grid grid-cols-3 border p-0.5"
      role="radiogroup"
      aria-label="Theme"
    >
      {options.map(({ value, icon: Icon, label }) => (
        <button
          key={value}
          type="button"
          role="radio"
          aria-checked={theme === value}
          title={label}
          onClick={() => setTheme(value)}
          className={cn(
            "grid h-6 place-items-center text-muted-foreground hover:text-foreground",
            theme === value && "bg-muted text-foreground",
          )}
        >
          <Icon className="size-3.5" />
        </button>
      ))}
    </div>
  );
}
