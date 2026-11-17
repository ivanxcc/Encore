// Choosing a source and getting it ready to play, ahead of the Play button.
import { audioLanguage, prefs } from "./core";
import { relaySession, relayClose, streams, type Decision, type Meta, type Stream, type Video } from "./api";

export interface Capabilities { video: string[]; audio: string[]; nativeHls: boolean; mse: boolean }

export const caps: Capabilities = (() => {
  const v = document.createElement("video");
  const w = window as unknown as { ManagedMediaSource?: typeof MediaSource; MediaSource?: typeof MediaSource };
  const MS = w.ManagedMediaSource || w.MediaSource;
  const can = (mime: string) => !!(MS && MS.isTypeSupported && MS.isTypeSupported(mime)) || v.canPlayType(mime) !== "";
  const video: string[] = [], audio: string[] = [];
  if (can('video/mp4; codecs="avc1.640028"')) video.push("h264");
  if (can('video/mp4; codecs="hvc1.1.6.L120.90"')) video.push("hevc");
  if (can('video/mp4; codecs="av01.0.08M.08"')) video.push("av1");
  if (can('audio/mp4; codecs="mp4a.40.2"')) audio.push("aac");
  if (can('audio/mp4; codecs="ac-3"')) audio.push("ac3");
  if (can('audio/mp4; codecs="ec-3"')) audio.push("eac3");
  if (can('audio/mp4; codecs="opus"')) audio.push("opus");
  return { video, audio, nativeHls: v.canPlayType("application/vnd.apple.mpegurl") !== "", mse: !!MS };
})();

/** Safari plays HLS itself, more efficiently than a script can, and decodes Dolby audio. */
export const useNativeHls = (() => {
  const ua = navigator.userAgent;
  const safari = /Safari/.test(ua) && !/Chrome|Chromium|CriOS|Android|Edg\//.test(ua);
  return caps.nativeHls && (safari || !caps.mse);
})();

export interface Candidate {
  label: string; url: string; headers?: Record<string, string>; score: number; quality: string;
  /** For the source list: the add-on's line, the size, the languages it says it has, ready now. */
  name: string; size?: string; langs: string[]; cached: boolean; hdr: boolean; hevc: boolean;
}

// Flags add-ons use for a release's languages, by country.
const FLAG_LANG: Record<string, string> = { GB: "en", US: "en", AU: "en", CA: "en", RU: "ru", IT: "it", ES: "es", MX: "es", AR: "es",
  FR: "fr", DE: "de", PT: "pt", BR: "pt", PL: "pl", UA: "uk", TR: "tr", JP: "ja", KR: "ko", CN: "zh", TW: "zh", HK: "zh", IN: "hi",
  NL: "nl", SE: "sv", NO: "no", DK: "da", FI: "fi", CZ: "cs", GR: "el", HU: "hu", RO: "ro", IL: "he", SA: "ar", AE: "ar",
  TH: "th", VN: "vi", ID: "id", BG: "bg", HR: "hr", RS: "sr", SK: "sk", SI: "sl", IR: "fa" };
const WORD_LANG: [RegExp, string][] = [
  [/\b(english|eng)\b/, "en"], [/\b(russian|rus)\b/, "ru"], [/\b(italian|ita)\b/, "it"], [/\b(french|truefrench|vff|vf|vfq|vostfr)\b/, "fr"],
  [/\b(german|ger|deutsch)\b/, "de"], [/\b(spanish|castellano|latino|spa|esp)\b/, "es"], [/\b(polish|pol|lektor)\b/, "pl"],
  [/\b(ukrainian|ukr)\b/, "uk"], [/\bhindi\b/, "hi"], [/\bportuguese\b/, "pt"], [/\bturkish\b/, "tr"],
  [/\b(japanese|jpn)\b/, "ja"], [/\bkorean\b/, "ko"], [/\b(chinese|mandarin|cantonese)\b/, "zh"], [/\barabic\b/, "ar"],
  [/\b(multi|dual audio|multi audio)\b/, "multi"],
];

/** The languages a source's text says it has ("multi" for several). Empty when it doesn't say. */
export function sourceLanguages(text: string): string[] {
  const out = new Set<string>();
  for (const m of text.matchAll(/([\u{1F1E6}-\u{1F1FF}])([\u{1F1E6}-\u{1F1FF}])/gu)) {
    const cc = String.fromCharCode(m[1].codePointAt(0)! - 0x1F1E6 + 65, m[2].codePointAt(0)! - 0x1F1E6 + 65);
    if (FLAG_LANG[cc]) out.add(FLAG_LANG[cc]);
  }
  const words = text.toLowerCase().replace(/[._\-\[\]()|/]+/g, " ");
  for (const [re, lang] of WORD_LANG) if (re.test(words)) out.add(lang);
  return [...out];
}

/** Sources the relay can play without converting video, best first: ready now, H.264, not HDR or
 * 4K, and light (a lower bitrate starts and seeks faster; AAC audio needs no conversion). */
