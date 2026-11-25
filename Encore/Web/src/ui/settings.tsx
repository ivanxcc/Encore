// Settings: who's watching, how things play, this server, the account. (Managing the server is on
// the Admin page, for its owner.)
import { auth, go, prefs, profileId, relayToken, setPref, type Prefs } from "../lib/core";
import { profile, profiles } from "../lib/library";
import { Avatar } from "./shared";
import { LANGUAGES } from "../lib/lang";
import { Exit, Swap } from "./icons";

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

export function SettingsPage() {
  const me = profile.value!;
  const languages: [string, string][] = [["", "Device Language"], ...LANGUAGES];
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
        <Row title="Audio Language" detail="Sources in this language come first, and it's the track chosen when a source has several.">
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
        <Row title="Prepare While Browsing" detail="Readies a few seconds of a title when its page has been open a moment, so Play starts at once. Only sources that are ready now.">
          <Toggle label="Prepare while browsing" on={prefs.value.prepareAhead} onChange={(v) => setPref("prepareAhead", v)} />
        </Row>
        <Row title="Quality" detail="Lower starts faster and uses less data, for weak or metered connections.">
          <Choice pref="quality" label="Quality" options={[["best", "Best"], ["1080p", "1080p"], ["720p", "720p"]]} />
        </Row>
      </section>

      <h2 class="group-title">This Server</h2>
      <section class="group">
        <Row title={location.host} detail={relayToken.value ? `Connected${relayToken.value.admin ? " · you manage this server" : ""}` : "Not connected yet"} />
        {relayToken.value?.admin
          ? <Row title="Admin" detail="Who's watching, the people who use this server, invitations, and add-ons for new people."><button class="pill secondary small" onClick={() => go("/admin")}>Open</button></Row>
          : <Row title="Privacy" detail="The owner of this server can see what's played on it, on which profile and device, and how well it played. It stays on this server." />}
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
