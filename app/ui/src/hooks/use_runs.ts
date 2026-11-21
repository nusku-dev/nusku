import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useState,
} from "react";
import { backend, type RunMeta, type SaveRequest } from "@/lib/backend";

export interface RunsState {
  runs: RunMeta[];
  error: Error | undefined;
  loading: boolean;
  save: (request: SaveRequest) => Promise<RunMeta>;
  relabel: (id: number, label: string, note: string) => Promise<void>;
  remove: (id: number) => Promise<void>;
}

export const RunsContext = createContext<RunsState | null>(null);

export function useRuns(): RunsState {
  const state = useContext(RunsContext);
  if (!state) throw new Error("useRuns needs a RunsProvider around the app");
  return state;
}

export function useStoreRuns(): RunsState {
  const [runs, setRuns] = useState<RunMeta[] | undefined>();
  const [error, setError] = useState<Error | undefined>();

  const reload = useCallback(async () => {
    try {
      setRuns(await backend.runsList());
      setError(undefined);
    } catch (e) {
      setError(e instanceof Error ? e : new Error(String(e)));
    }
  }, []);

  useEffect(() => {
    let alive = true;
    backend
      .runsList()
      .then((list) => alive && setRuns(list))
      .catch(
        (e: unknown) =>
          alive && setError(e instanceof Error ? e : new Error(String(e))),
      );
    return () => {
      alive = false;
    };
  }, []);

  const save = async (request: SaveRequest) => {
    const meta = await backend.runsSave(request);
    await reload();
    return meta;
  };
  const relabel = async (id: number, label: string, note: string) => {
    await backend.runsRelabel(id, label, note);
    await reload();
  };
  const remove = async (id: number) => {
    await backend.runsDelete(id);
    await reload();
  };

  return {
    runs: runs ?? [],
    error,
    loading: !runs && !error,
    save,
    relabel,
    remove,
  };
}
