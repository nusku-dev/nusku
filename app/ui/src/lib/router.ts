import { useSyncExternalStore } from "react";

export const Routes = {
  processes: "processes",
  sessions: "sessions",
} as const;

export type Routes = (typeof Routes)[keyof typeof Routes];

type Route = {
  current: Routes;
  params?: Record<string, string>;
  query?: Record<string, string>;
};

type RouteDetails = {
  params?: Record<string, string>;
  query?: Record<string, string>;
};

const routeNames = new Set<string>(Object.values(Routes));

function parse(hash: string): Route {
  const [path, search = ""] = hash.replace(/^#\/?/, "").split("?");
  const [name, ...segments] = path.split("/").filter(Boolean);

  const current = routeNames.has(name)
    ? (name as Routes)
    : Routes.processes;

  const query = Object.fromEntries(new URLSearchParams(search));

  return {
    current,
    ...(segments.length && {
      params: Object.fromEntries(
        segments.map((value, index) => [index.toString(), value]),
      ),
    }),
    ...(Object.keys(query).length && { query }),
  };
}

const getSnapshot = () => window.location.hash;

const subscribe = (callback: () => void) => {
  window.addEventListener("hashchange", callback);
  return () => window.removeEventListener("hashchange", callback);
};

function nav(name: Routes, details?: RouteDetails) {
  const path = [
    name,
    ...Object.values(details?.params ?? {}).map(encodeURIComponent),
  ].join("/");

  const query = new URLSearchParams(details?.query).toString();

  const url = `#/${path}${query ? `?${query}` : ""}`;

  return {
    href: () => url,
    go: () => {
      window.location.hash = url.slice(1);
    },
  };
}

export function useRoute() {
  const hash = useSyncExternalStore(
    subscribe,
    getSnapshot,
    () => "",
  );

  const route = parse(hash);

  return {
    ...route,
    nav,
  };
}
