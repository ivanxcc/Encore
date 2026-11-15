// Everything the app talks to: the Stremio account, its add-ons, Encore Cloud, and the relay.
import { auth, config, pendingInvite, relayToken, imdbOf } from "./core";

// MARK: Types (the Stremio add-on protocol, as much of it as Encore uses)

export interface Meta {
  id: string; type: string; name: string;
  poster?: string; background?: string; logo?: string; description?: string;
  releaseInfo?: string; imdbRating?: string; genres?: string[]; runtime?: string;
  videos?: Video[]; cast?: string[];
}
export interface Video { id: string; title?: string; name?: string; season?: number; episode?: number; number?: number; released?: string; thumbnail?: string; overview?: string; description?: string }
export interface Stream { url?: string; infoHash?: string; name?: string; title?: string; description?: string; behaviorHints?: { filename?: string; proxyHeaders?: { request?: Record<string, string> } } }
export interface Catalog { type: string; id: string; name?: string; extra?: { name: string; isRequired?: boolean }[]; extraRequired?: string[] }
export interface Addon { transportUrl: string; manifest: { id: string; name: string; types?: string[]; idPrefixes?: string[]; resources?: (string | { name: string; types?: string[]; idPrefixes?: string[] })[]; catalogs?: Catalog[] } }
export interface CatalogRef { addon: Addon; catalog: Catalog; title: string; key: string }
export interface LibraryItem {
  _id: string; name: string; type: string; poster?: string; removed?: boolean; temp?: boolean; _ctime?: string; _mtime?: string;
  state: { lastWatched?: string; timeWatched?: number; timeOffset?: number; duration?: number; video_id?: string; timesWatched?: number; flaggedWatched?: number; watched?: string };
}
export interface Profile { id: string; name: string; avatar?: string; colorIndex?: number; isOwner?: boolean; isKids?: boolean; pinHash?: string | null }
export interface Household { name?: string; profiles: Profile[]; libraries?: Record<string, LibraryItem[]>; watched?: Record<string, Record<string, { watched: boolean; at: string }>> }
export interface Extras { tmdbId?: number; backdrop?: string; logo?: string; tagline?: string; certification?: string; runtime?: number; cast?: { name: string; character?: string; photo?: string }[]; crew?: { name: string; job: string }[]; trailer?: { site: string; key: string } }
export interface Trending { imdbId: string; type: string; name: string; backdrop?: string; logo?: string; overview?: string; year?: string; genres?: string[]; rating?: number }

async function json<T>(url: string, init?: RequestInit, timeoutMs = 15000): Promise<T> {
  const control = new AbortController();
  const timer = setTimeout(() => control.abort(), timeoutMs);
  try {
    const r = await fetch(url, { ...init, signal: control.signal });
    if (!r.ok) throw Object.assign(new Error(`HTTP ${r.status}`), { status: r.status, body: await r.json().catch(() => null) });
    return (await r.json()) as T;
  } finally {
    clearTimeout(timer);
  }
}

// MARK: Stremio account

export async function stremio<T>(method: string, body: object): Promise<T> {
  const out = await json<{ result?: T; error?: { message?: string } }>("https://api.strem.io/api/" + method, { method: "POST", body: JSON.stringify(body) });
  if (out.error || out.result === undefined) throw new Error(out.error?.message || "Stremio didn't answer.");
  return out.result;
}

export async function signIn(email: string, password: string) {
  const result = await stremio<{ authKey: string; user: { email: string } }>("login", { type: "Login", email, password, facebook: false });
  auth.value = { key: result.authKey, email: result.user?.email || email };
}

const DEFAULT_ADDONS: Addon[] = [{
  transportUrl: "https://v3-cinemeta.strem.io/manifest.json",
  manifest: {
    id: "com.linvo.cinemeta", name: "Cinemeta", types: ["movie", "series"], idPrefixes: ["tt"],
    resources: ["catalog", "meta"],
    catalogs: [
      { type: "movie", id: "top", name: "Popular", extra: [{ name: "search" }, { name: "genre" }, { name: "skip" }] },
      { type: "series", id: "top", name: "Popular", extra: [{ name: "search" }, { name: "genre" }, { name: "skip" }] },
    ],
  },
}];

