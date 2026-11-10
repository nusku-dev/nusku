import { Activity } from "react";
import { AppShell } from "./components/layout/AppShell";
import { useRoute } from "./lib/router";
import { ProcessesPage } from "./pages/processes";

export default function App() {
  const route = useRoute();
  const shown = (page: string) =>
    route.current === page ? "visible" : "hidden";

  return (
    <AppShell>
      <Activity mode={shown("processes")}>
        <ProcessesPage />
      </Activity>
      <Activity mode={shown("sessions")}>
        <h1>sessions</h1>
      </Activity>
    </AppShell>
  );
}
