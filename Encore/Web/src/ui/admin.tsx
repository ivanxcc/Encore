// Admin: for the server's owner only (the server checks too). What's playing now and how the server
// is doing; the people who use it, with their profiles, devices, history, and how well things play
// for them; invitations; and the add-ons offered to people who join.
import { useEffect, useState } from "preact/hooks";
import { go, relayToken } from "../lib/core";
import { admin, freshAddons, inviteLink, relayChange, relayInvite, relayPeople, relayRemove, type Addon, type InviteRecord, type Overview, type PersonPage, type Play, type RelayPerson } from "../lib/api";
import { QR } from "./gates";
import { Check, Left } from "./icons";

// MARK: Little formatters

export function ago(unix?: number): string {
  if (!unix) return "never";
  const m = Math.round((Date.now() / 1000 - unix) / 60);
  if (m < 2) return "just now";
  if (m < 60) return `${m} min ago`;
  const h = Math.round(m / 60);
  if (h < 24) return `${h} hr ago`;
  const d = Math.round(h / 24);
  return d < 30 ? `${d} day${d === 1 ? "" : "s"} ago` : date(unix);
}
const date = (unix: number) => new Date(unix * 1000).toLocaleDateString(undefined, { month: "short", day: "numeric", year: new Date(unix * 1000).getFullYear() === new Date().getFullYear() ? undefined : "numeric" });
const clockTime = (unix: number) => new Date(unix * 1000).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });
const hours = (h: number) => (h < 1 ? `${Math.round(h * 60)} min` : `${h.toFixed(h < 10 ? 1 : 0)} hr`);
const duration = (sec: number) => (sec < 60 ? `${Math.round(sec)} s` : sec < 3600 ? `${Math.round(sec / 60)} min` : `${Math.floor(sec / 3600)} hr ${Math.round((sec % 3600) / 60)} min`);
const bytes = (n: number) => (n < 1e6 ? `${Math.round(n / 1e3)} KB` : n < 1e9 ? `${(n / 1e6).toFixed(0)} MB` : `${(n / 1e9).toFixed(n < 1e10 ? 1 : 0)} GB`);
const seconds = (ms?: number) => (ms ? (ms < 1000 ? `${ms} ms` : `${(ms / 1000).toFixed(1)} s`) : "–");
const MODES: Record<string, string> = { direct: "From source", proxied: "Through server", remux: "Prepared", converted: "Converted" };
const who = (p: { name?: string; email?: string; who?: string }) => p.name || p.email || p.who || "";

function Toggle({ on, label, onChange }: { on: boolean; label: string; onChange: (v: boolean) => void }) {
  return <button role="switch" aria-checked={on} aria-label={label} class={"switch" + (on ? " on" : "")} onClick={() => onChange(!on)}><i /></button>;
}

function Tile({ label, value, note, level }: { label: string; value: string; note?: string; level?: "good" | "warn" | "bad" }) {
  return <div class={"tile" + (level ? " " + level : "")}><small>{label}</small><b>{value}</b>{note && <span>{note}</span>}</div>;
}

// MARK: The page

const TABS = [["overview", "Overview"], ["people", "People"], ["invites", "Invitations"], ["addons", "Add-ons"]] as const;

export function AdminPage({ tab, email }: { tab?: string; email?: string }) {
  if (!relayToken.value?.admin) {
    return <div class="page padded settings"><h1 class="heading">Admin</h1><p class="quiet" style={{ padding: "0 var(--edge)" }}>Only the owner of this server can see this.</p></div>;
  }
  if (email) return <PersonView email={email} />;
  const now = TABS.find(([t]) => t === tab)?.[0] || "overview";
  return (
    <div class="page padded admin">
      <h1 class="heading">Admin</h1>
      <div class="tabs admin-tabs" role="tablist">
        {TABS.map(([t, name]) => <button key={t} role="tab" aria-selected={now === t} class={now === t ? "on" : ""} onClick={() => go(`/admin?tab=${t}`, { replace: true })}>{name}</button>)}
      </div>
      {now === "overview" && <OverviewView />}
      {now === "people" && <PeopleView />}
      {now === "invites" && <InvitesView />}
      {now === "addons" && <AddonsView />}
    </div>
  );
}

