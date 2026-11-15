import { useEffect, useMemo, useState } from "preact/hooks";
import { back, go, minutes } from "../lib/core";
import { art, encore, meta as loadMeta, type Extras, type Meta, type Video } from "../lib/api";
import { inProgress, isUpNext, isWatched, item as libraryItem, progressOf, setInList, watchedMarks } from "../lib/library";
import { prepare } from "../lib/play";
import { Art, Logo, MetaLine, Shelf } from "./shared";
import { Check, Left, Play, Plus } from "./icons";

export const episodeNumber = (v: Video) => v.episode ?? v.number;
export const videoTitle = (v: Video) => v.title || v.name || (episodeNumber(v) != null ? `Episode ${episodeNumber(v)}` : "");
export const episodeTag = (v: Video) => (v.season != null && episodeNumber(v) != null ? `S${v.season}, E${episodeNumber(v)}` : null);

/** The episodes in watching order, specials last. */
export function episodes(meta: Meta): Video[] {
  return (meta.videos || []).filter((v) => v.season != null).sort((a, b) => ((a.season || 1e6) - (b.season || 1e6)) || ((episodeNumber(a) || 0) - (episodeNumber(b) || 0)));
}

/** What Play means for a title: the episode in progress (or lined up next), else the first. */
export function currentVideo(meta: Meta): Video | undefined {
  if (meta.type !== "series" && !(meta.videos || []).some((v) => v.season != null)) return undefined;
  const all = episodes(meta);
  const saved = libraryItem(meta.id)?.state.video_id;
  return all.find((v) => v.id === saved) || all.find((v) => (v.season || 0) > 0) || all[0];
}

/** Where to resume a video, in seconds; 0 to start from the beginning. */
export function resumeAt(meta: Meta, video: Video | undefined): number {
  const it = libraryItem(meta.id);
  if (!it || !inProgress(it) || isUpNext(it)) return 0;
  if ((it.state.video_id || undefined) !== video?.id && !(video === undefined && it.state.video_id === meta.id)) return 0;
  return (it.state.timeOffset || 0) / 1000;
}

function parseRuntime(text?: string): number | null {
  if (!text) return null;
  const h = /(\d+)\s*h/.exec(text), m = /(\d+)\s*m/.exec(text), bare = /^\s*(\d+)\s*$/.exec(text);
  const total = (h ? +h[1] * 60 : 0) + (m ? +m[1] : 0) + (bare ? +bare[1] : 0);
  return total > 0 ? total * 60 : null;
}

