// Subtitles in the player: which tracks there are, loading their cues, and drawing them.
//
// Cues are drawn by Encore over the video, in its own type, and moved up when the controls show. In
// the iPhone's own full-screen player and in Picture in Picture, where nothing of the page shows, they
// are handed to the video as a text track instead.
import { useEffect, useRef, useState } from "preact/hooks";
import { addonSubtitles, relayCues, subtitleFile, type AddonSubtitle, type Cue, type Decision } from "../lib/api";
import { lang2, languageName } from "../lib/lang";

export interface SubOption { key: string; label: string; detail?: string; lang: string; forced?: boolean; embedded?: number; url?: string }

/** The subtitle choices for this stream: the file's own text tracks first, then add-ons' (one per
 * language the file doesn't already have, their first being their best). */
export function subtitleOptions(decision: Decision | null, fromAddons: AddonSubtitle[]): SubOption[] {
  const out: SubOption[] = [];
  const have = new Set<string>();
  for (const t of decision?.subtitles || []) {
    if (!t.text) continue;
    const lang = lang2(t.language);
    const name = (t.name || "").trim();
    const extra = name && name.toLowerCase() !== languageName(t.language).toLowerCase() ? name : "";
    out.push({ key: `e:${t.index}`, label: languageName(t.language), detail: [t.forced && !/forced/i.test(extra) ? "Forced" : "", extra].filter(Boolean).join(" · ") || undefined, lang, forced: t.forced || /forced/i.test(name), embedded: t.index });
    if (!t.forced) have.add(lang);
  }
  const seen = new Set<string>();
  for (const s of fromAddons) {
    const lang = lang2(s.lang);
    if (!lang || have.has(lang) || seen.has(lang)) continue;
    seen.add(lang);
    out.push({ key: `a:${s.id}`, label: languageName(s.lang), detail: s.source, lang, url: s.url });
  }
  return out;
}

/** Subtitles the account's add-ons offer for this video, looked up once per video. */
export function useAddonSubtitles(type: string, videoId: string | undefined) {
  const [list, setList] = useState<AddonSubtitle[]>([]);
  useEffect(() => {
    setList([]);
    if (!videoId) return;
    let live = true;
    addonSubtitles(type, videoId).then((l) => live && setList(l), () => {});
    return () => { live = false; };
  }, [type, videoId]);
  return list;
}

const key = (c: Cue) => `${c.start.toFixed(2)}|${c.text}`;

/** The cues of the chosen track, growing as the relay finds more (a file's own track) or all at once
 * (an add-on's file). */
export function useCues(choice: SubOption | null, sessionId: string | undefined): Cue[] {
  const [cues, setCues] = useState<Cue[]>([]);
  const store = useRef(new Map<string, { list: Cue[]; seen: Set<string> }>());
  useEffect(() => {
    if (!choice) { setCues([]); return; }
    let entry = store.current.get(choice.key);
    if (!entry) { entry = { list: [], seen: new Set() }; store.current.set(choice.key, entry); }
    const mine = entry;
    setCues(mine.list);
    const add = (more: Cue[]) => {
      let changed = false;
      for (const c of more) { const k = key(c); if (!mine.seen.has(k)) { mine.seen.add(k); mine.list.push(c); changed = true; } }
      if (changed) { mine.list.sort((a, b) => a.start - b.start); setCues([...mine.list]); }
    };
    let live = true;
    if (choice.url) {
      if (!mine.list.length) subtitleFile(choice.url).then((c) => live && add(c), () => {});
      return () => { live = false; };
    }
    if (choice.embedded == null || !sessionId) return;
    // The relay collects a file's subtitles as it makes the stream: ask for the new ones every few seconds.
    let after = 0;
    let timer: number | undefined;
    const poll = async () => {
      try {
        const body = await relayCues(sessionId, choice.embedded!, after);
        if (!live) return;
        after = body.total;
        add(body.cues);
      } catch {}
      if (live) timer = setTimeout(poll, mine.list.length ? 4000 : 1500) as unknown as number;
    };
    poll();
    return () => { live = false; clearTimeout(timer); };
  }, [choice?.key, sessionId]);
  return cues;
}

/** The cues showing at a moment (a sorted list; usually one or two lines). */
export function activeCues(cues: Cue[], t: number): Cue[] {
  let lo = 0, hi = cues.length;
  while (lo < hi) { const mid = (lo + hi) >> 1; if (cues[mid].start <= t) lo = mid + 1; else hi = mid; }
  const out: Cue[] = [];
  // Cues can overlap: look back a little from the last one that has started.
  for (let i = lo - 1; i >= 0 && i >= lo - 8; i--) if (cues[i].end > t) out.unshift(cues[i]);
  return out;
}

/** Cue text to markup: everything escaped, then only <i>, <b>, and <u> let back in. */
function markup(text: string): string {
  return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/&lt;(\/?)(i|b|u)&gt;/gi, "<$1$2>").replace(/\n/g, "<br>");
}

/** Encore's own drawing of the cues, over the video. */
export function Captions({ video, cues, raised }: { video: HTMLVideoElement; cues: Cue[]; raised: boolean }) {
  const [shown, setShown] = useState<Cue[]>([]);
  const last = useRef("");
  useEffect(() => {
    if (!cues.length) { setShown([]); last.current = ""; return; }
    let frame = 0;
    const tick = () => {
      const now = activeCues(cues, video.currentTime);
      const id = now.map(key).join("\n");
      if (id !== last.current) { last.current = id; setShown(now); }
      frame = requestAnimationFrame(tick);
    };
    tick();
    return () => cancelAnimationFrame(frame);
  }, [cues]);
  if (!shown.length) return null;
  return (
    <div class={"captions" + (raised ? " raised" : "")} aria-live="off">
      {shown.map((c) => <p key={key(c)}><span dangerouslySetInnerHTML={{ __html: markup(c.text) }} /></p>)}
    </div>
  );
}

/** In the system's own player (iPhone full screen, Picture in Picture) the page isn't drawn: give the
 * video the cues as a text track while it's there. */
export function useSystemCaptions(video: HTMLVideoElement, cues: Cue[], lang: string) {
  const track = useRef<TextTrack | null>(null);
  const [system, setSystem] = useState(false);
  useEffect(() => {
    const on = () => setSystem(true), off = () => setSystem(false);
    const names = ["webkitbeginfullscreen", "enterpictureinpicture"], ends = ["webkitendfullscreen", "leavepictureinpicture"];
    names.forEach((n) => video.addEventListener(n, on));
    ends.forEach((n) => video.addEventListener(n, off));
    return () => { names.forEach((n) => video.removeEventListener(n, on)); ends.forEach((n) => video.removeEventListener(n, off)); };
  }, []);
  useEffect(() => {
    if (!track.current && system && typeof VTTCue !== "undefined") track.current = video.addTextTrack("subtitles", "Subtitles", lang || "en");
    const t = track.current;
    if (!t) return;
    for (const c of [...(t.cues || [])]) t.removeCue(c);
    if (!system || !cues.length) { t.mode = "disabled"; return; }
    for (const c of cues) t.addCue(new VTTCue(c.start, c.end, c.text));
    t.mode = "showing";
  }, [system, cues, lang]);
}