// MARK: Overview

function OverviewView() {
  const [o, setO] = useState<Overview | null>(null);
  const [failed, setFailed] = useState(false);
  const [stopping, setStopping] = useState<string | null>(null);
  const load = () => admin.overview().then((x) => { setO(x); setFailed(false); }, () => setFailed(true));
  useEffect(() => { load(); const t = setInterval(load, 10_000); return () => clearInterval(t); }, []);
  if (o) { o.live = o.live || []; o.problems = o.problems || []; o.traffic = o.traffic || []; }
  if (!o) return failed ? <p class="quiet pad">The server didn't answer. It may be restarting.</p> : <div class="pad"><div class="spinner" /></div>;
  const s = o.server;
  const max = Math.max(1, ...o.traffic.map((t) => t.bytes));
  const day = o.traffic.slice(-24).reduce((n, t) => n + t.bytes, 0);
  const stop = async (p: Play) => { await admin.endPlay(p.id).catch(() => {}); setStopping(null); load(); };
  return (
    <div class="admin-body">
      <h2 class="group-title">Watching Now</h2>
      {o.live.length ? (
        <section class="group">
          {o.live.map((p) => (
            <div key={p.id} class="setting live-row">
              <div class="words">
                <b>{p.title}{p.episode ? <span class="dim"> · {p.episode}</span> : null}</b>
                <small>{[who(p), p.profile && p.profile !== who(p) ? `as ${p.profile}` : "", p.device, p.quality, MODES[p.mode || ""] || p.mode].filter(Boolean).join(" · ")}</small>
                <small>Started {clockTime(p.at)} · {duration(Math.max(p.watched, Date.now() / 1000 - p.at))} in{p.stalls ? ` · ${p.stalls} stall${p.stalls === 1 ? "" : "s"}` : ""}</small>
              </div>
              {stopping === p.id
                ? <span class="actions"><button class="pill small danger" onClick={() => stop(p)}>Stop</button><button class="pill secondary small" onClick={() => setStopping(null)}>Cancel</button></span>
                : <button class="pill secondary small" onClick={() => setStopping(p.id)}>Stop…</button>}
            </div>
          ))}
        </section>
      ) : <p class="quiet pad">No one is watching right now.</p>}

      <h2 class="group-title">Server</h2>
      <div class="tiles">
        <Tile label="Processor" value={s.load >= 0 ? `${Math.round(s.load * 100)}%` : "–"} note={`${s.cpus} cores`} level={s.load > 0.9 ? "bad" : s.load > 0.6 ? "warn" : "good"} />
        <Tile label="Memory" value={s.memory >= 0 ? `${Math.round(s.memory * 100)}%` : "–"} level={s.memory > 0.9 ? "bad" : s.memory > 0.75 ? "warn" : "good"} />
        <Tile label="Watching Now" value={String(o.live.length)} note={s.converting ? `${s.converting} converting` : `Converting: ${s.convertMode}`} />
        <Tile label="Last 24 Hours" value={bytes(day)} note="sent to viewers" />
        <Tile label="Up For" value={duration(s.uptime)} note={s.version} />
        <Tile label="Saved Data" value={bytes(s.dataBytes)} note="people and activity" />
      </div>

      <h2 class="group-title">Traffic, Last 48 Hours</h2>
      <div class="group chart" role="img" aria-label={`Traffic over the last 48 hours; ${bytes(day)} in the last 24.`}>
        <div class="bars">
          {o.traffic.map((t) => <i key={t.hour} style={{ height: `${Math.max(1.5, (t.bytes / max) * 100)}%` }} class={t.bytes ? "" : "none"} title={`${new Date(t.hour * 1000).toLocaleString(undefined, { weekday: "short", hour: "numeric" })} · ${bytes(t.bytes)}`} />)}
        </div>
        <div class="axis"><span>48 hours ago</span><span>24 hours ago</span><span>Now</span></div>
      </div>
      <p class="quiet note">Counted since the server last started. Files played from the source directly don't pass through it.</p>

      <h2 class="group-title">Problems</h2>
      {o.problems.length ? (
        <section class="group">
          {o.problems.slice(0, 15).map((p, i) => (
            <div key={i} class="setting"><div class="words"><b class="problem-text">{p.what}</b><small>{[ago(p.at), p.who].filter(Boolean).join(" · ")}</small></div></div>
          ))}
        </section>
      ) : <p class="quiet pad">Nothing has gone wrong since the server started.</p>}
    </div>
  );
}

