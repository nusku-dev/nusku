import { Activity } from "react";
import { AppShell } from "./components/layout/AppShell";
import { useRoute } from "./lib/router";
import { ProcessesPage } from "./pages/processes";
import { SessionPage } from "./pages/session";
import { SessionsPage } from "./pages/sessions";

export default function App() {
  const route = useRoute();
  const job = route.current === "sessions" ? Number(route.params?.["0"]) : NaN;
  const shown = (page: string) =>
    route.current === page && Number.isNaN(job) ? "visible" : "hidden";

  return (
    <AppShell>
      <Activity mode={shown("processes")}>
        <ProcessesPage />
      </Activity>
      <Activity mode={shown("sessions")}>
        <SessionsPage />
      </Activity>
      {!Number.isNaN(job) && <SessionPage key={job} job={job} />}
    </AppShell>
  );
}