export function rank(list: Stream[]): Candidate[] {
  return list.map((s, order) => {
    // Add-ons style their text with look-alike characters (ᴹᵇᵖˢ, s₀₁·ᴇ₂₁); fold them to plain letters.
    const text = [s.name, s.title, s.description, s.behaviorHints?.filename].filter(Boolean).join(" ").normalize("NFKC").replace(/[​-‍]/g, "");
    const t = " " + text.toLowerCase() + " ";
    const has = (...words: string[]) => words.some((w) => t.includes(w));
    let score = -order * 0.5;
    const uncached = has("uncached", "download]", "⏳");
    const cached = !uncached && (has("+]", "⚡", "cached", "instant") || t.includes("rd+"));
    if (uncached) score -= 3000; else if (cached) score += 4000;
    // The language: a source that says it's only in other languages comes after every one that doesn't.
    const langs = sourceLanguages(text);
    const want = audioLanguage();
    if (langs.includes(want)) score += 400;
    else if (langs.includes("multi")) score += 100;
    else if (langs.length) score -= 3500;
    if (has("x265", "hevc", "h265", "h.265", "av1")) score -= 1500; else if (has("x264", "h264", "h.264", "avc")) score += 600; else score += 150;
    if (has("hdr", "dolby vision", "dovi", ".dv.", " dv ", "10bit", "10-bit")) score -= 1200;
    const quality = has("2160p", "4k", "uhd") ? "4K" : has("1080p") ? "1080p" : has("720p") ? "720p" : has("480p", " sd ") ? "SD" : "";
    score += quality === "4K" ? -900 : quality === "1080p" ? 300 : quality === "720p" ? 240 : 60;
    // Settings › Quality: sharper than allowed only when nothing else is ready.
    const cap = prefs.value.quality;
    if (cap === "720p" && (quality === "1080p" || quality === "4K")) score -= 2500;
    if (cap === "720p" && quality === "720p") score += 200;
    if (cap === "1080p" && quality === "4K") score -= 1500;
    if (has("remux", "bdremux")) score -= 500;
    if (has(" cam ", "hdcam", "telesync", " ts ")) score -= 5000;
    if (has("aac")) score += 250;
    if (has("web-dl", "webdl", "webrip", "web ")) score += 120;
    if (/\.mp4\b/.test(t)) score += 120;
    const rate = /(\d+(?:\.\d+)?)\s*mbps/.exec(t);
    if (rate) score -= Math.max(0, parseFloat(rate[1]) - 8) * 60;
    const size = /(\d+(?:[.,]\d+)?)\s*(gb|gib|mb|mib)\b/i.exec(text);
    return { label: text.replace(/\s+/g, " ").slice(0, 120), url: s.url || "", headers: s.behaviorHints?.proxyHeaders?.request, score, quality,
      name: (s.name || "").replace(/\s+/g, " ").trim(), size: size ? `${size[1].replace(",", ".")} ${size[2].toUpperCase().replace("IB", "B")}` : undefined,
      langs, cached, hdr: has("hdr", "dolby vision", "dovi", ".dv.", " dv "), hevc: has("x265", "hevc", "h265", "h.265") };
  }).filter((c) => c.url && /^https?:/.test(c.url)).sort((a, b) => b.score - a.score);
}

/** What the relay is asked for a source: from where, in which language, for what this browser plays.
 * Dolby audio passes through only where the browser's own HLS plays it. */
export function sessionRequest(candidate: Candidate, start: number, extra: { audio?: number; convert?: boolean; preview?: boolean } = {}) {
  return { url: candidate.url, headers: candidate.headers, start, language: audioLanguage(), ...extra,
    caps: { video: caps.video, audio: caps.audio, stream: useNativeHls ? caps.audio : caps.audio.filter((a) => a === "aac") } };
}

export interface Prepared {
  decision: Decision | null;
  candidate: Candidate | null;
  /** Why nothing can play, in words for the viewer. */
  problem?: string;
  startAt: number;
  timings: { sourcesMs: number; relayMs: number; tried: number };
  /** The other sources, best first, for switching to a lighter one. */
  alternatives?: Candidate[];
}

const QUALITY_RANK: Record<string, number> = { "4K": 4, "1080p": 3, "720p": 2, SD: 1 };
/** Sources lighter than the one playing: a lower resolution, best first. */
export function lighter(p: Prepared): Candidate[] {
  const now = QUALITY_RANK[p.candidate?.quality || ""] ?? 3;
  return (p.alternatives || []).filter((c) => c.url !== p.candidate?.url && (QUALITY_RANK[c.quality] ?? 3) < now);
}

const prepared = new Map<string, { at: number; startAt: number; promise: Promise<Prepared>; preview: boolean }>();
/** The one stream readied ahead of Play (a title page, the next episode) and not yet taken by a
 * player: readying another lets it go, so browsing leaves nothing open on the server. */