// MARK: People

function PeopleView() {
  const [people, setPeople] = useState<RelayPerson[] | null>(null);
  useEffect(() => { relayPeople().then(setPeople, () => setPeople([])); }, []);
  if (!people) return <div class="pad"><div class="spinner" /></div>;
  return (
    <div class="admin-body">
      <section class="group">
        {people.map((p) => {
          const status = p.paused ? "Paused" : p.watching ? "Watching now" : `Last seen ${ago(p.lastSeen)}`;
          return (
            <button key={p.email} class="setting person-head" onClick={() => go(`/admin/people/${encodeURIComponent(p.email)}`)}>
              <span class="initial">{(p.name || p.email).charAt(0).toUpperCase()}</span>
              <div class="words"><b>{p.name || p.email}{p.you ? " (you)" : ""}</b><small>{[p.name ? p.email : "", p.admin ? "Owner" : "", status].filter(Boolean).join(" · ")}</small></div>
              {p.paused ? <i class="badge-paused">Paused</i> : p.watching ? <i class="badge-live">Live</i> : null}
              <span class="chev" aria-hidden="true">›</span>
            </button>
          );
        })}
      </section>
      <p class="quiet note"><button class="link" onClick={() => go("/admin?tab=invites", { replace: true })}>Invite someone</button> to add a person.</p>
    </div>
  );
}

