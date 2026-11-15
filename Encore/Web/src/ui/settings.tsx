// Settings: who's watching, how things play, this server (and who else may use it), the account.
import { useEffect, useState } from "preact/hooks";
import { auth, prefs, profileId, relayToken, setPref, type Prefs } from "../lib/core";
import { relayInvite, relayPeople, relayRemove, type RelayPerson } from "../lib/api";
import { profile, profiles } from "../lib/library";
import { Avatar } from "./shared";
import { QR } from "./gates";
import { Check, Close, Exit, Swap } from "./icons";

const LANGUAGES: [string, string][] = [
  ["en", "English"], ["es", "Spanish"], ["fr", "French"], ["de", "German"], ["it", "Italian"], ["pt", "Portuguese"],
  ["nl", "Dutch"], ["sv", "Swedish"], ["no", "Norwegian"], ["da", "Danish"], ["fi", "Finnish"], ["pl", "Polish"],
  ["ru", "Russian"], ["uk", "Ukrainian"], ["tr", "Turkish"], ["ar", "Arabic"], ["he", "Hebrew"], ["hi", "Hindi"],
  ["ja", "Japanese"], ["ko", "Korean"], ["zh", "Chinese"], ["vi", "Vietnamese"], ["th", "Thai"], ["id", "Indonesian"],
];
export const languageName = (code: string) => LANGUAGES.find(([c]) => c === code)?.[1] || code.toUpperCase();

function Toggle({ on, label, onChange }: { on: boolean; label: string; onChange: (v: boolean) => void }) {
  return <button role="switch" aria-checked={on} aria-label={label} class={"switch" + (on ? " on" : "")} onClick={() => onChange(!on)}><i /></button>;
}

function Row(props: { title: string; detail?: string; children?: preact.ComponentChildren }) {
  return (
    <div class="setting">
      <div class="words"><b>{props.title}</b>{props.detail && <small>{props.detail}</small>}</div>
      {props.children}
    </div>
  );
}

function Choice<K extends keyof Prefs>({ pref, options, label }: { pref: K; options: [Prefs[K], string][]; label: string }) {
  return (
    <div class="segmented" role="radiogroup" aria-label={label}>
      {options.map(([value, name]) => (
        <button key={String(value)} role="radio" aria-checked={prefs.value[pref] === value} class={prefs.value[pref] === value ? "on" : ""} onClick={() => setPref(pref, value)}>{name}</button>
      ))}
    </div>
  );
}

function Invite() {
  const [invite, setInvite] = useState<{ link: string; expiresAt: number } | null>(null);
  const [busy, setBusy] = useState(false);
  const [copied, setCopied] = useState(false);
  const [error, setError] = useState("");
  const make = async () => {
    setBusy(true); setError("");
    try { setInvite(await relayInvite()); } catch { setError("Couldn't make an invitation. Check that this server is reachable."); }
    setBusy(false);
  };
  const share = async () => {
    const nav = navigator as Navigator & { share?: (d: ShareData) => Promise<void> };
    if (nav.share && matchMedia("(pointer: coarse)").matches) { nav.share({ title: "Join me on Encore", url: invite!.link }).catch(() => {}); return; }
    try { await navigator.clipboard.writeText(invite!.link); setCopied(true); setTimeout(() => setCopied(false), 2000); } catch { setError("Copy the link by hand: select it and copy."); }
  };
  if (!invite) {
    return (
      <Row title="Invite Someone" detail="Lets one more Stremio account watch with this server. Everyone signs in with their own account and keeps their own library.">
        <button class="pill secondary small" disabled={busy} onClick={make}>{busy ? "Making…" : "Create Link"}</button>
        {error && <p class="error">{error}</p>}
      </Row>
    );
  }
  return (
    <div class="setting invite">
      <div class="qr small"><QR text={invite.link} label="QR code with the invitation link" /></div>
      <div class="words">
        <b>Invitation ready</b>
        <small>Works once, for one account, until {new Date(invite.expiresAt * 1000).toLocaleDateString(undefined, { month: "long", day: "numeric" })}. Send it, or have them scan the code.</small>
        <input class="field link-field" readOnly value={invite.link} onFocus={(e) => (e.target as HTMLInputElement).select()} aria-label="Invitation link" />
        <div class="actions">
          <button class="pill primary small" onClick={share}>{copied ? <><Check />Copied</> : "Share Link"}</button>
          <button class="pill secondary small" onClick={() => setInvite(null)}>Done</button>
        </div>
        {error && <p class="error">{error}</p>}
      </div>
    </div>
  );
}

