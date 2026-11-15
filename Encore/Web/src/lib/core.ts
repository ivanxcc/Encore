// The app's small core: saved state, the address-based router, and helpers shared by every screen.
import { signal, effect, type Signal } from "@preact/signals";

/** A signal kept in localStorage, so a reload (or the next visit) starts where this one left off. */
export function saved<T>(key: string, initial: T): Signal<T> {
  let value = initial;
  try {
    const raw = localStorage.getItem("encore." + key);
    if (raw != null) value = JSON.parse(raw) as T;
  } catch {}
  const s = signal<T>(value);
  let first = true;
  effect(() => {
    const v = s.value;
    if (first) { first = false; return; }
    try {
      if (v == null) localStorage.removeItem("encore." + key);
      else localStorage.setItem("encore." + key, JSON.stringify(v));
    } catch {}
  });
  return s;
}

export interface Auth { key: string; email: string }
export const auth = saved<Auth | null>("auth", null);
export const relayToken = saved<{ value: string; expiresAt: number } | null>("relay", null);
export const profileId = saved<string | null>("profile", null);
export const config = signal<{ cloud: string }>({ cloud: "" });

// MARK: Router

export const path = signal(location.pathname + location.search);

addEventListener("popstate", () => transition(() => { path.value = location.pathname + location.search; }));

/** Changes the page with the browser's own cross-fade where it has one. */
function transition(change: () => void) {
  const doc = document as Document & { startViewTransition?: (cb: () => void) => unknown };
  if (doc.startViewTransition && !matchMedia("(prefers-reduced-motion: reduce)").matches && !document.documentElement.classList.contains("lite")) {
    doc.startViewTransition(change);
  } else {
    change();
  }
}

export function go(to: string, options: { replace?: boolean } = {}) {
  if (to === path.value) return;
  if (options.replace) history.replaceState(null, "", to); else history.pushState(null, "", to);
  transition(() => {
    path.value = to;
    if (!to.startsWith("/watch")) scrollTo(0, 0);
  });
}

export function back(fallback = "/") {
  if (history.length > 1) history.back(); else go(fallback, { replace: true });
}

// MARK: Helpers

export function clock(seconds: number): string {
  if (!isFinite(seconds) || seconds < 0) seconds = 0;
  const s = Math.floor(seconds % 60), m = Math.floor(seconds / 60) % 60, h = Math.floor(seconds / 3600);
  const two = (n: number) => String(n).padStart(2, "0");
  return h > 0 ? `${h}:${two(m)}:${two(s)}` : `${m}:${two(s)}`;
}

/** "22m", "1h 5m". */
export function minutes(seconds: number): string {
  const m = Math.max(1, Math.round(seconds / 60));
  return m >= 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m}m`;
}

export function imdbOf(id: string): string | null {
  const base = id.split(":")[0];
  return /^tt\d+$/.test(base) ? base : null;
}

/** Older, slower hardware (a car's browser): no blur, no cross-fades, fewer moving parts. */
export const lite = (() => {
  const ua = navigator.userAgent;
  const apple = /iPhone|iPad|Macintosh/.test(ua);
  const tesla = /Tesla|QtCarBrowser/i.test(ua);
  return tesla || (!apple && (navigator.hardwareConcurrency || 8) <= 4);
})();
if (lite) document.documentElement.classList.add("lite");
