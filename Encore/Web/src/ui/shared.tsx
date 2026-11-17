// Pieces every screen uses: artwork that fades in, cards, shelves, the avatar.
import type { ComponentChildren } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { signal } from "@preact/signals";
import { go } from "../lib/core";
import { art, meta as loadMeta, type Meta, type Profile } from "../lib/api";
import { Left, Right } from "./icons";

/** Shows an image only once it is decoded, so it fades in whole instead of painting in pieces. */
function reveal(img: HTMLImageElement, show: () => void) {
  if (img.decode) img.decode().then(show, show); else show();
}

/** An image that fades in once loaded; if it fails, the title in type, never a broken-image glyph.
 * One that is already in the browser's cache appears at once, without fading again. */
export function Art(props: { src?: string; alt?: string; fallback?: string; eager?: boolean; class?: string }) {
  const [state, setState] = useState<"wait" | "in" | "now" | "failed">("wait");
  const ref = useRef<HTMLImageElement>(null);
  useEffect(() => { setState(ref.current?.complete && ref.current.naturalWidth ? "now" : "wait"); }, [props.src]);
  return (
    <div class={"art " + (props.class || "")}>
      {props.src && state !== "failed" && (
        <img ref={ref} src={props.src} alt={props.alt || ""} loading={props.eager ? "eager" : "lazy"} decoding="async" draggable={false}
          class={state === "in" ? "in" : state === "now" ? "in now" : ""}
          onLoad={(e) => state === "wait" && reveal(e.currentTarget, () => setState((s) => (s === "wait" ? "in" : s)))} onError={() => setState("failed")} />
      )}
      {(!props.src || state === "failed") && props.fallback && <div class="fallback">{props.fallback}</div>}
    </div>
  );
}

/** Full-bleed artwork that cross-fades: a sharper or different image fades in over the one before,
 * never through black. */
export function Backdrop(props: { src?: string; class?: string }) {
  const [layers, setLayers] = useState<{ src: string; shown: boolean }[]>([]);
  useEffect(() => {
    const src = props.src;
    if (!src) return;
    setLayers((now) => (now.some((l) => l.src === src) ? now : [...now.slice(-1), { src, shown: false }]));
  }, [props.src]);
  const shown = (src: string) => setLayers((now) => {
    const at = now.findIndex((l) => l.src === src);
    if (at < 0) return now;
    // Once the newest is in, the ones under it can go (after its fade).
    const next = now.map((l, i) => (i === at ? { ...l, shown: true } : l));
    if (at === next.length - 1) setTimeout(() => setLayers((later) => { const i = later.findIndex((x) => x.src === src); return i > 0 ? later.slice(i) : later; }), 900);
    return next;
  });
  return (
    <div class={"backdrop " + (props.class || "")}>
      {layers.map((l) => (
        <img key={l.src} src={l.src} alt="" decoding="async" draggable={false} class={l.shown ? "in" : ""}
          ref={(img) => { if (img && !l.shown && img.complete && img.naturalWidth) queueMicrotask(() => shown(l.src)); }}
          onLoad={(e) => reveal(e.currentTarget, () => shown(l.src))} />
      ))}
    </div>
  );
}

export interface Action { label: string; icon?: () => preact.JSX.Element; run: () => void; danger?: boolean }

interface MenuRequest { at: DOMRect; title?: string; subtitle?: string; actions: Action[] }
const openMenu = signal<MenuRequest | null>(null);
/** Opens a menu of actions for one thing (drawn once, at the top of the page, so no row clips it). */
export const showMenu = (request: MenuRequest) => { openMenu.value = request; };

/** Where menus are drawn: once, in the app's root. */
export function MenuHost() {
  const m = openMenu.value;
  return m ? <ActionMenu key={m.at.x + ":" + m.at.y} {...m} onClose={() => { openMenu.value = null; }} /> : null;
}

