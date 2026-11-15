import { useEffect, useRef, useState } from "preact/hooks";
import { go, minutes } from "../lib/core";
import { art, catalog, encore, shelves as loadShelves, meta as loadMeta, type CatalogRef, type Meta } from "../lib/api";
import { continueWatching, dismiss, episodeLabel, isUpNext, markWatched, progressOf } from "../lib/library";
import type { LibraryItem } from "../lib/api";
import { Art, Link, Logo, MetaLine, PosterCard, Shelf, SkeletonShelf, titlePath, useNearScreen, usePress, showMenu, type Action } from "./shared";
import { episodes } from "./detail";
import { Check, Close, Film, Info, Left, More, Play, Right } from "./icons";

const SLIDE = 9000;

/** "24m left" for something part-watched. */
function left(item: { state: { timeOffset?: number; duration?: number } }): string | null {
  const { timeOffset = 0, duration = 0 } = item.state;
  return duration > 0 && duration > timeOffset ? `${minutes((duration - timeOffset) / 1000)} left` : null;
}

function Hero({ items }: { items: Meta[] }) {
  const [index, setIndex] = useState(0);
  const [held, setHeld] = useState(false);
  const [loadedArt, setLoadedArt] = useState<Set<string>>(new Set());
  const touch = useRef<number | null>(null);
  // The words under the artwork change a beat after the picture starts to: they fade out, then in.
  const [infoIndex, setInfoIndex] = useState(0);
  const [leaving, setLeaving] = useState(false);
  useEffect(() => {
    if (index === infoIndex) return;
    setLeaving(true);
    const t = setTimeout(() => { setInfoIndex(index); setLeaving(false); }, 260);
    return () => clearTimeout(t);
  }, [index]);
  const item = items[Math.min(infoIndex, items.length - 1)];
  const current = items[Math.min(index, items.length - 1)];
  // The picture on screen stays until the next one is ready, so a slide never fades through black.
  const lastShown = useRef(0);
  if (loadedArt.has(current.id)) lastShown.current = index;
  const visible = lastShown.current;
  const step = (d: number) => setIndex((i) => (i + d + items.length) % items.length);

  useEffect(() => {
    if (held || items.length < 2) return;
    const t = setTimeout(() => step(1), SLIDE);
    return () => clearTimeout(t);
  }, [index, held, items.length]);
  // The title on the hero is the likeliest to be opened: have its details ready.
  useEffect(() => { loadMeta(current.type, current.id).catch(() => {}); }, [current.id]);

  return (
    <section class="hero" onPointerEnter={(e) => e.pointerType === "mouse" && setHeld(true)} onPointerLeave={() => setHeld(false)}
      onTouchStart={(e) => { touch.current = e.touches[0].clientX; }}
      onTouchEnd={(e) => {
        const dx = e.changedTouches[0].clientX - (touch.current ?? 0);
        if (Math.abs(dx) > 50) step(dx < 0 ? 1 : -1);
        touch.current = null;
      }}>
      <div class="backdrop">
        {items.map((m, i) => Math.abs(i - index) <= 1 || (index === 0 && i === items.length - 1) || (index === items.length - 1 && i === 0)
          ? <img key={m.id} src={art.backdrop(m)} class={i === visible && loadedArt.has(m.id) ? "on" : ""} alt="" decoding="async"
              ref={(img) => { if (img?.complete && img.naturalWidth && !loadedArt.has(m.id)) setLoadedArt((s) => new Set(s).add(m.id)); }}
              onLoad={(e) => { const img = e.currentTarget; const done = () => setLoadedArt((s) => new Set(s).add(m.id)); img.decode ? img.decode().then(done, done) : done(); }} /> : null)}
      </div>
      <div class={"info" + (leaving ? " out" : "")} key={item.id}>
        <Logo src={art.logo(item)} name={item.name} />
        <MetaLine meta={item} />
        {item.description && <p class="blurb">{item.description}</p>}
        <div class="actions">
          <button class="pill primary" onClick={() => go(`/watch/${item.type}/${encodeURIComponent(item.id)}`)}><Play />Play</button>
          <Link to={titlePath(item)} class="pill secondary">More Info</Link>
        </div>
      </div>
      {items.length > 1 && (
        <>
          <button class="hero-arrow prev glass" aria-label="Previous" onClick={() => step(-1)}><Left /></button>
          <button class="hero-arrow next glass" aria-label="Next" onClick={() => step(1)}><Right /></button>
          <div class="dots glass" style={{ "--slide": SLIDE + "ms" }}>
            {items.map((m, i) => <button key={m.id} class={(i === index ? "on" : "") + (held ? " held" : "")} aria-label={`Show ${m.name}`} onClick={() => setIndex(i)}><i key={index} /></button>)}
          </div>
        </>
      )}
    </section>
  );
}

