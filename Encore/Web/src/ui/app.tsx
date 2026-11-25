import { useEffect, useState } from "preact/hooks";
import { auth, go, online, path, profileId } from "../lib/core";
import { forgetSession, NeedsCode, Paused, relayAuth } from "../lib/api";
import { load, loaded, profile, profiles, signOut as clearLibrary } from "../lib/library";
import { HomePage } from "./home";
import { TitlePage } from "./detail";
import { ListPage, SearchPage } from "./browse";
import { SettingsPage } from "./settings";
import { AdminPage } from "./admin";
import { admin, freshAddons, installAddons, type Addon } from "../lib/api";
import { reportProfiles } from "../lib/report";
import { relayToken } from "../lib/core";
import { LinkRelay, SignIn, WhoIsWatching } from "./gates";
import { Player } from "./player";
import { Avatar, Link, MenuHost } from "./shared";
import { Chart, Check, Close, Exit, Gear, Home, Search, Stack, Swap } from "./icons";

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
            {relayToken.value?.admin && <button role="menuitem" onClick={() => { setMenu(null); go("/admin"); }}><Chart />Admin</button>}
            {profiles.value.length > 1 && <button role="menuitem" onClick={() => { setMenu(null); profileId.value = null; }}><Swap />Switch Profile</button>}
            <button role="menuitem" onClick={() => { setMenu(null); auth.value = null; }}><Exit />Sign Out</button>
          </div>
        </>
      )}
    </>
  );
}

// Safari on an iPhone or iPad (iPadOS calls itself a Mac with a touch screen), not already opened from
// the Home Screen.
const iosSafari = (() => {
  const ua = navigator.userAgent;
  const ios = /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
  const safari = /Safari/.test(ua) && !/CriOS|FxiOS|EdgiOS|OPiOS|GSA\//.test(ua);
  const standalone = (navigator as Navigator & { standalone?: boolean }).standalone === true || matchMedia("(display-mode: standalone)").matches;
  return ios && safari && !standalone;
})();

/** A quiet suggestion, once (and again after a month if it's still in the browser): on the Home
 * Screen, Encore opens full screen, without Safari's bars, like an app. */
function InstallHint() {
  const [shown, setShown] = useState(false);
  useEffect(() => {
    if (!iosSafari) return;
    let last = 0;
    try { last = Number(localStorage.getItem("encore.installHint") || 0); } catch {}
    if (Date.now() - last < 30 * 86400_000) return;
    const t = setTimeout(() => setShown(true), 6000);
    return () => clearTimeout(t);
  }, []);
  if (!shown) return null;
  const close = () => { setShown(false); try { localStorage.setItem("encore.installHint", String(Date.now())); } catch {} };
  return (
    <div class="install glass" role="status">
      <img src="/icon-180.png" alt="" />
      <div>
        <b>Add Encore to your Home Screen</b>
        <span>Tap <ShareGlyph /> then <em>Add to Home Screen</em>. It opens full screen, like an app. You'll sign in once more there.</span>
      </div>
      <button class="icon" aria-label="Not now" onClick={close}><Close /></button>
    </div>
  );
}

const ShareGlyph = () => (
  <svg class="share" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-label="Share">
    <path d="M12 3v12M8 7l4-4 4 4M6 11H5v10h14V11h-1" />
  </svg>
);

/** Once a visit: the profiles in this household, for the server owner's People page. */
let profilesSent = false;
function Reports() {
  useEffect(() => {
    if (profilesSent || !relayToken.value) return;
    profilesSent = true;
    reportProfiles(profiles.value.map((p) => ({ name: p.name, avatar: p.avatar, kids: !!p.isKids, pin: !!p.pinHash })));
  }, []);
  return null;
}

