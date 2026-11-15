// The player: Encore's own controls over one long-lived <video>. Sources are prepared before this
// screen opens (see lib/play.ts), so its work is to attach, start, and stay out of the way.
import { useEffect, useRef, useState } from "preact/hooks";
import { back, clock, go } from "../lib/core";
import { art, encore, meta as loadMeta, NeedsCode, type Meta, type Video } from "../lib/api";
import { flush, recordProgress } from "../lib/library";
import { prepare, used, useNativeHls, type Prepared } from "../lib/play";
import { currentVideo, episodes, episodeTag, resumeAt, videoTitle } from "./detail";
import { Logo } from "./shared";
import { Back10, Cast, Full, Fwd10, Left, Muted, Next, Pause, Pip, Play, Small, Sound } from "./icons";

// One element for the life of the page. Browsers only let a video start with sound from a tap; the
// tap that leads here (Play, an episode, a Continue Watching card) unlocks this element at once,
// while sources are still being found.
const video = document.createElement("video");
video.playsInline = true;
video.preload = "auto";
video.setAttribute("x-webkit-airplay", "allow");
addEventListener("click", () => {
  if (!video.currentSrc && !video.src) { video.muted = false; video.play().catch(() => {}); }
}, { capture: true });

type Segment = { kind: "intro" | "recap" | "credits"; start: number; end: number };
type HlsType = import("hls.js").default;