export function TitlePage({ type, id }: { type: string; id: string }) {
  const [meta, setMeta] = useState<Meta | null>(null);
  const [extras, setExtras] = useState<Extras | null>(null);
  const [failed, setFailed] = useState(false);
  const [season, setSeason] = useState<number | null>(null);
  const [runtimes, setRuntimes] = useState<Record<number, number>>({});
  const [shade, setShade] = useState(0);
  const _marks = watchedMarks.value; void _marks;   // re-draw when marks change

  useEffect(() => {
    let live = true;
    setMeta(null); setExtras(null); setFailed(false); setSeason(null);
    loadMeta(type, id).then((m) => {
      if (!live) return;
      setMeta(m);
      setSeason(currentVideo(m)?.season ?? null);
    }, () => live && setFailed(true));
    encore.extras(id, type).then((e) => live && setExtras(e));
    return () => { live = false; };
  }, [type, id]);

  const item = libraryItem(id);
  const video = meta ? currentVideo(meta) : undefined;
  const resume = meta ? resumeAt(meta, video) : 0;

  // Ready the stream at the resume point now, so Play has nothing to wait for.
  useEffect(() => { if (meta) prepare(meta, video, resume).catch(() => {}); }, [meta?.id, video?.id]);
  useEffect(() => {
    if (extras?.tmdbId && season != null) encore.runtimes(extras.tmdbId, season).then(setRuntimes);
  }, [extras?.tmdbId, season]);
  useEffect(() => {
    const onScroll = () => setShade(Math.min(0.82, scrollY / (innerHeight * 0.7)));
    addEventListener("scroll", onScroll, { passive: true });
    return () => removeEventListener("scroll", onScroll);
  }, []);

  const seasons = useMemo(() => meta ? [...new Set(episodes(meta).map((v) => v.season!))] : [], [meta]);
  const shown = useMemo(() => meta && season != null ? episodes(meta).filter((v) => v.season === season) : [], [meta, season]);
  const base = meta || { id, type, name: "" };
  const withArt = { ...base, background: extras?.backdrop || meta?.background, logo: extras?.logo || meta?.logo };
  const resuming = !!item && inProgress(item) && !isUpNext(item);
  const inList = !!item && !item.removed && !item.temp;
  const exact = extras?.runtime ? (extras.runtime >= 60 ? `${Math.floor(extras.runtime / 60)} hr ${extras.runtime % 60} min` : `${extras.runtime} min`) : undefined;
  const showRuntime = parseRuntime(meta?.runtime);
  const tag = video ? episodeTag(video) : null;
  const left = item && resuming ? ((item.state.duration || 0) - (item.state.timeOffset || 0)) / 1000 : 0;
  const cast = extras?.cast?.length ? extras.cast : (meta?.cast || []).map((name) => ({ name, character: undefined, photo: undefined }));

  return (
    <div class="page title-page">
      <div class="backdrop"><img key={art.backdrop(withArt)} src={art.backdrop(withArt)} alt="" onLoad={(e) => (e.target as HTMLImageElement).classList.add("in")} /></div>
      <div class="shade" style={{ opacity: shade }} />
      <button class="back glass" aria-label="Back" onClick={() => back()}><Left /></button>

      <div class="top">
        {meta ? (
          <div class="info" key={meta.id}>
            <Logo src={art.logo(withArt)} name={meta.name} />
            <MetaLine meta={meta} extra={{ runtime: meta.type === "series" ? undefined : exact, certification: extras?.certification }} />
            <div class="actions">
              <button class="pill primary" onClick={() => go(`/watch/${type}/${encodeURIComponent(id)}${video ? `?v=${encodeURIComponent(video.id)}` : ""}`)}>
                <Play />{resuming ? "Resume" : "Play"}{tag ? ` ${tag}` : ""}
              </button>
              <button class="pill secondary round" aria-label={inList ? "Remove from My List" : "Add to My List"} onClick={() => setInList(meta, !inList)}>
                {inList ? <Check /> : <Plus />}
              </button>
            </div>
            {resuming && item && (
              <div class="resume"><div class="bar"><i style={{ width: `${progressOf(item) * 100}%` }} /></div>{minutes(left)} left</div>
            )}
            {(meta.description || extras?.tagline) && <p class="blurb">{meta.description || extras?.tagline}</p>}
          </div>
        ) : failed ? (
          <div class="info"><h1 class="logo-text">Not available</h1><p class="blurb">None of your add-ons has details for this title right now.</p></div>
        ) : null}
      </div>

      {meta && (
        <div class="rest">
          {seasons.length > 0 && (
            <section>
              {seasons.length > 1 && (
                <div class="tabs" role="tablist">
                  {seasons.map((s) => <button key={s} role="tab" aria-selected={s === season} class={s === season ? "on" : ""} onClick={() => setSeason(s)}>{s === 0 ? "Specials" : `Season ${s}`}</button>)}
                </div>
              )}
              <Shelf title={seasons.length > 1 ? "" : "Episodes"}>
                {shown.map((v) => {
                  const mine = item?.state.video_id === v.id && resuming;
                  const number = episodeNumber(v);
                  const length = (number != null && runtimes[number]) || showRuntime;
                  const upcoming = v.released ? new Date(v.released).getTime() > Date.now() : false;
                  return (
                    <button key={v.id} class="episode" disabled={upcoming} onClick={() => go(`/watch/${type}/${encodeURIComponent(id)}?v=${encodeURIComponent(v.id)}`)}>
                      <div class="art-wrap" style={{ position: "relative" }}>
                        <Art src={v.thumbnail || art.wide(withArt)} fallback={videoTitle(v)} />
                        {!upcoming && (
                          <span class="chip glass">
                            {isWatched(v.id) && !mine ? <Check /> : <Play />}
                            {mine && item && <span class="bar"><i style={{ width: `${progressOf(item) * 100}%` }} /></span>}
                            {mine ? `${minutes(left)} left` : length ? minutes(length) : ""}
                          </span>
                        )}
                        {upcoming && <span class="chip glass">Coming {new Date(v.released!).toLocaleDateString(undefined, { month: "short", day: "numeric" })}</span>}
                      </div>
                      <div>
                        {number != null && <small>EPISODE {number}</small>}
                        <b>{videoTitle(v)}</b>
                        {(v.overview || v.description) && <p>{v.overview || v.description}</p>}
                      </div>
                    </button>
                  );
                })}
              </Shelf>
            </section>
          )}

          {cast.length > 0 && (
            <Shelf title="Cast">
              {cast.slice(0, 20).map((p) => (
                <div key={p.name + (p.character || "")} class="person">
                  <Art src={p.photo} fallback={p.name.split(" ").map((w) => w[0]).slice(0, 2).join("")} />
                  <b>{p.name}</b>{p.character && <span>{p.character}</span>}
                </div>
              ))}
            </Shelf>
          )}

          <section class="about">
            <h2 style={{ color: "var(--text)", fontSize: "1.32rem" }}>About</h2>
            {meta.description && <p>{meta.description}</p>}
            <div class="meta">
              {(meta.genres || []).length > 0 && <span>{meta.genres!.join(", ")}</span>}
              {meta.releaseInfo && <span>{meta.releaseInfo}</span>}
              {(exact || meta.runtime) && <span>{exact || meta.runtime}</span>}
              {extras?.crew?.length ? <span>{extras.crew[0].job}: {extras.crew.map((c) => c.name).join(", ")}</span> : null}
            </div>
          </section>
        </div>
      )}
    </div>
  );
}