let addonsPromise: Promise<Addon[]> | null = null;

/** The account's add-ons. Remembered from the last visit so Home draws at once, then refreshed. */
export function addons(): Promise<Addon[]> {
  if (addonsPromise) return addonsPromise;
  const key = auth.value?.key;
  let remembered: Addon[] | null = null;
  try { remembered = JSON.parse(localStorage.getItem("encore.addons") || "null"); } catch {}
  const fresh = (key
    ? stremio<{ addons: Addon[] }>("addonCollectionGet", { type: "AddonCollectionGet", authKey: key, update: true }).then((r) => r.addons || [])
    : Promise.resolve(DEFAULT_ADDONS)
  ).then((list) => {
    const usable = list.filter((a) => a && a.transportUrl && a.manifest);
    try { localStorage.setItem("encore.addons", JSON.stringify(usable)); } catch {}
    return usable.length ? usable : DEFAULT_ADDONS;
  }).catch(() => remembered || DEFAULT_ADDONS);
  addonsPromise = remembered && remembered.length ? Promise.resolve(remembered) : fresh;
  if (remembered) fresh.then((list) => { addonsPromise = Promise.resolve(list); });
  return addonsPromise;
}

export function forgetSession() {
  addonsPromise = null;
  for (const key of ["addons", "library", "household"]) { try { localStorage.removeItem("encore." + key); } catch {} }
}

// MARK: Add-ons

const base = (a: Addon) => a.transportUrl.replace(/\/manifest\.json$/, "");

function supports(a: Addon, resource: string, type: string, id: string): boolean {
  const m = a.manifest;
  for (const r of m.resources || []) {
    const name = typeof r === "string" ? r : r.name;
    if (name !== resource) continue;
    const types = (typeof r === "object" && r.types) || m.types || [];
    const prefixes = (typeof r === "object" && r.idPrefixes) || m.idPrefixes;
    if (types.includes(type) && (!prefixes || prefixes.some((p) => id.startsWith(p)))) return true;
  }
  return false;
}

const typeName: Record<string, string> = { movie: "Movies", series: "Shows", channel: "Channels", tv: "Live TV", anime: "Anime" };

/** The catalogs to show as shelves: every one that needs nothing more than its name to load. */
export async function shelves(): Promise<CatalogRef[]> {
  const out: CatalogRef[] = [];
  for (const addon of await addons()) {
    for (const catalog of addon.manifest.catalogs || []) {
      const required = new Set([...(catalog.extraRequired || []), ...(catalog.extra || []).filter((e) => e.isRequired).map((e) => e.name)]);
      if (required.size) continue;
      const kind = typeName[catalog.type] || catalog.type;
      const name = catalog.name || catalog.id;
      out.push({ addon, catalog, title: name.toLowerCase().includes(kind.toLowerCase().replace(/s$/, "")) ? name : `${name} ${kind}`, key: `${addon.manifest.id}|${catalog.type}|${catalog.id}` });
    }
  }
  return out;
}

const catalogCache = new Map<string, Promise<Meta[]>>();

export function catalog(ref: CatalogRef, extra?: [string, string]): Promise<Meta[]> {
  const suffix = extra ? `/${extra[0]}=${encodeURIComponent(extra[1])}` : "";
  const url = `${base(ref.addon)}/catalog/${ref.catalog.type}/${encodeURIComponent(ref.catalog.id)}${suffix}.json`;
  let hit = catalogCache.get(url);
  if (!hit) {
    hit = json<{ metas?: Meta[] }>(url).then((r) => dedupe((r.metas || []).filter((m) => m && m.id && m.name)));
    hit.catch(() => catalogCache.delete(url));
    catalogCache.set(url, hit);
  }
  return hit;
}

