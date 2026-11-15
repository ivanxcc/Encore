import { useEffect, useRef, useState } from "preact/hooks";
import { go, minutes } from "../lib/core";
import { art, catalog, encore, shelves as loadShelves, meta as loadMeta, type CatalogRef, type Meta } from "../lib/api";
import { continueWatching, episodeLabel, isUpNext, progressOf } from "../lib/library";
import { Art, Link, Logo, MetaLine, PosterCard, Shelf, SkeletonShelf, titlePath, useNearScreen } from "./shared";
import { Left, Play, Right } from "./icons";

const SLIDE = 9000;

/** "24m left" for something part-watched. */
function left(item: { state: { timeOffset?: number; duration?: number } }): string | null {
  const { timeOffset = 0, duration = 0 } = item.state;
  return duration > 0 && duration > timeOffset ? `${minutes((duration - timeOffset) / 1000)} left` : null;
}

function Hero({ items }: { items: Meta[] }) {
  const [index, setIndex] = useState(0);
  const [held, setHeld] = useState(false);
  const touch = useRef<number | null>(null);
  const item = items[Math.min(index, items.length - 1)];
  const step = (d: number) => setIndex((i) => (i + d + items.length) % items.length);

  useEffect(() => {
    if (held || items.length < 2) return;
    const t = setTimeout(() => step(1), SLIDE);
    return () => clearTimeout(t);
  }, [index, held, items.length]);
  // The title on the hero is the likeliest to be opened: have its details ready.
  useEffect(() => { loadMeta(item.type, item.id).catch(() => {}); }, [item.id]);

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
          ? <img key={m.id} src={art.backdrop(m)} class={i === index ? "on" : ""} alt="" decoding="async" /> : null)}
      </div>
      <div class="info" key={item.id}>
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

function ContinueShelf() {
  const list = continueWatching.value;
  if (!list.length) return null;
  return (
    <Shelf title="Continue Watching">
      {list.map((item) => {
        const episode = episodeLabel(item.state.video_id);
        const m = { id: item._id, type: item.type, name: item.name, poster: item.poster };
        return (
          <Link key={item._id} to={`/watch/${item.type}/${encodeURIComponent(item._id)}`} class="card wide" label={`Resume ${item.name}`} warm={m}>
            <Art src={art.wide(m)} fallback={item.name} />
            <div class="over">
              <b>{item.name}</b>
              <small>{[isUpNext(item) ? (episode ? `Next · ${episode}` : "Up Next") : episode, left(item)].filter(Boolean).join(" · ")}</small>
              <div class="bar" style={isUpNext(item) ? { visibility: "hidden" } : undefined}><i style={{ width: `${progressOf(item) * 100}%` }} /></div>
            </div>
          </Link>
        );
      })}
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