function People() {
  const [people, setPeople] = useState<RelayPerson[] | null>(null);
  const [confirm, setConfirm] = useState<string | null>(null);
  useEffect(() => { relayPeople().then(setPeople, () => setPeople([])); }, []);
  if (!people || people.length < 2) return null;
  const remove = async (email: string) => {
    await relayRemove(email).catch(() => {});
    setPeople((list) => (list || []).filter((p) => p.email !== email));
    setConfirm(null);
  };
  return (
    <>
      {people.map((p) => (
        <Row key={p.email} title={p.email + (p.you ? " (you)" : "")} detail={p.admin ? "Manages this server" : p.invitedBy ? `Invited by ${p.invitedBy}` : "Invited"}>
          {!p.you && (confirm === p.email
            ? <span class="actions"><button class="pill small danger" onClick={() => remove(p.email)}>Remove</button><button class="pill secondary small" onClick={() => setConfirm(null)}>Cancel</button></span>
            : <button class="icon" aria-label={`Remove ${p.email}`} onClick={() => setConfirm(p.email)}><Close /></button>)}
        </Row>
      ))}
    </>
  );
}

export function SettingsPage() {
  const me = profile.value!;
  const languages: [string, string][] = [["", "Automatic"], ...LANGUAGES];
  return (
    <div class="page padded settings">
      <h1 class="heading">Settings</h1>

      <section class="group">
        <div class="setting who-row">
          <Avatar profile={me} />
          <div class="words"><b>{me.name}</b><small>{auth.value?.email}</small></div>
          {profiles.value.length > 1 && <button class="pill secondary small" onClick={() => { profileId.value = null; }}><Swap />Switch Profile</button>}
        </div>
      </section>

      <h2 class="group-title">Playback</h2>
      <section class="group">
        <Row title="Audio Language" detail="Chosen when a source has more than one.">
          <select class="select" aria-label="Audio language" value={prefs.value.audioLanguage} onChange={(e) => setPref("audioLanguage", (e.target as HTMLSelectElement).value)}>
            {languages.map(([c, n]) => <option key={c} value={c}>{n}</option>)}
          </select>
        </Row>
        <Row title="Subtitles" detail="Turned on by themselves when available in this language.">
          <select class="select" aria-label="Subtitles" value={prefs.value.subtitles} onChange={(e) => setPref("subtitles", (e.target as HTMLSelectElement).value)}>
            <option value="off">Off</option>
            {LANGUAGES.map(([c, n]) => <option key={c} value={c}>{n}</option>)}
          </select>
        </Row>
        <Row title="Autoplay Next Episode" detail="Counts down at the credits, then plays the next episode.">
          <Toggle label="Autoplay next episode" on={prefs.value.autoplayNext} onChange={(v) => setPref("autoplayNext", v)} />
        </Row>
        <Row title="Skip Intros and Recaps" detail="Skips them by themselves where Encore knows where they are.">
          <Toggle label="Skip intros and recaps" on={prefs.value.skipIntros} onChange={(v) => setPref("skipIntros", v)} />
        </Row>
        <Row title="Quality" detail="Lower starts faster and uses less data, for weak or metered connections.">
          <Choice pref="quality" label="Quality" options={[["best", "Best"], ["1080p", "1080p"], ["720p", "720p"]]} />
        </Row>
      </section>

      <h2 class="group-title">This Server</h2>
      <section class="group">
        <Row title={location.host} detail={relayToken.value ? `Connected${relayToken.value.admin ? " · you manage this server" : ""}` : "Not connected yet"} />
        <Invite />
        {relayToken.value?.admin && <People />}
      </section>

      <h2 class="group-title">Account</h2>
      <section class="group">
        <Row title="Stremio Account" detail={auth.value?.email}>
          <button class="pill secondary small danger" onClick={() => { auth.value = null; }}><Exit />Sign Out</button>
        </Row>
      </section>

      <p class="fine">Encore Web · {__BUILD__}</p>
    </div>
  );
}