function dedupe(metas: Meta[]): Meta[] {
  const seen = new Set<string>();
  return metas.filter((m) => !seen.has(m.id) && seen.add(m.id));
}

/** Search every add-on that can, calling back as each answers. */
export async function search(query: string, onPartial: (results: { ref: CatalogRef; metas: Meta[] }[]) => void, signal: AbortSignal) {
  const refs: CatalogRef[] = [];
  for (const addon of await addons()) {
    for (const c of addon.manifest.catalogs || []) {
      if ((c.extra || []).some((e) => e.name === "search") || (c.extraRequired || []).includes("search")) {
        refs.push({ addon, catalog: c, title: `${typeName[c.type] || c.type}${addon.manifest.name === "Cinemeta" ? "" : " · " + addon.manifest.name}`, key: `${addon.manifest.id}|${c.type}|${c.id}` });
      }
    }
  }
  const results: { ref: CatalogRef; metas: Meta[]; order: number }[] = [];
  await Promise.all(refs.map(async (ref, order) => {
    try {
      const metas = await catalog(ref, ["search", query]);
      if (signal.aborted || !metas.length) return;
      results.push({ ref, metas, order });
      onPartial(results.slice().sort((a, b) => a.order - b.order));
    } catch {}
  }));
}

const metaCache = new Map<string, Promise<Meta>>();

/** A title's details: the first add-on (in the account's order) that has them. */
export function meta(type: string, id: string): Promise<Meta> {
  const key = type + "|" + id;
  let hit = metaCache.get(key);
  if (!hit) {
    hit = (async () => {
      for (const a of await addons()) {
        if (!supports(a, "meta", type, id)) continue;
        try {
          const r = await json<{ meta?: Meta }>(`${base(a)}/meta/${type}/${encodeURIComponent(id)}.json`);
          if (r.meta && r.meta.id) return r.meta;
        } catch {}
      }
      throw new Error("No add-on has this title.");
    })();
    hit.catch(() => metaCache.delete(key));
    metaCache.set(key, hit);
  }
  return hit;
}

export async function streams(type: string, videoId: string): Promise<Stream[]> {
  const lists = await Promise.all((await addons()).filter((a) => supports(a, "stream", type, videoId)).map(async (a) => {
    try {
      return (await json<{ streams?: Stream[] }>(`${base(a)}/stream/${type}/${encodeURIComponent(videoId)}.json`, undefined, 20000)).streams || [];
    } catch { return []; }
  }));
  return lists.flat();
}

export interface AddonSubtitle { id: string; url: string; lang: string; source: string }

/** Subtitles the account's subtitle add-ons (OpenSubtitles and the like) offer for a film or episode. */
export async function addonSubtitles(type: string, videoId: string): Promise<AddonSubtitle[]> {
  const lists = await Promise.all((await addons()).filter((a) => supports(a, "subtitles", type, videoId)).map(async (a) => {
    try {
      const body = await json<{ subtitles?: { id?: string; url: string; lang: string }[] }>(`${base(a)}/subtitles/${type}/${encodeURIComponent(videoId)}.json`, undefined, 12000);
      return (body.subtitles || []).filter((x) => x.url && /^https?:/.test(x.url)).map((x, i) => ({ id: x.id || `${a.manifest.id}:${i}`, url: x.url, lang: x.lang, source: a.manifest.name }));
    } catch { return []; }
  }));
  return lists.flat();
}

// MARK: Artwork

