import { useEffect, useState } from "preact/hooks";
import { auth, go, online, path, profileId } from "../lib/core";
import { forgetSession, NeedsCode, relayAuth } from "../lib/api";
import { load, loaded, profile, profiles, signOut as clearLibrary } from "../lib/library";
import { HomePage } from "./home";
import { TitlePage } from "./detail";
import { ListPage, SearchPage } from "./browse";
import { SettingsPage } from "./settings";
import { LinkRelay, SignIn, WhoIsWatching } from "./gates";
import { Player } from "./player";
import { Avatar, Link, MenuHost } from "./shared";
import { Exit, Gear, Home, Search, Stack, Swap } from "./icons";

function Nav() {
  const [menu, setMenu] = useState<{ right: number } | null>(null);
  const here = path.value.split("?")[0];
  const me = profile.value!;
  const tab = (to: string, label: string, Icon: () => preact.JSX.Element) => (
    <Link to={to} class={here === to ? "on" : ""}><Icon />{label}</Link>
  );
  return (
    <>
      <nav class="nav glass" aria-label="Main">
        {tab("/", "Home", Home)}
        {tab("/search", "Search", Search)}
        {tab("/list", "My List", Stack)}
        <button class="me" aria-label={`${me.name}: profile and account`} aria-expanded={!!menu}
          onClick={(e) => {
            // The menu opens under the avatar, wherever the bar puts it, and stays on screen.
            const box = (e.currentTarget as HTMLElement).getBoundingClientRect();
            setMenu(menu ? null : { right: Math.max(12, window.innerWidth - box.right - 8) });
          }}><Avatar profile={me} /></button>
      </nav>
      {menu && (
        <>
          <div class="scrim" onClick={() => setMenu(null)} />
          <div class="menu glass" role="menu" style={{ "--menu-right": `${menu.right}px` }}>
            <button role="menuitem" onClick={() => { setMenu(null); if (profiles.value.length > 1) profileId.value = null; }}>
              <Avatar profile={me} /><span>{me.name}<small>{auth.value?.email}</small></span>
            </button>
            <hr />
            <button role="menuitem" onClick={() => { setMenu(null); go("/settings"); }}><Gear />Settings</button>
            {profiles.value.length > 1 && <button role="menuitem" onClick={() => { setMenu(null); profileId.value = null; }}><Swap />Switch Profile</button>}
            <button role="menuitem" onClick={() => { setMenu(null); auth.value = null; }}><Exit />Sign Out</button>
          </div>
        </>
      )}
    </>
  );
}

/** Said once, quietly, while there's no connection. */
export function Offline() {
  if (online.value) return null;
  return <div class="offline glass" role="status">No connection. Encore picks up where it left off when you're back online.</div>;
}

/** Arrow keys move between things on screen, for TV remotes and keyboards: to the nearest control in
 * that direction. Text fields and the player keep their own arrow keys. */
function useSpatialNavigation() {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const delta: Record<string, [number, number]> = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] };
      const d = delta[e.key];
      if (!d || e.defaultPrevented || path.value.startsWith("/watch")) return;
      const from = document.activeElement as HTMLElement | null;
      if (from && (from.tagName === "INPUT" || from.tagName === "TEXTAREA")) return;
      const all = [...document.querySelectorAll<HTMLElement>("a[href], button:not([disabled]):not([tabindex='-1']), input")].filter((el) => el.offsetParent !== null);
      if (!all.length) return;
      if (!from || from === document.body) { all[0].focus(); e.preventDefault(); return; }
      const a = from.getBoundingClientRect();
      const ax = a.left + a.width / 2, ay = a.top + a.height / 2;
      let best: HTMLElement | null = null, bestScore = Infinity;
      for (const el of all) {
        if (el === from) continue;
        const b = el.getBoundingClientRect();
        const dx = b.left + b.width / 2 - ax, dy = b.top + b.height / 2 - ay;
        const along = dx * d[0] + dy * d[1];
        if (along <= 4) continue;
        const across = Math.abs(dx * d[1] + dy * d[0]);
        const score = along + across * 2.5;
        if (score < bestScore) { best = el; bestScore = score; }
      }
      if (best) { best.focus({ preventScroll: true }); best.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "smooth" }); e.preventDefault(); }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  }, []);
}

export function App() {
  const [linked, setLinked] = useState<"checking" | "yes" | "needs">("checking");
  const signedIn = !!auth.value;
  useSpatialNavigation();

  useEffect(() => {
    if (!signedIn) {
      forgetSession(); clearLibrary();
      profileId.value = null;
      setLinked("checking");
      return;
    }
    load();
    relayAuth().then(() => setLinked("yes"), (e) => setLinked(e instanceof NeedsCode ? "needs" : "yes"));
  }, [signedIn]);

  if (!signedIn) return <SignIn />;
  if (linked === "needs") return <LinkRelay onLinked={() => setLinked("yes")} />;
  if (!loaded.value || linked === "checking") return <div class="stage"><div class="spinner" /></div>;
  if (!profile.value) return <WhoIsWatching />;

  const [route, query] = path.value.split("?");
  const parts = route.split("/").filter(Boolean).map(decodeURIComponent);
  if (parts[0] === "watch" && parts[1] && parts[2]) {
    return <Player key="player" type={parts[1]} id={parts[2]} videoId={new URLSearchParams(query || "").get("v") || undefined} />;
  }
  let page;
  if (parts[0] === "title" && parts[1] && parts[2]) page = <TitlePage key={parts[2]} type={parts[1]} id={parts[2]} focus={new URLSearchParams(query || "").get("v") || undefined} />;
  else if (parts[0] === "search") page = <SearchPage />;
  else if (parts[0] === "list") page = <ListPage />;
  else if (parts[0] === "settings") page = <SettingsPage />;
  else { page = <HomePage />; if (parts.length) queueMicrotask(() => go("/", { replace: true })); }
  return <>{parts[0] !== "title" && <Nav />}{page}<MenuHost /></>;
}
