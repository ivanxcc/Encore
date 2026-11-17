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
export const relayToken = saved<{ value: string; expiresAt: number; admin?: boolean } | null>("relay", null);
export const profileId = saved<string | null>("profile", null);
export const config = signal<{ cloud: string }>({ cloud: "" });
/** An invitation to this relay, from a link someone shared, until it has been used. */
export const pendingInvite = saved<string | null>("invite", null);

/** Settings › Playback, kept on this device. */
export interface Prefs {
  /** Preferred audio language (ISO 639-1), "" for the browser's. */
  audioLanguage: string;
  /** Subtitles to turn on by themselves: "off", or a language. */
  subtitles: string;
  autoplayNext: boolean;
  skipIntros: boolean;
  /** The sharpest source to choose. Lower starts faster and uses less data. */
  quality: "best" | "1080p" | "720p";
  /** Ready a few seconds of a title when its page has been open a moment, so Play starts at once. */
  prepareAhead: boolean;
  v?: number;
}
const defaultPrefs: Prefs = { audioLanguage: "en", subtitles: "off", autoplayNext: true, skipIntros: false, quality: "best", prepareAhead: true, v: 2 };
export const prefs = saved<Prefs>("prefs", defaultPrefs);
// Version 2: English unless chosen otherwise (it was the device's language).
prefs.value = { ...defaultPrefs, ...prefs.value, ...(prefs.value.v !== 2 && !prefs.value.audioLanguage ? { audioLanguage: "en" } : {}), v: 2 };
export const setPref = <K extends keyof Prefs>(key: K, value: Prefs[K]) => { prefs.value = { ...prefs.value, [key]: value }; };
/** The audio language to ask for: the chosen one, else the browser's. */
export const audioLanguage = () => prefs.value.audioLanguage || (navigator.language || "en").slice(0, 2).toLowerCase();

/** Whether the device has a connection. */
export const online = signal(navigator.onLine);
addEventListener("online", () => { online.value = true; });
addEventListener("offline", () => { online.value = false; });

// MARK: Router

const TABS = ["/", "/search", "/list", "/settings"];
const isTab = (p: string) => TABS.includes(p.split("?")[0]);

export const path = signal(location.pathname + location.search);

addEventListener("popstate", () => {
  const to = location.pathname + location.search;
  const change = () => { path.value = to; };
  if (isTab(path.value) && isTab(to)) change(); else transition(change);
});

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
  const from = path.value;
  if (options.replace) history.replaceState(null, "", to); else history.pushState(null, "", to);
  const change = () => {
    path.value = to;
    if (!to.startsWith("/watch")) scrollTo(0, 0);
  };
  // Between tabs the page changes at once, as a tab bar does; the bar itself never moves. Into and
  // out of a title, the browser's cross-fade.
  if (isTab(from) && isTab(to)) change(); else transition(change);
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