/** A short menu of actions for one thing: next to it on larger screens, a sheet from the bottom on phones. */
function ActionMenu(props: MenuRequest & { onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === "Escape") { e.preventDefault(); props.onClose(); } };
    addEventListener("keydown", onKey);
    addEventListener("scroll", props.onClose, { passive: true, once: true });
    return () => { removeEventListener("keydown", onKey); removeEventListener("scroll", props.onClose); };
  }, []);
  const first = useRef<HTMLButtonElement>(null);
  useEffect(() => { first.current?.focus({ preventScroll: true }); }, []);
  const phone = innerWidth <= 640;
  const width = 300, room = innerHeight - props.at.bottom;
  const style = phone ? undefined : {
    left: `${Math.min(Math.max(12, props.at.right - width), innerWidth - width - 12)}px`,
    ...(room > 260 ? { top: `${props.at.bottom + 8}px` } : { bottom: `${innerHeight - props.at.top + 8}px` }),
    width: `${width}px`,
  };
  return (
    <>
      <div class={"scrim" + (phone ? " dim" : "")} onClick={props.onClose} />
      <div class={"menu glass" + (phone ? " sheet" : " floating")} role="menu" style={style}>
        {props.title && <div class="menu-head"><b>{props.title}</b>{props.subtitle && <small>{props.subtitle}</small>}</div>}
        {props.actions.map((a, i) => (
          <button key={a.label} ref={i === 0 ? first : undefined} role="menuitem" class={a.danger ? "danger" : ""} onClick={() => { props.onClose(); a.run(); }}>
            {a.icon && <a.icon />}{a.label}
          </button>
        ))}
      </div>
    </>
  );
}

/** Long-press on touch screens (and right-click) opens a menu instead of following the link. */
export function usePress(open: (box: DOMRect) => void) {
  const timer = useRef<number>();
  const fired = useRef(false);
  const start = useRef<{ x: number; y: number } | null>(null);
  return {
    onContextMenu: (e: MouseEvent) => { e.preventDefault(); open((e.currentTarget as HTMLElement).getBoundingClientRect()); },
    onPointerDown: (e: PointerEvent) => {
      if (e.pointerType !== "touch") return;
      fired.current = false;
      start.current = { x: e.clientX, y: e.clientY };
      const el = e.currentTarget as HTMLElement;
      timer.current = setTimeout(() => { fired.current = true; navigator.vibrate?.(10); open(el.getBoundingClientRect()); }, 480) as unknown as number;
    },
    onPointerMove: (e: PointerEvent) => {
      if (start.current && Math.hypot(e.clientX - start.current.x, e.clientY - start.current.y) > 10) clearTimeout(timer.current);
    },
    onPointerUp: () => clearTimeout(timer.current),
    onPointerCancel: () => clearTimeout(timer.current),
    onClickCapture: (e: MouseEvent) => { if (fired.current) { e.preventDefault(); e.stopPropagation(); fired.current = false; } },
  };
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
export function Shelf(props: { title: string; children: ComponentChildren; class?: string }) {
  const row = useRef<HTMLDivElement>(null);
  const [ends, setEnds] = useState({ left: true, right: false });
  const measure = () => {
    const el = row.current;
    if (el) setEnds({ left: el.scrollLeft < 8, right: el.scrollLeft + el.clientWidth > el.scrollWidth - 8 });
  };
  useEffect(measure, [props.children]);
  const page = (direction: number) => row.current?.scrollBy({ left: direction * row.current.clientWidth * 0.85, behavior: "smooth" });
  return (
    <section class={"shelf" + (props.class ? " " + props.class : "")}>
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

/** A title's logo, faded in once it's decoded; its name in type when there's none. The space it will
 * take is held while it loads, so nothing below it jumps. */
export function Logo({ src, name }: { src?: string; name: string }) {
  // Kept by address, so a new title's logo gets its own try and its own fade.
  const [state, setState] = useState<{ src?: string; is: "wait" | "in" | "failed" }>({ is: "wait" });
  const now = state.src === src ? state.is : "wait";
  if (!src || now === "failed") return <h1 class="logo-text">{name}</h1>;
  return (
    <div class={"logo-box" + (now === "in" ? " in" : "")}>
      <img class="logo" src={src} alt={name} draggable={false} decoding="async"
        ref={(img) => { if (img && now === "wait" && img.complete && img.naturalWidth) queueMicrotask(() => setState({ src, is: "in" })); }}
        onLoad={(e) => reveal(e.currentTarget, () => setState({ src, is: "in" }))} onError={() => setState({ src, is: "failed" })} />
    </div>
  );
}