/** For someone invited, once: the add-ons the server's owner offers, to add in one tap. */
function StarterOffer() {
  const [offer, setOffer] = useState<{ addons: Addon[]; from?: string } | null>(null);
  const [chosen, setChosen] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);
  const key = "encore.starter." + (auth.value?.email || "");
  useEffect(() => {
    if (relayToken.value?.admin || !auth.value) return;
    try { if (localStorage.getItem(key)) return; } catch { return; }
    let live = true;
    Promise.all([admin.starter(), freshAddons()]).then(([s, mine]) => {
      const have = new Set(mine.map((a) => a.transportUrl));
      const missing = s.addons.filter((a) => a && a.transportUrl && !have.has(a.transportUrl));
      if (!live) return;
      if (!missing.length) { try { localStorage.setItem(key, "done"); } catch {} return; }
      setChosen(new Set(missing.map((a) => a.transportUrl)));
      setOffer({ addons: missing, from: s.from });
    }, () => {});
    return () => { live = false; };
  }, []);
  if (!offer) return null;
  const done = () => { try { localStorage.setItem(key, "done"); } catch {} setOffer(null); };
  const add = async () => {
    setBusy(true);
    try { await installAddons(offer.addons.filter((a) => chosen.has(a.transportUrl))); done(); location.reload(); } catch { setBusy(false); }
  };
  return (
    <>
      <div class="scrim dim" />
      <div class="sources glass starter" role="dialog" aria-label="Add-ons">
        <div class="sources-head"><div><b>Set Up Your Add-ons</b><small>{offer.from ? `${offer.from} offers these` : "This server's owner offers these"} so you can find and play everything here.</small></div></div>
        <div class="sources-list">
          {offer.addons.map((a) => (
            <label key={a.transportUrl} class="setting check-row">
              <input type="checkbox" checked={chosen.has(a.transportUrl)} onChange={() => { const n = new Set(chosen); if (n.has(a.transportUrl)) n.delete(a.transportUrl); else n.add(a.transportUrl); setChosen(n); }} />
              <div class="words"><b>{a.manifest.name}</b><small>{(a.manifest as { description?: string }).description?.slice(0, 110) || ""}</small></div>
            </label>
          ))}
          <p class="quiet note">They're added to your Stremio account, so every Stremio app sees them too. You can remove them there any time.</p>
        </div>
        <div class="actions sheet-actions">
          <button class="pill secondary" onClick={done}>Not Now</button>
          <button class="pill primary" disabled={busy || !chosen.size} onClick={add}>{busy ? "Adding…" : <><Check />Add {chosen.size} Add-on{chosen.size === 1 ? "" : "s"}</>}</button>
        </div>
      </div>
    </>
  );
}

/** The server's owner has paused this account: said plainly, with a way to check again. */
function PausedGate({ onRetry }: { onRetry: () => void }) {
  return (
    <div class="stage">
      <div class="gate-note">
        <h1>Paused</h1>
        <p class="quiet">Your access to this Encore server is paused. Ask its owner if you think that's a mistake.</p>
        <div class="actions"><button class="pill primary" onClick={onRetry}>Check Again</button><button class="pill secondary" onClick={() => { auth.value = null; }}>Sign Out</button></div>
      </div>
    </div>
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
  const [linked, setLinked] = useState<"checking" | "yes" | "needs" | "paused">("checking");
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
    const settle = (e: unknown) => setLinked(e instanceof NeedsCode ? "needs" : e instanceof Paused ? "paused" : "yes");
    // A saved token opens the app at once; the server is asked in the background whether this
    // account is still welcome (paused or removed since), and the app follows its answer.
    relayAuth().then(() => {
      setLinked("yes");
      relayAuth(undefined, true).catch((e) => { if (e instanceof NeedsCode || e instanceof Paused) settle(e); });
    }, settle);
  }, [signedIn]);

  if (!signedIn) return <SignIn />;
  if (linked === "needs") return <LinkRelay onLinked={() => setLinked("yes")} />;
  if (linked === "paused") return <PausedGate onRetry={() => relayAuth().then(() => setLinked("yes"), () => {})} />;
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
  else if (parts[0] === "admin") page = <AdminPage key={parts.join("/")} tab={new URLSearchParams(query || "").get("tab") || undefined} email={parts[1] === "people" ? parts[2] : undefined} />;
  else { page = <HomePage />; if (parts.length) queueMicrotask(() => go("/", { replace: true })); }
  const bare = parts[0] === "title" || (parts[0] === "admin" && parts[1] === "people");
  return <>{!bare && <Nav />}{page}<MenuHost />{!bare && <InstallHint />}<Reports /><StarterOffer /></>;
}