function PersonView({ email }: { email: string }) {
  const [p, setP] = useState<PersonPage | null>(null);
  const [failed, setFailed] = useState(false);
  const [confirm, setConfirm] = useState(false);
  const [naming, setNaming] = useState(false);
  const load = () => admin.person(email).then(setP, () => setFailed(true));
  useEffect(() => { load(); }, [email]);
  if (!p) return <div class="page padded admin">{failed ? <p class="quiet pad">This person doesn't use this server.</p> : <div class="pad"><div class="spinner" /></div>}</div>;
  const change = async (edit: { paused?: boolean; streams?: number; convert?: boolean; direct?: boolean; name?: string }) => {
    setP({ ...p, ...edit });
    await relayChange(p.email, edit).catch(load);
  };
  const s = p.summary;
  const byDay = new Map<string, Play[]>();
  for (const play of p.plays) {
    const d = new Date(play.at * 1000).toLocaleDateString(undefined, { weekday: "long", month: "long", day: "numeric" });
    byDay.set(d, [...(byDay.get(d) || []), play]);
  }
  const months = Object.entries(p.months).sort(([a], [b]) => b.localeCompare(a));
  return (
    <div class="page padded admin">
      <button class="back glass" aria-label="Back to People" onClick={() => go("/admin?tab=people")}><Left /></button>
      <div class="person-top">
        <span class="initial big">{(p.name || p.email).charAt(0).toUpperCase()}</span>
        <div>
          {naming ? (
            <form class="rename" onSubmit={(e) => { e.preventDefault(); const v = (e.currentTarget.elements.namedItem("n") as HTMLInputElement).value; change({ name: v }); setNaming(false); }}>
              <input name="n" class="field" defaultValue={p.name || ""} placeholder="Name" autoFocus maxLength={60} />
              <button class="pill primary small">Save</button>
            </form>
          ) : <h1>{p.name || p.email} {!p.admin && <button class="link small-link" onClick={() => setNaming(true)}>{p.name ? "Rename" : "Add a name"}</button>}</h1>}
          <p class="quiet">{[p.name ? p.email : "", p.admin ? "Owner of this server" : p.invitedBy ? `Invited by ${p.invitedBy}` : "", p.since ? `joined ${date(p.since)}` : "", `last seen ${ago(p.lastSeen)}`].filter(Boolean).join(" · ")}</p>
        </div>
      </div>

      <div class="tiles">
        <Tile label="This Week" value={hours(s.hours7)} note={`${s.plays7} play${s.plays7 === 1 ? "" : "s"}`} />
        <Tile label="Last 30 Days" value={hours(s.hours30)} note={`${s.plays30} play${s.plays30 === 1 ? "" : "s"}`} />
        <Tile label="Typical Start" value={seconds(s.startMs)} note="to the first frame" level={!s.startMs ? undefined : s.startMs < 3000 ? "good" : s.startMs < 6000 ? "warn" : "bad"} />
        <Tile label="Stalls" value={s.stallsPerHour ? `${s.stallsPerHour.toFixed(1)} / hr` : "None"} note="last 30 days" level={s.stallsPerHour > 3 ? "bad" : s.stallsPerHour > 1 ? "warn" : "good"} />
        <Tile label="Errors" value={String(s.errors30)} note="last 30 days" level={s.errors30 > 3 ? "warn" : "good"} />
      </div>

      {!p.admin && (
        <>
          <h2 class="group-title">Access</h2>
          <section class="group">
            <div class="setting">
              <div class="words"><b>Screens at Once</b><small>How many streams they can watch at the same time.</small></div>
              <div class="segmented" role="radiogroup" aria-label="Screens at once">
                {[1, 2, 3].map((n) => <button key={n} role="radio" aria-checked={p.streams === n} class={p.streams === n ? "on" : ""} onClick={() => change({ streams: n })}>{n}</button>)}
              </div>
            </div>
            <div class="setting">
              <div class="words"><b>Converting</b><small>Lets the server re-encode video their browser can't play. Uses most of the server's processor.</small></div>
              <Toggle label="Converting" on={p.convert} onChange={(v) => change({ convert: v })} />
            </div>
            <div class="setting">
              <div class="words"><b>Play Straight From the Source</b><small>Off: everything they watch passes through this server, so the source only ever sees the server.</small></div>
              <Toggle label="Play straight from the source" on={p.direct} onChange={(v) => change({ direct: v })} />
            </div>
            <div class="setting">
              <div class="words"><b>{p.paused ? "Paused" : "Pause Access"}</b><small>{p.paused ? "Nothing plays for them until you resume." : "Stops what they're watching now; nothing plays until you resume."}</small></div>
              <Toggle label="Paused" on={p.paused} onChange={(v) => change({ paused: v })} />
            </div>
            <div class="setting">
              <div class="words"><b>Remove</b><small>Takes them off this server and deletes their activity here. They'd need a new invitation.</small></div>
              {confirm
                ? <span class="actions"><button class="pill small danger" onClick={async () => { await relayRemove(p.email).catch(() => {}); go("/admin?tab=people"); }}>Remove</button><button class="pill secondary small" onClick={() => setConfirm(false)}>Cancel</button></span>
                : <button class="pill secondary small danger" onClick={() => setConfirm(true)}>Remove…</button>}
            </div>
          </section>
        </>
      )}

      <h2 class="group-title">Profiles</h2>
      {p.profiles?.length ? (
        <div class="profiles-row">
          {p.profiles.map((x) => (
            <div key={x.name} class="profile-chip">
              <span class="initial">{x.avatar && /\p{Extended_Pictographic}/u.test(x.avatar) ? x.avatar : x.name.charAt(0).toUpperCase()}</span>
              <b>{x.name}</b><small>{[x.kids ? "Kids" : "", x.pin ? "PIN" : ""].filter(Boolean).join(" · ") || " "}</small>
            </div>
          ))}
        </div>
      ) : <p class="quiet pad">Not reported yet: their profiles show here once they open Encore Web.</p>}

      {p.devices && Object.keys(p.devices).length > 0 && (
        <>
          <h2 class="group-title">Devices</h2>
          <section class="group">
            {Object.entries(p.devices).sort(([, a], [, b]) => b - a).map(([d, t]) => (
              <div key={d} class="setting"><div class="words"><b>{d}</b><small>Last used {ago(t)}</small></div></div>
            ))}
          </section>
        </>
      )}

      <h2 class="group-title">History</h2>
      {byDay.size ? [...byDay.entries()].map(([day, plays]) => (
        <div key={day} class="history-day">
          <h3>{day}</h3>
          <section class="group">
            {plays.map((x) => (
              <div key={x.id} class="setting history-row">
                <span class="time">{clockTime(x.at)}</span>
                <div class="words">
                  <b>{x.title}{x.episode ? <span class="dim"> · {x.episode}</span> : null}</b>
                  <small>{[x.profile, x.device, x.quality, MODES[x.mode || ""] || x.mode].filter(Boolean).join(" · ")}</small>
                  {x.problem && <small class="problem-text">{x.problem}</small>}
                </div>
                <div class="numbers">
                  <b>{duration(x.watched)}</b>
                  <small>{seconds(x.startMs)} start{x.stalls ? ` · ${x.stalls} stall${x.stalls === 1 ? "" : "s"}` : ""}</small>
                </div>
              </div>
            ))}
          </section>
        </div>
      )) : <p class="quiet pad">Nothing watched in the last 90 days.</p>}

      {months.length > 0 && (
        <>
          <h2 class="group-title">By Month</h2>
          <section class="group">
            {months.map(([m, t]) => (
              <div key={m} class="setting"><div class="words"><b>{new Date(m + "-15").toLocaleDateString(undefined, { month: "long", year: "numeric" })}</b></div>
                <div class="numbers"><b>{hours(t.seconds / 3600)}</b><small>{t.plays} play{t.plays === 1 ? "" : "s"}</small></div></div>
            ))}
          </section>
          <p class="quiet note">Each play's detail is kept 90 days; after that, only the month's totals.</p>
        </>
      )}
    </div>
  );
}

// MARK: Invitations

function InvitesView() {
  const [list, setList] = useState<InviteRecord[] | null>(null);
  const [made, setMade] = useState<{ link: string; expiresAt: number; label: string } | null>(null);
  const [label, setLabel] = useState("");
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState<string | null>(null);
  const load = () => admin.invites().then(setList, () => setList([]));
  useEffect(() => { load(); }, []);
  const create = async (e: Event) => {
    e.preventDefault();
    setBusy(true);
    try { const r = await relayInvite(label.trim()); setMade({ ...r, label: label.trim() }); setLabel(""); load(); } catch {}
    setBusy(false);
  };
  const share = async (link: string, id: string) => {
    const nav = navigator as Navigator & { share?: (d: ShareData) => Promise<void> };
    if (nav.share && matchMedia("(pointer: coarse)").matches) { nav.share({ title: "Join me on Encore", url: link }).catch(() => {}); return; }
    try { await navigator.clipboard.writeText(link); setCopied(id); setTimeout(() => setCopied(null), 2000); } catch {}
  };
  const now = Date.now() / 1000;
  const state = (i: InviteRecord) => i.usedBy ? `Joined as ${i.usedBy} · ${date(i.usedAt!)}` : i.revoked ? "Withdrawn" : i.expires < now ? `Expired ${date(i.expires)}` : `Open until ${date(i.expires)}`;
  return (
    <div class="admin-body">
      <section class="group">
        <form class="setting" onSubmit={create}>
          <div class="words"><b>New Invitation</b><small>Works once, for one Stremio account, for 7 days. The name is how they'll show in People.</small></div>
          <input class="field name-field" placeholder="Their name (optional)" value={label} maxLength={60} onInput={(e) => setLabel((e.target as HTMLInputElement).value)} />
          <button class="pill primary small" disabled={busy}>{busy ? "Creating…" : "Create Link"}</button>
        </form>
        {made && (
          <div class="setting invite">
            <div class="qr small"><QR text={made.link} label="QR code with the invitation link" /></div>
            <div class="words">
              <b>{made.label ? `Invitation for ${made.label}` : "Invitation ready"}</b>
              <small>Send it, or have them scan the code. They'll sign in with their own Stremio account.</small>
              <input class="field link-field" readOnly value={made.link} onFocus={(e) => (e.target as HTMLInputElement).select()} aria-label="Invitation link" />
              <div class="actions">
                <button class="pill primary small" onClick={() => share(made.link, "new")}>{copied === "new" ? <><Check />Copied</> : "Share Link"}</button>
                <button class="pill secondary small" onClick={() => setMade(null)}>Done</button>
              </div>
            </div>
          </div>
        )}
      </section>
      <h2 class="group-title">Sent</h2>
      {list?.length ? (
        <section class="group">
          {list.map((i) => (
            <div key={i.id} class={"setting" + (i.usedBy || i.revoked || i.expires < now ? " closed" : "")}>
              <div class="words"><b>{i.label || "Unnamed invitation"}</b><small>{state(i)} · made {date(i.created)}</small></div>
              {i.invite && (
                <span class="actions">
                  <button class="pill secondary small" onClick={() => share(inviteLink(i.invite!), i.id)}>{copied === i.id ? "Copied" : "Copy Link"}</button>
                  <button class="pill secondary small danger" onClick={async () => { await admin.withdraw(i.id).catch(() => {}); load(); }}>Withdraw</button>
                </span>
              )}
            </div>
          ))}
        </section>
      ) : <p class="quiet pad">{list ? "No invitations yet." : ""}</p>}
    </div>
  );
}

// MARK: Add-ons offered to people who join

function AddonsView() {
  const [mine, setMine] = useState<Addon[] | null>(null);
  const [chosen, setChosen] = useState<Set<string>>(new Set());
  const [saved, setSaved] = useState<"" | "saving" | "saved">("");
  useEffect(() => {
    Promise.all([freshAddons(), admin.starter()]).then(([list, starter]) => {
      setMine(list);
      setChosen(new Set(starter.addons.map((a) => a.transportUrl)));
    }, () => setMine([]));
  }, []);
  if (!mine) return <div class="pad"><div class="spinner" /></div>;
  const flip = (url: string) => { const next = new Set(chosen); if (next.has(url)) next.delete(url); else next.add(url); setChosen(next); setSaved(""); };
  const save = async () => {
    setSaved("saving");
    await admin.setStarter(mine.filter((a) => chosen.has(a.transportUrl))).catch(() => {});
    setSaved("saved");
  };
  // Stremio's own add-ons (Cinemeta and the like) every account has already.
  const offerable = mine.filter((a) => !/^https:\/\/(v3-cinemeta|opensubtitles-v3|watchhub|caching)\.strem\.io/.test(a.transportUrl));
  return (
    <div class="admin-body">
      <p class="quiet note top">Choose add-ons from your Stremio account to offer people who join. The first time they open Encore, they can add them in one tap; they can say no, and remove them later in any Stremio app.</p>
      <p class="quiet note warn">An add-on's link can include the accounts it uses, like a debrid key. People who add it use those accounts, so offer only what you mean to share.</p>
      <section class="group">
        {offerable.map((a) => (
          <label key={a.transportUrl} class="setting check-row">
            <input type="checkbox" checked={chosen.has(a.transportUrl)} onChange={() => flip(a.transportUrl)} />
            <div class="words"><b>{a.manifest.name}</b><small>{(a.manifest as { description?: string }).description?.slice(0, 120) || new URL(a.transportUrl).host}</small></div>
          </label>
        ))}
        {!offerable.length && <p class="quiet pad">Your Stremio account has no add-ons of its own to offer.</p>}
      </section>
      <div class="actions save-row">
        <button class="pill primary" disabled={saved === "saving"} onClick={save}>{saved === "saved" ? <><Check />Saved</> : saved === "saving" ? "Saving…" : `Offer ${chosen.size || "No"} Add-on${chosen.size === 1 ? "" : "s"}`}</button>
      </div>
    </div>
  );
}
