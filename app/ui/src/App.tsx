import { Activity } from "react";
import { AppShell } from "./components/layout/AppShell";
import { useRoute } from "./lib/router";
import { ProcessesPage } from "./pages/processes";
import { SessionPage } from "./pages/session";
import { SessionsPage } from "./pages/sessions";
import { RunsPage } from "./pages/runs";
import { RunPage } from "./pages/run";

export default function App() {
  const route = useRoute();
  const job = route.current === "sessions" ? Number(route.params?.["0"]) : NaN;
  const run = route.current === "runs" ? Number(route.params?.["0"]) : NaN;
  const shown = (page: string) =>
    route.current === page && Number.isNaN(job) && Number.isNaN(run)
      ? "visible"
      : "hidden";

  return (
    <AppShell>
      <Activity mode={shown("processes")}>
        <ProcessesPage />
      </Activity>
      <Activity mode={shown("sessions")}>
        <SessionsPage />
      </Activity>
      <Activity mode={shown("runs")}>
        <RunsPage />
      </Activity>
      {!Number.isNaN(job) && <SessionPage key={job} job={job} />}
      {!Number.isNaN(run) && <RunPage key={run} id={run} />}
    </AppShell>
  );
}
