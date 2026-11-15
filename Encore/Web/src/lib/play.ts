// Choosing a source and getting it ready to play, ahead of the Play button.
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

export interface Candidate { label: string; url: string; headers?: Record<string, string>; score: number; quality: string }

/** Sources the relay can play without converting video, best first: ready now, H.264, not HDR or
 * 4K, and light (a lower bitrate starts and seeks faster; AAC audio needs no conversion). */
export function rank(list: Stream[]): Candidate[] {
  return list.map((s, order) => {
    // Add-ons style their text with look-alike characters (ᴹᵇᵖˢ, s₀₁·ᴇ₂₁); fold them to plain letters.
    const text = [s.name, s.title, s.description, s.behaviorHints?.filename].filter(Boolean).join(" ").normalize("NFKC").replace(/[​-‍]/g, "");
    const t = " " + text.toLowerCase() + " ";
    const has = (...words: string[]) => words.some((w) => t.includes(w));
    let score = -order * 0.5;
    if (has("uncached", "download]", "⏳")) score -= 3000; else if (has("+]", "⚡", "cached", "instant") || t.includes("rd+")) score += 4000;
    if (has("x265", "hevc", "h265", "h.265", "av1")) score -= 1500; else if (has("x264", "h264", "h.264", "avc")) score += 600; else score += 150;
    if (has("hdr", "dolby vision", "dovi", ".dv.", " dv ", "10bit", "10-bit")) score -= 1200;
    const quality = has("2160p", "4k", "uhd") ? "4K" : has("1080p") ? "1080p" : has("720p") ? "720p" : has("480p", " sd ") ? "SD" : "";
    score += quality === "4K" ? -900 : quality === "1080p" ? 300 : quality === "720p" ? 240 : 60;
    if (has("remux", "bdremux")) score -= 500;
    if (has(" cam ", "hdcam", "telesync", " ts ")) score -= 5000;
    if (has("aac")) score += 250;
    if (has("web-dl", "webdl", "webrip", "web ")) score += 120;
    if (/\.mp4\b/.test(t)) score += 120;
    const rate = /(\d+(?:\.\d+)?)\s*mbps/.exec(t);
    if (rate) score -= Math.max(0, parseFloat(rate[1]) - 8) * 60;
    return { label: text.replace(/\s+/g, " ").slice(0, 120), url: s.url || "", headers: s.behaviorHints?.proxyHeaders?.request, score, quality };
  }).filter((c) => c.url && /^https?:/.test(c.url)).sort((a, b) => b.score - a.score);
}

export interface Prepared {
  decision: Decision | null;
  candidate: Candidate | null;
  /** Why nothing can play, in words for the viewer. */
  problem?: string;
  startAt: number;
  timings: { sourcesMs: number; relayMs: number; tried: number };
}

const prepared = new Map<string, { at: number; startAt: number; promise: Promise<Prepared> }>();

/** Find the sources for a film or episode and ready the best one at the resume point. Called when a
 * title's page opens, so pressing Play has nothing left to wait for. */
export function prepare(meta: Meta, video: Video | undefined, startAt: number): Promise<Prepared> {
  const key = video?.id || meta.id;
  const hit = prepared.get(key);
  // A prepared stream is kept by the relay for 15 minutes; one readied elsewhere in the video is no use.
  if (hit && Date.now() - hit.at < 10 * 60_000 && Math.abs(hit.startAt - startAt) < 30) return hit.promise;
  const promise = (async (): Promise<Prepared> => {
    const began = performance.now();
    const found = rank(await streams(meta.type, key));
    const sourcesMs = performance.now() - began;
    if (!found.length) return { decision: null, candidate: null, startAt, problem: "No sources were found for this title. Check the add-ons on your Stremio account.", timings: { sourcesMs, relayMs: 0, tried: 0 } };
    const relayBegan = performance.now();
    let tried = 0, lastReason = "";
    for (const candidate of found.slice(0, 6)) {
      tried++;
      // Dolby audio passes through only where the browser's own HLS plays it.
      const decision = await relaySession({ url: candidate.url, headers: candidate.headers, start: startAt, caps: { video: caps.video, audio: caps.audio, stream: useNativeHls ? caps.audio : caps.audio.filter((a) => a === "aac") } });
      if (decision.mode === "direct" || decision.mode === "remux") {
        return { decision, candidate, startAt, timings: { sourcesMs, relayMs: performance.now() - relayBegan, tried } };
      }
      lastReason = decision.reason || decision.mode;
    }
    return { decision: null, candidate: null, startAt, problem: `None of the best sources can play in this browser yet (${lastReason}).`, timings: { sourcesMs, relayMs: performance.now() - relayBegan, tried } };
  })();
  prepared.set(key, { at: Date.now(), startAt, promise });
  promise.then((p) => { if (!p.decision) prepared.delete(key); }, () => prepared.delete(key));
  return promise;
}

/** A stream that was played can't be handed out again as "ready at the resume point". */
export function used(key: string, sessionId?: string) {
  prepared.delete(key);
  if (sessionId) relayClose(sessionId);
}
