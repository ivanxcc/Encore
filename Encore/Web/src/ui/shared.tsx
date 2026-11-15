// Pieces every screen uses: artwork that fades in, cards, shelves, the avatar.
import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { go } from "../lib/core";
import { art, meta as loadMeta, type Meta, type Profile } from "../lib/api";
import { Left, Right } from "./icons";

/** An image that fades in once loaded; if it fails, the title in type, never a broken-image glyph. */
export function Art(props: { src?: string; alt?: string; fallback?: string; eager?: boolean; class?: string }) {
  const [state, setState] = useState<"wait" | "in" | "failed">("wait");
  const ref = useRef<HTMLImageElement>(null);
  useEffect(() => { setState(ref.current?.complete && ref.current.naturalWidth ? "in" : "wait"); }, [props.src]);
  return (
    <div class={"art " + (props.class || "")}>
      {props.src && state !== "failed" && (
        <img ref={ref} src={props.src} alt={props.alt || ""} loading={props.eager ? "eager" : "lazy"} decoding="async" draggable={false}
          class={state === "in" ? "in" : ""} onLoad={() => setState("in")} onError={() => setState("failed")} />
      )}
      {(!props.src || state === "failed") && props.fallback && <div class="fallback">{props.fallback}</div>}
    </div>
  );
}

const COLORS = [["#3a7bfa", "#1f4fd6"], ["#f25c5c", "#c93a4b"], ["#fab033", "#e2801c"], ["#4dc778", "#2a9a5c"], ["#a366f2", "#7340d0"], ["#fa73b3", "#d6478c"]];

export function Avatar({ profile }: { profile: Profile }) {
  const [c1, c2] = COLORS[(profile.colorIndex || 0) % COLORS.length];
  // The apps store an emoji or the name of an Apple symbol; a symbol name becomes the initial here.
  const emoji = profile.avatar && /\p{Extended_Pictographic}/u.test(profile.avatar) ? profile.avatar : null;
  return <span class="avatar" style={{ "--c1": c1, "--c2": c2 }}>{emoji || (profile.name || "?").trim().charAt(0).toUpperCase()}</span>;
}

export const titlePath = (m: { type: string; id: string }) => `/title/${m.type}/${encodeURIComponent(m.id)}`;

/** A link that changes the page without reloading, and fetches a title's details as the pointer arrives. */
export function Link(props: { to: string; class?: string; children: ComponentChildren; warm?: Meta; label?: string }) {
  return (
    <a href={props.to} class={props.class} aria-label={props.label}
      onClick={(e) => { if (e.metaKey || e.ctrlKey || e.shiftKey) return; e.preventDefault(); go(props.to); }}
      onPointerEnter={props.warm ? () => { loadMeta(props.warm!.type, props.warm!.id).catch(() => {}); } : undefined}>
      {props.children}
    </a>
  );
}

export function PosterCard({ meta }: { meta: Meta }) {
  return (
    <Link to={titlePath(meta)} class="card" warm={meta} label={meta.name}>
      <Art src={art.poster(meta)} fallback={meta.name} />
    </Link>
  );
}

/** A titled row that scrolls sideways: by touch or trackpad, or by the arrows that appear at its edges. */
export function Shelf(props: { title: string; children: ComponentChildren }) {
  const row = useRef<HTMLDivElement>(null);
  const [ends, setEnds] = useState({ left: true, right: false });
  const measure = () => {
    const el = row.current;
    if (el) setEnds({ left: el.scrollLeft < 8, right: el.scrollLeft + el.clientWidth > el.scrollWidth - 8 });
  };
  useEffect(measure, [props.children]);
  const page = (direction: number) => row.current?.scrollBy({ left: direction * row.current.clientWidth * 0.85, behavior: "smooth" });
  return (
    <section class="shelf">
      <h2>{props.title}</h2>
      <div class="row" ref={row} onScroll={measure}>{props.children}</div>
      <button class="edge left" disabled={ends.left} tabIndex={-1} aria-hidden="true" onClick={() => page(-1)}><Left /></button>
      <button class="edge right" disabled={ends.right} tabIndex={-1} aria-hidden="true" onClick={() => page(1)}><Right /></button>
    </section>
  );
}

export function SkeletonShelf({ title, wide }: { title: string; wide?: boolean }) {
  return (
    <section class="shelf skeleton" aria-hidden="true">
      <h2>{title}</h2>
      <div class="row">{Array.from({ length: 10 }, (_, i) => <div key={i} class={"card" + (wide ? " wide" : "")}><div class="art" /></div>)}</div>
    </section>
  );
}

/** Runs once the element is near the screen (shelves below the fold load as they are approached). */
export function useNearScreen<T extends HTMLElement>(): [{ current: T | null }, boolean] {
  const ref = useRef<T>(null);
  const [near, setNear] = useState(false);
  useEffect(() => {
    if (near || !ref.current) return;
    const io = new IntersectionObserver((entries) => { if (entries.some((e) => e.isIntersecting)) setNear(true); }, { rootMargin: "600px 0px" });
    io.observe(ref.current);
    return () => io.disconnect();
  }, [near]);
  return [ref, near];
}

export function MetaLine({ meta, extra }: { meta: Meta; extra?: { runtime?: string; certification?: string } }) {
  const genres = (meta.genres || []).slice(0, 2).join(", ");
  return (
    <div class="meta">
      {meta.releaseInfo && <span>{meta.releaseInfo}</span>}
      {(extra?.runtime || meta.runtime) && <span>{extra?.runtime || meta.runtime}</span>}
      {genres && <span>{genres}</span>}
      {extra?.certification && <span><b class="badge">{extra.certification}</b></span>}
      {meta.imdbRating && <span><b class="imdb">IMDb</b>{meta.imdbRating}</span>}
    </div>
  );
}

export function Logo({ src, name }: { src?: string; name: string }) {
  // Remembers which address failed, so a new title's logo gets its own try.
  const [failed, setFailed] = useState<string>();
  return src && failed !== src
    ? <img class="logo" src={src} alt={name} onError={() => setFailed(src)} draggable={false} />
    : <h1 class="logo-text">{name}</h1>;
}