export function Player({ type, id, videoId }: { type: string; id: string; videoId?: string }) {
  const root = useRef<HTMLDivElement>(null);
  const holder = useRef<HTMLDivElement>(null);
  const [meta, setMeta] = useState<Meta | null>(null);
  const [episode, setEpisode] = useState<Video | undefined>();
  const [phase, setPhase] = useState<"loading" | "playing" | "problem">("loading");
  const [problem, setProblem] = useState("");
  const [status, setStatus] = useState("Finding the best source…");
  const [show, setShow] = useState(true);
  const [paused, setPaused] = useState(false);
  const [waiting, setWaiting] = useState(false);
  const [time, setTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [buffered, setBuffered] = useState(0);
  const [drag, setDrag] = useState<number | null>(null);
  const [hover, setHover] = useState<number | null>(null);
  const [muted, setMuted] = useState(false);
  const [volume, setVolume] = useState(video.volume);
  const [needsSound, setNeedsSound] = useState(false);
  const [full, setFull] = useState(false);
  const [segments, setSegments] = useState<Segment[]>([]);
  const [skipped, setSkipped] = useState<number[]>([]);
  const [count, setCount] = useState<number | null>(null);
  const [declined, setDeclined] = useState(false);
  const [stats, setStats] = useState(false);
  const live = useRef({ startMs: 0, seekMs: 0, stalls: 0, seekAt: 0, mounted: performance.now(), prepared: null as Prepared | null, lastSaved: 0, warmedNext: false });
  const hideTimer = useRef<number>();

  const list = meta ? episodes(meta) : [];
  const next = episode ? list[list.findIndex((v) => v.id === episode.id) + 1] : undefined;
  const nextRef = useRef(next); nextRef.current = next;
  const state = useRef({ meta, episode, declined }); state.current = { meta, episode, declined };

  const reveal = () => {
    setShow(true);
    clearTimeout(hideTimer.current);
    hideTimer.current = setTimeout(() => { if (!video.paused) setShow(false); }, 3200) as unknown as number;
  };
  const close = () => { back(`/title/${type}/${encodeURIComponent(id)}`); };

  const save = (force = false) => {
    const { meta, episode } = state.current;
    if (!meta || !(video.duration > 0) || live.current.startMs === 0) return;
    if (!force && Math.abs(video.currentTime - live.current.lastSaved) < 10) return;
    live.current.lastSaved = video.currentTime;
    recordProgress(meta, episode, video.currentTime, video.duration, nextRef.current);
  };

  const playNext = () => {
    const n = nextRef.current;
    if (!n) return close();
    save(true);
    go(`/watch/${type}/${encodeURIComponent(id)}?v=${encodeURIComponent(n.id)}`, { replace: true });
  };

  // Load the title, choose the episode, and start what was prepared.
  useEffect(() => {
    let alive = true;
    let hls: HlsType | null = null;
    let sessionId: string | undefined;
    let key = videoId || id;
    live.current = { ...live.current, startMs: 0, seekMs: 0, stalls: 0, mounted: performance.now(), prepared: null, lastSaved: 0, warmedNext: false };
    setPhase("loading"); setProblem(""); setStatus("Finding the best source…"); setSegments([]); setSkipped([]); setCount(null); setDeclined(false);
    setTime(0); setDuration(0); setBuffered(0); setNeedsSound(false);
    holder.current?.appendChild(video);

    (async () => {
      try {
        const m = await loadMeta(type, id);
        if (!alive) return;
        const v = videoId ? (m.videos || []).find((x) => x.id === videoId) : currentVideo(m);
        key = v?.id || m.id;
        setMeta(m); setEpisode(v);
        const startAt = videoId && v?.id !== currentVideo(m)?.id ? resumeAt(m, v) : resumeAt(m, v);
        const p = await prepare(m, v, startAt);
        if (!alive) return;
        live.current.prepared = p;
        if (!p.decision) { setProblem(p.problem || "This title can't be played right now."); setPhase("problem"); return; }
        sessionId = p.decision.id;
        setStatus("Starting…");
        const begin = () => { if (startAt > 1) { try { video.currentTime = startAt; } catch {} } };
        if (p.decision.mode === "direct" || useNativeHls) {
          video.src = p.decision.mode === "direct" ? p.decision.url! : p.decision.playlist!;
          video.addEventListener("loadedmetadata", begin, { once: true });
        } else {
          const { default: Hls } = await import("hls.js");
          if (!alive) return;
          const patient = { maxTimeToFirstByteMs: 30000, maxLoadTimeMs: 120000, timeoutRetry: { maxNumRetry: 3, retryDelayMs: 0, maxRetryDelayMs: 0 }, errorRetry: { maxNumRetry: 6, retryDelayMs: 1000, maxRetryDelayMs: 8000 } };
          hls = new Hls({ startPosition: startAt > 1 ? startAt : -1, maxBufferLength: 40, backBufferLength: 60, fragLoadPolicy: { default: patient } });
          hls.on(Hls.Events.ERROR, (_e, data) => {
            if (!data.fatal) return;
            if (data.type === Hls.ErrorTypes.MEDIA_ERROR) hls!.recoverMediaError();
            else if (alive) { setProblem("The stream stopped and couldn't be recovered. Try again."); setPhase("problem"); }
          });
          hls.loadSource(p.decision.playlist!);
          hls.attachMedia(video);
        }
        try {
          video.muted = false;
          await video.play();
        } catch {
          // Not allowed to start with sound (no tap led here): start silent and offer sound.
          video.muted = true;
          setMuted(true); setNeedsSound(true);
          video.play().catch(() => {});
        }
      } catch (e) {
        if (!alive) return;
        setProblem(e instanceof NeedsCode ? "This server isn't linked to your account yet. Reload the page to link it." : "This title couldn't be loaded. Check your connection and try again.");
        setPhase("problem");
      }
    })();

    return () => {
      alive = false;
      save(true);
      flush();
      hls?.destroy();
      video.pause();
      video.removeAttribute("src");
      video.load();
      used(key, sessionId);
    };
  }, [type, id, videoId]);

  // The video's own events.
  useEffect(() => {
    const on = <K extends keyof HTMLMediaElementEventMap>(name: K, fn: (e: HTMLMediaElementEventMap[K]) => void) => { video.addEventListener(name, fn); return () => video.removeEventListener(name, fn); };
    const offs = [
      on("timeupdate", () => {
        setTime(video.currentTime);
        if (!video.paused && video.readyState >= 3) {
          if (live.current.startMs === 0) { live.current.startMs = performance.now() - live.current.mounted; setPhase("playing"); reveal(); }
          if (live.current.seekAt) { live.current.seekMs = performance.now() - live.current.seekAt; live.current.seekAt = 0; }
          setWaiting(false);
        }
        save();
        // Near the end: have the next episode ready so Up Next starts at once.
        const { meta } = state.current;
        if (meta && nextRef.current && !live.current.warmedNext && video.duration > 0 && video.currentTime / video.duration > 0.85) {
          live.current.warmedNext = true;
          prepare(meta, nextRef.current, 0).catch(() => {});
        }
      }),
      on("durationchange", () => setDuration(isFinite(video.duration) ? video.duration : 0)),
      on("progress", () => { const b = video.buffered; setBuffered(b.length ? b.end(b.length - 1) : 0); }),
      on("play", () => { setPaused(false); reveal(); }),
      on("pause", () => { setPaused(true); setShow(true); save(true); }),
      on("waiting", () => { setWaiting(true); if (live.current.startMs && !live.current.seekAt) live.current.stalls++; }),
      on("playing", () => setWaiting(false)),
      on("seeking", () => { live.current.seekAt = performance.now(); }),
      on("volumechange", () => { setMuted(video.muted); setVolume(video.volume); }),
      on("ended", () => {
        save(true);
        // After Watch Credits (or with nothing after this), the end returns to the title's page.
        if (nextRef.current && !state.current.declined) playNext(); else close();
      }),
      on("error", () => { if (video.error && live.current.startMs === 0) { setProblem("This source didn't play. Try again in a moment."); setPhase("problem"); } }),
    ];
    const onFull = () => setFull(!!document.fullscreenElement);
    document.addEventListener("fullscreenchange", onFull);
    return () => { offs.forEach((off) => off()); document.removeEventListener("fullscreenchange", onFull); clearTimeout(hideTimer.current); };
  }, []);

  // Intro, recap, and credits markers, once the length is known.
  useEffect(() => {
    if (!meta || duration < 120) return;
    let alive = true;
    encore.skip(meta.id, episode?.season, episode ? (episode.episode ?? episode.number) : undefined, duration).then((s) => alive && setSegments(s));
    return () => { alive = false; };
  }, [meta?.id, episode?.id, duration > 120]);

  const active = segments.findIndex((s, i) => time >= s.start && time < s.end - 1 && !skipped.includes(i));
  const segment = active >= 0 ? segments[active] : null;
  const closing = !!segment && segment.kind === "credits";
  // Up Next begins with the closing credits, else in the last 25 seconds.
  const atEnd = !!next && duration >= 300 && (closing || (duration - time < 25 && time / duration > 0.8));
  useEffect(() => {
    if (!atEnd || declined || count != null || phase !== "playing") return;
    setCount(15);
  }, [atEnd, declined, phase]);
  useEffect(() => {
    if (count == null) return;
    if (count <= 0) { playNext(); return; }
    if (paused) return;
    const t = setTimeout(() => setCount((c) => (c == null ? c : c - 1)), 1000);
    return () => clearTimeout(t);
  }, [count, paused]);
  // Seeking back out of the ending takes the countdown (and "Watch Credits") back.
  useEffect(() => { if (!atEnd && duration > 0 && time < duration * 0.75) { if (count != null) setCount(null); if (declined) setDeclined(false); } }, [atEnd, time < duration * 0.75]);

  // Lock screen, headset buttons, and keeping the screen awake.
  useEffect(() => {
    if (!meta || !("mediaSession" in navigator)) return;
    const tag = episode ? episodeTag(episode) : null;
    navigator.mediaSession.metadata = new MediaMetadata({
      title: episode ? videoTitle(episode) : meta.name, artist: episode ? [meta.name, tag].filter(Boolean).join(" · ") : "",
      artwork: [art.wide(meta), art.poster(meta)].filter(Boolean).map((src) => ({ src: src! })),
    });
    const set = (action: MediaSessionAction, fn: MediaSessionActionHandler | null) => { try { navigator.mediaSession.setActionHandler(action, fn); } catch {} };
    set("play", () => video.play());
    set("pause", () => video.pause());
    set("seekbackward", () => seekBy(-10));
    set("seekforward", () => seekBy(10));
    set("seekto", (d) => { if (d.seekTime != null) video.currentTime = d.seekTime; });
    set("nexttrack", next ? () => playNext() : null);
    return () => { navigator.mediaSession.metadata = null; };
  }, [meta?.id, episode?.id, !!next]);
  useEffect(() => {
    if (paused || phase !== "playing" || !("wakeLock" in navigator)) return;
    let lock: WakeLockSentinel | null = null;
    navigator.wakeLock.request("screen").then((l) => { lock = l; }).catch(() => {});
    return () => { lock?.release().catch(() => {}); };
  }, [paused, phase]);

  const toggle = () => { if (video.paused) video.play().catch(() => {}); else video.pause(); };
  const seekBy = (d: number) => { video.currentTime = Math.max(0, Math.min((video.duration || 0) - 1, video.currentTime + d)); reveal(); };
  const toggleFull = () => {
    const el = root.current as (HTMLElement & { webkitRequestFullscreen?: () => void }) | null;
    const v = video as HTMLVideoElement & { webkitEnterFullscreen?: () => void };
    if (document.fullscreenElement) document.exitFullscreen();
    else if (el?.requestFullscreen) el.requestFullscreen().catch(() => {});
    else if (el?.webkitRequestFullscreen) el.webkitRequestFullscreen();
    else v.webkitEnterFullscreen?.();
  };
  const sound = () => { video.muted = false; setNeedsSound(false); };

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      switch (e.key) {
        case " ": case "k": toggle(); break;
        case "ArrowLeft": case "j": seekBy(-10); break;
        case "ArrowRight": case "l": seekBy(10); break;
        case "ArrowUp": video.volume = Math.min(1, video.volume + 0.1); video.muted = false; reveal(); break;
        case "ArrowDown": video.volume = Math.max(0, video.volume - 0.1); reveal(); break;
        case "f": toggleFull(); break;
        case "m": video.muted = !video.muted; break;
        case "s": setStats((v) => !v); break;
        case "n": if (nextRef.current) playNext(); break;
        case "Escape": case "Backspace": if (!document.fullscreenElement) close(); break;
        default: return;
      }
      e.preventDefault();
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, [type, id]);

  // The scrubber: drag to preview a time, release to go there.
  const fraction = (e: PointerEvent, el: HTMLElement) => { const r = el.getBoundingClientRect(); return Math.min(1, Math.max(0, (e.clientX - r.left) / r.width)); };
  const scrub = {
    onPointerDown: (e: PointerEvent) => { const el = e.currentTarget as HTMLElement; el.setPointerCapture(e.pointerId); setDrag(fraction(e, el) * duration); },
    onPointerMove: (e: PointerEvent) => { const el = e.currentTarget as HTMLElement; const t = fraction(e, el) * duration; setHover(t); if (drag != null) setDrag(t); reveal(); },
    onPointerUp: (e: PointerEvent) => { if (drag != null) { video.currentTime = fraction(e, e.currentTarget as HTMLElement) * duration; setTime(video.currentTime); setDrag(null); } },
    onPointerLeave: () => setHover(null),
    onPointerCancel: () => setDrag(null),
  };
  const shownTime = drag ?? time;
  const tag = episode ? episodeTag(episode) : null;
  const v = video as HTMLVideoElement & { webkitShowPlaybackTargetPicker?: () => void };
  const p = live.current.prepared;

  return (
    <div ref={root} class={"player" + (show || phase !== "playing" ? " show" : " idle")} onPointerMove={(e) => e.pointerType === "mouse" && reveal()}>
      <div ref={holder} onClick={(e) => { if ((e as unknown as PointerEvent).pointerType === "mouse") toggle(); else if (show && !video.paused) setShow(false); else reveal(); }}
        onDblClick={toggleFull} style={{ position: "absolute", inset: 0 }} />

      {phase !== "playing" && (
        <div class="curtain">
          {meta && <img class="bg" src={art.backdrop(meta)} alt="" />}
          <div class="mid">
            {meta && <Logo src={art.logo(meta)} name={meta.name} />}
            {tag && <p class="quiet">{tag}{episode ? ` · ${videoTitle(episode)}` : ""}</p>}
            {phase === "loading" ? <><div class="spinner" /><p class="quiet">{status}</p></> : (
              <div class="problem">
                <p>{problem}</p>
                <div class="actions"><button class="pill primary" onClick={() => location.reload()}>Try Again</button><button class="pill secondary" onClick={close}>Back</button></div>
              </div>
            )}
          </div>
        </div>
      )}
      {phase === "playing" && waiting && <div class="wait"><div class="spinner" /></div>}

      <div class="chrome">
        <div class="topbar">
          <button class="icon" aria-label="Back" onClick={close}><Left /></button>
          <div class="names">
            <b>{meta?.name}</b>
            {tag && <small>{tag}{episode ? ` · ${videoTitle(episode)}` : ""}</small>}
          </div>
        </div>
        {phase === "playing" && (
          <div class="center">
            <button class="icon mid" aria-label="Back 10 seconds" onClick={() => seekBy(-10)}><Back10 /></button>
            <button class="icon big" aria-label={paused ? "Play" : "Pause"} onClick={toggle}>{paused ? <Play /> : <Pause />}</button>
            <button class="icon mid" aria-label="Forward 10 seconds" onClick={() => seekBy(10)}><Fwd10 /></button>
          </div>
        )}
        {phase === "playing" ? (
          <div class="bottom">
            <div class={"scrub" + (drag != null ? " drag" : "")} role="slider" aria-label="Position" aria-valuemin={0} aria-valuemax={Math.round(duration)} aria-valuenow={Math.round(shownTime)} aria-valuetext={clock(shownTime)} {...scrub}>
              <div class="track">
                <div class="buffered" style={{ width: `${duration ? (buffered / duration) * 100 : 0}%` }} />
                <div class="played" style={{ width: `${duration ? (shownTime / duration) * 100 : 0}%` }} />
              </div>
              <div class="knob" style={{ left: `${duration ? (shownTime / duration) * 100 : 0}%` }} />
              {(hover != null || drag != null) && duration > 0 && <div class="tip glass" style={{ left: `${((drag ?? hover!) / duration) * 100}%` }}>{clock(drag ?? hover!)}</div>}
            </div>
            <div class="controls">
              <span>{clock(shownTime)}</span>
              <span class="grow" />
              <span>-{clock(Math.max(0, duration - shownTime))}</span>
              <span style={{ width: "0.6rem" }} />
              <span class="volume">
                <button class="icon" aria-label={muted ? "Unmute" : "Mute"} onClick={() => { video.muted = !video.muted; setNeedsSound(false); }}>{muted || volume === 0 ? <Muted /> : <Sound />}</button>
                <input type="range" min="0" max="1" step="0.05" value={muted ? 0 : volume} aria-label="Volume" onInput={(e) => { video.volume = +(e.target as HTMLInputElement).value; video.muted = false; }} />
              </span>
              {next && <button class="icon" aria-label="Next episode" onClick={playNext}><Next /></button>}
              {v.webkitShowPlaybackTargetPicker && <button class="icon" aria-label="AirPlay" onClick={() => v.webkitShowPlaybackTargetPicker!()}><Cast /></button>}
              {document.pictureInPictureEnabled && <button class="icon" aria-label="Picture in Picture" onClick={() => (document.pictureInPictureElement ? document.exitPictureInPicture() : video.requestPictureInPicture()).catch(() => {})}><Pip /></button>}
              <button class="icon" aria-label={full ? "Exit full screen" : "Full screen"} onClick={toggleFull}>{full ? <Small /> : <Full />}</button>
            </div>
          </div>
        ) : <div />}
      </div>

      {phase === "playing" && (
        <div class="offer">
          {needsSound && <button class="pill primary" onClick={sound}><Sound />Turn Sound On</button>}
          {segment && !closing && (
            <button class="pill primary" onClick={() => { video.currentTime = segment.end; setSkipped((s) => [...s, active]); }}>Skip {segment.kind === "recap" ? "Recap" : "Intro"}</button>
          )}
          {count != null && next && (
            <>
              <button class="pill secondary glass" onClick={() => { setCount(null); setDeclined(true); }}>Watch Credits</button>
              <button class="pill primary count" style={{ "--count": "15s" }} onClick={playNext}><span><Next />Next Episode in {count}</span></button>
            </>
          )}
          {count == null && next && (declined || (closing && atEnd)) && <button class="pill primary" onClick={playNext}><Next />Next Episode</button>}
        </div>
      )}

      {stats && (
        <div class="stats glass">{[
          `mode      ${p?.decision?.mode || "–"}${p?.decision?.audioCopied ? " (audio untouched)" : ""} via ${p?.decision?.mode === "direct" ? "source" : useNativeHls ? "native HLS" : "hls.js"}`,
          `video     ${video.videoWidth}×${video.videoHeight}`,
          `sources   ${p ? Math.round(p.timings.sourcesMs) : "–"} ms, relay ${p ? Math.round(p.timings.relayMs) : "–"} ms (${p?.timings.tried || 0} tried)`,
          `start     ${Math.round(live.current.startMs)} ms from opening the player`,
          `last seek ${Math.round(live.current.seekMs)} ms`,
          `stalls    ${live.current.stalls}`,
          `buffer    ${Math.max(0, buffered - time).toFixed(1)} s ahead`,
          `source    ${(p?.candidate?.label || "").slice(0, 70)}`,
        ].join("\n")}</div>
      )}
    </div>
  );
}
