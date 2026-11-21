import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { ThemeProvider } from "next-themes";
import "./style.css";
import App from "./App.tsx";
import { MachineProvider } from "@/components/machine-provider";
import { ProfilesProvider } from "@/components/profiles-provider";
import { StoreRunsProvider } from "./components/store_runs_provider.tsx";

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <ThemeProvider
      attribute="class"
      defaultTheme="dark"
      enableSystem
      disableTransitionOnChange
    >
      <MachineProvider>
        <ProfilesProvider>
          <StoreRunsProvider>
            <App />
          </StoreRunsProvider>
        </ProfilesProvider>
      </MachineProvider>
    </ThemeProvider>
  </StrictMode>,
);