const hub = (kind: string, size: string, id: string) => { const tt = imdbOf(id); return tt ? `https://images.metahub.space/${kind}/${size}/${tt}/img` : undefined; };
const sharpen = (url: string | undefined, size: string) => url && url.includes("images.metahub.space") ? url.replace(/\/(small|medium|large)\//, `/${size}/`) : url;

export const art = {
  poster: (m: { id: string; poster?: string }) => sharpen(m.poster, "medium") || hub("poster", "medium", m.id),
  backdrop: (m: { id: string; background?: string; poster?: string }) => sharpen(m.background, "large") || hub("background", "large", m.id) || m.poster,
  wide: (m: { id: string; background?: string; poster?: string }) => sharpen(m.background, "medium") || hub("background", "medium", m.id) || m.poster,
  logo: (m: { id: string; logo?: string }) => sharpen(m.logo, "large") || hub("logo", "large", m.id),
};

// MARK: Encore Cloud

const cloud = () => config.value.cloud;
const stremioAuth = () => ({ authorization: "Stremio " + (auth.value?.key || "") });
const cloudCache = new Map<string, Promise<unknown>>();

function cached<T>(key: string, load: () => Promise<T>): Promise<T> {
  let hit = cloudCache.get(key) as Promise<T> | undefined;
  if (!hit) {
    hit = load();
    hit.catch(() => cloudCache.delete(key));
    cloudCache.set(key, hit);
  }
  return hit;
}

export const encore = {
  available: () => !!cloud(),
  pairStart: () => json<{ code: string; pollToken: string; expiresAt: number }>(cloud() + "/v1/pair/start", { method: "POST" }),
  /** null while waiting. */
  async pairPoll(token: string): Promise<{ authKey: string; email: string } | null> {
    const r = await fetch(cloud() + "/v1/pair/poll?token=" + encodeURIComponent(token));
    if (r.status === 202) return null;
    if (!r.ok) throw new Error("expired");
    return r.json();
  },
  pairPage: (code: string) => `${cloud()}/pair/${code.replace(/[^A-Za-z0-9]/g, "")}`,
  async household(): Promise<{ version: number; doc: Household } | null> {
    if (!cloud() || !auth.value) return null;
    try { return await json(cloud() + "/v1/household", { headers: stremioAuth() }); } catch { return null; }
  },
  putHousehold: (doc: Household, baseVersion: number) =>
    json<{ version: number }>(cloud() + "/v1/household", { method: "PUT", headers: { ...stremioAuth(), "content-type": "application/json" }, body: JSON.stringify({ baseVersion, doc }) }),
  extras(id: string, type: string): Promise<Extras | null> {
    const tt = imdbOf(id);
    if (!cloud() || !tt) return Promise.resolve(null);
    return cached(`title|${tt}|${type}`, () => json<Extras>(`${cloud()}/v1/title?imdb=${tt}&type=${type}`).catch(() => null));
  },
  trending: (): Promise<Trending[]> => !cloud() ? Promise.resolve([]) : cached("trending", () => json<{ items: Trending[] }>(cloud() + "/v1/trending").then((r) => r.items || []).catch(() => [])),
  runtimes(tmdbId: number, season: number): Promise<Record<number, number>> {
    return cached(`season|${tmdbId}|${season}`, () => json<{ episodes: { episode: number; runtime: number }[] }>(`${cloud()}/v1/season?tmdb=${tmdbId}&season=${season}`)
      .then((r) => Object.fromEntries(r.episodes.map((e) => [e.episode, e.runtime * 60]))).catch(() => ({})));
  },
  /** Intro, recap, and credits markers, in seconds. */
  async skip(id: string, season: number | undefined, episode: number | undefined, duration: number): Promise<{ kind: "intro" | "recap" | "credits"; start: number; end: number }[]> {
    const tt = imdbOf(id);
    if (!cloud() || !tt) return [];
    const q = new URLSearchParams({ imdb: tt, duration_ms: String(Math.round(duration * 1000)) });
    if (season != null) q.set("season", String(season));
    if (episode != null) q.set("episode", String(episode));
    try {
      const body = await json<Record<string, { start_ms: number | null; end_ms: number | null }[] | null>>(`${cloud()}/v1/skip?${q}`);
      const out: { kind: "intro" | "recap" | "credits"; start: number; end: number }[] = [];
      for (const kind of ["intro", "recap", "credits"] as const) {
        for (const s of body[kind] || []) {
          const start = (s.start_ms ?? 0) / 1000, end = s.end_ms == null ? duration : s.end_ms / 1000;
          // A marker must be a real stretch inside the video ("credits from 0:00" is no marker).
          if (end - start >= 5 && end <= duration + 1 && !(kind === "credits" && start < duration * 0.5)) out.push({ kind, start, end });
        }
      }
      return out;
    } catch { return []; }
  },
};

// MARK: Relay (this site)

export interface TrackInfo { index: number; codec: string; language?: string; name?: string; channels?: number; default?: boolean; forced?: boolean; text?: boolean }
export interface Decision { mode: "direct" | "remux" | "unsupported" | "error"; reason?: string; url?: string; id?: string; playlist?: string; duration?: number; audioCopied?: boolean; audio?: TrackInfo; audioTracks?: TrackInfo[]; subtitles?: TrackInfo[]; video?: { codec?: string; width?: number; height?: number }; timings?: { openMs: number; indexMs: number } }
export interface Cue { start: number; end: number; text: string }

/** A subtitle track's cues the relay has found so far, after the first `after`. */
export async function relayCues(sessionId: string, track: number, after: number): Promise<{ cues: Cue[]; total: number }> {
  return json(`/v1/s/${sessionId}/subs/${track}?after=${after}`, undefined, 10000);
}

/** An add-on's subtitle file, read and converted by the relay. */
export const subtitleFile = (url: string) => relayCall<{ cues: Cue[] }>(`/v1/subtitle?url=${encodeURIComponent(url)}`).then((b) => b.cues);

export class NeedsCode extends Error {}

/** A token for the relay: remembered, renewed a day before it runs out, asked for with the sign-in. */
export async function relayAuth(code?: string): Promise<string> {
  const now = Date.now() / 1000;
  const have = relayToken.value;
  if (!code && have && have.expiresAt - now > 86400) return have.value;
  // A link someone shared stands in for the code, once.
  const invite = code ? undefined : pendingInvite.value || undefined;
  const r = await fetch("/v1/auth", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ authKey: auth.value?.key, code, invite }) });
  const body = await r.json().catch(() => ({}));
  if (invite && r.status !== 401) pendingInvite.value = null;
  if (r.status === 403 && body.needsCode) throw new NeedsCode(code || invite ? body.error : "");
  if (!r.ok) throw new Error(body.error || "The relay refused this sign-in.");
  relayToken.value = { value: body.token, expiresAt: body.expiresAt, admin: !!body.admin };
  return body.token;
}