function ContinueCard({ item }: { item: LibraryItem }) {
  const open = (at: DOMRect) => showMenu({ at, title: item.name, subtitle: episode || undefined, actions });
  const press = usePress((at) => open(at));
  const episode = episodeLabel(item.state.video_id);
  const next = isUpNext(item);
  const series = item.type === "series" || !!episode;
  const m = { id: item._id, type: item.type, name: item.name, poster: item.poster };
  const watch = `/watch/${item.type}/${encodeURIComponent(item._id)}${item.state.video_id && item.state.video_id !== item._id ? `?v=${encodeURIComponent(item.state.video_id)}` : ""}`;
  const actions: Action[] = [
    { label: next ? `Play ${episode || ""}`.trim() : `Resume${episode ? " " + episode : ""}`, icon: Play, run: () => go(watch) },
    ...(series && item.state.video_id
      ? [{ label: "Go to Episode", icon: Film, run: () => go(`${titlePath(m)}?v=${encodeURIComponent(item.state.video_id!)}`) },
         { label: "Go to Show", icon: Info, run: () => go(titlePath(m)) }]
      : [{ label: "Go to Movie", icon: Info, run: () => go(titlePath(m)) }]),
    { label: "Mark as Watched", icon: Check, run: async () => {
      const meta = await loadMeta(item.type, item._id).catch(() => null);
      const all = meta ? episodes(meta) : [];
      const at = all.findIndex((v) => v.id === item.state.video_id);
      markWatched(meta || m, at >= 0 ? all[at] : undefined, at >= 0 ? all[at + 1] : undefined);
    } },
    { label: "Remove from Continue Watching", icon: Close, run: () => dismiss(item), danger: true },
  ];
  return (
    <div class="card wide cw" {...press}>
      <Link to={watch} class="hit" label={`${next ? "Play" : "Resume"} ${item.name}${episode ? ", " + episode : ""}`} warm={m}>
        <Art src={art.wide(m)} fallback={item.name} />
        <div class="over">
          <b>{item.name}</b>
          <small>{[next ? (episode ? `Next · ${episode}` : "Up Next") : episode, left(item)].filter(Boolean).join(" · ")}</small>
          <div class="bar" style={next ? { visibility: "hidden" } : undefined}><i style={{ width: `${progressOf(item) * 100}%` }} /></div>
        </div>
      </Link>
      <button class="more glass" aria-label={`More for ${item.name}`} aria-haspopup="menu"
        onClick={(e) => open((e.currentTarget as HTMLElement).getBoundingClientRect())}><More /></button>
    </div>
  );
}

function ContinueShelf() {
  const list = continueWatching.value;
  if (!list.length) return null;
  return (
    <Shelf title="Continue Watching">
      {list.map((item) => <ContinueCard key={item._id} item={item} />)}
    </Shelf>
  );
}

function CatalogShelf({ shelf }: { shelf: CatalogRef }) {
  const [ref, near] = useNearScreen<HTMLDivElement>();
  const [metas, setMetas] = useState<Meta[] | null>(null);
  useEffect(() => {
    if (!near) return;
    let live = true;
    catalog(shelf).then((m) => live && setMetas(m), () => live && setMetas([]));
    return () => { live = false; };
  }, [near, shelf.key]);
  if (metas && !metas.length) return null;
  return (
    <div ref={ref}>
      {metas
        ? <Shelf title={shelf.title}>{metas.slice(0, 40).map((m) => <PosterCard key={m.id} meta={m} />)}</Shelf>
        : <SkeletonShelf title={shelf.title} />}
    </div>
  );
}

export function HomePage() {
  const [featured, setFeatured] = useState<Meta[]>([]);
  const [list, setList] = useState<CatalogRef[]>([]);

  useEffect(() => {
    let live = true;
    loadShelves().then(async (found) => {
      if (!live) return;
      setList(found);
      // Featured: this week's trending titles with their best artwork; else the first shelf's leaders.
      const trending = await encore.trending();
      if (!live) return;
      if (trending.length) {
        setFeatured(trending.slice(0, 7).map((t) => ({ id: t.imdbId, type: t.type, name: t.name, background: t.backdrop, logo: t.logo, description: t.overview, releaseInfo: t.year, genres: t.genres, imdbRating: t.rating ? t.rating.toFixed(1) : undefined })));
      } else if (found[0]) {
        const metas = await catalog(found[0]).catch(() => []);
        if (live) setFeatured(metas.slice(0, 6));
      }
    });
    return () => { live = false; };
  }, []);

  return (
    <div class="page">
      {featured.length ? <Hero items={featured} /> : <div class="hero skeleton" />}
      <div class="shelves">
        <ContinueShelf />
        {list.slice(0, 14).map((s) => <CatalogShelf key={s.key} shelf={s} />)}
      </div>
    </div>
  );
}