let ahead: string | null = null;

export interface PrepareOptions {
  /** Readied ahead of Play: only sources that are ready now are tried, and only a few seconds made. */
  preview?: boolean;
  /** A source chosen by hand (Sources on a title page): tried first. */
  candidate?: Candidate;
}

/** Find the sources for a film or episode and ready the best one at the resume point. Called when a
 * title's page has been open a moment, so pressing Play has nothing left to wait for. */
export function prepare(meta: Meta, video: Video | undefined, startAt: number, options: PrepareOptions = {}): Promise<Prepared> {
  const key = video?.id || meta.id;
  const hit = prepared.get(key);
  // A prepared stream is kept by the relay for 15 minutes; one readied elsewhere in the video is no use.
  if (!options.candidate && hit && Date.now() - hit.at < 10 * 60_000 && Math.abs(hit.startAt - startAt) < 30) {
    // Readied ahead with only the ready-now sources: if none of those played, Play tries them all.
    return hit.preview && !options.preview ? hit.promise.then((p) => (p.decision ? p : prepare(meta, video, startAt, options))) : hit.promise;
  }
  if (options.preview) {
    if (!prefs.value.prepareAhead) return Promise.resolve({ decision: null, candidate: null, startAt, timings: { sourcesMs: 0, relayMs: 0, tried: 0 } });
    if (ahead && ahead !== key) release(ahead);
    ahead = key;
  } else if (hit) {
    release(key);
  }
  const promise = (async (): Promise<Prepared> => {
    const began = performance.now();
    const found = rank(await streams(meta.type, key));
    const sourcesMs = performance.now() - began;
    if (!found.length) return { decision: null, candidate: null, startAt, problem: "No sources were found for this title. Check the add-ons on your Stremio account.", timings: { sourcesMs, relayMs: 0, tried: 0 } };
    const relayBegan = performance.now();
    let tried = 0, lastReason = "";
    const convertible: Candidate[] = [];
    // Ahead of Play, only sources that are ready now: asking for one that isn't can start a download
    // on the debrid account.
    const order = options.candidate ? [options.candidate, ...found.filter((c) => c.url !== options.candidate!.url)] : found;
    const tryList = options.preview ? order.filter((c) => c.cached).slice(0, 2) : order.slice(0, 6);
    for (const candidate of tryList) {
      tried++;
      const decision = await relaySession(sessionRequest(candidate, startAt, { preview: options.preview }));
      if (decision.mode === "direct" || decision.mode === "remux") {
        return { decision, candidate, startAt, timings: { sourcesMs, relayMs: performance.now() - relayBegan, tried }, alternatives: found };
      }
      if (decision.convertible) convertible.push(candidate);
      lastReason = decision.reason || decision.mode;
    }
    // Nothing plays as it is: the server converts the best one that it can (it remembers the file, so
    // asking again is quick). Never ahead of Play: converting is costly.
    for (const candidate of options.preview ? [] : convertible.slice(0, 2)) {
      tried++;
      const decision = await relaySession(sessionRequest(candidate, startAt, { convert: true }));
      if (decision.mode === "remux") {
        return { decision, candidate, startAt, timings: { sourcesMs, relayMs: performance.now() - relayBegan, tried }, alternatives: found };
      }
      lastReason = decision.reason === "busy" ? "the server is converting another video" : decision.reason || decision.mode;
    }
    return { decision: null, candidate: null, startAt, alternatives: found, problem: lastReason === "the server is converting another video"
      ? "Your server is converting another video right now. Try again when that one is done, or choose another title."
      : `None of the sources found can play in this browser (${lastReason}).`, timings: { sourcesMs, relayMs: performance.now() - relayBegan, tried } };
  })();
  prepared.set(key, { at: Date.now(), startAt, promise, preview: !!options.preview });
  promise.then((p) => { if (!p.decision) prepared.delete(key); }, () => prepared.delete(key));
  return promise;
}

/** Let a stream readied ahead go on the server. */
function release(key: string) {
  const hit = prepared.get(key);
  prepared.delete(key);
  if (ahead === key) ahead = null;
  hit?.promise.then((p) => { if (p.decision?.id) relayClose(p.decision.id); }, () => {});
}

/** A player has taken this stream: it's no longer only readied ahead. */
export function claim(key: string) {
  if (ahead === key) ahead = null;
}

/** The sources for a film or episode, best first, for choosing one by hand. */
export async function sources(meta: Meta, video: Video | undefined): Promise<Candidate[]> {
  return rank(await streams(meta.type, video?.id || meta.id));
}

/** A source chosen by hand on a title page, for the player to start with. */
export const chosenSource = new Map<string, Candidate>();

/** A stream that was played can't be handed out again as "ready at the resume point". */
export function used(key: string, sessionId?: string) {
  prepared.delete(key);
  if (sessionId) relayClose(sessionId);
}