async function relayCall<T>(path: string, init: RequestInit = {}): Promise<T> {
  const token = await relayAuth();
  return json<T>(path, { ...init, headers: { ...(init.headers || {}), "content-type": "application/json", authorization: "Bearer " + token } });
}

/** A link that lets one more Stremio account use this server, once, within 7 days. */
export async function relayInvite(): Promise<{ link: string; expiresAt: number }> {
  const body = await relayCall<{ invite: string; expiresAt: number }>("/v1/invite", { method: "POST" });
  return { link: `${location.origin}/join#${body.invite}`, expiresAt: body.expiresAt };
}

export interface RelayPerson { email: string; admin: boolean; invitedBy?: string; since?: number; you?: boolean }
export const relayPeople = () => relayCall<{ people: RelayPerson[] }>("/v1/people").then((b) => b.people);
export const relayRemove = (email: string) => relayCall(`/v1/people/${encodeURIComponent(email)}`, { method: "DELETE" });

export async function relaySession(body: object): Promise<Decision> {
  const token = await relayAuth();
  try {
    return await json<Decision>("/v1/session", { method: "POST", headers: { "content-type": "application/json", authorization: "Bearer " + token }, body: JSON.stringify(body) }, 30000);
  } catch (e) {
    const err = e as { status?: number; body?: { error?: string } };
    if (err.status === 401) relayToken.value = null;
    return { mode: "error", reason: err.body?.error || (e as Error).message };
  }
}

export function relayClose(id: string) {
  fetch(`/v1/s/${id}`, { method: "DELETE", keepalive: true }).catch(() => {});
}
