// What stands between opening the site and Home: signing in, linking this relay, choosing who's watching.
import { useEffect, useRef, useState } from "preact/hooks";
import qrcode from "qrcode-generator";
import { auth, profileId } from "../lib/core";
import { encore, NeedsCode, relayAuth, signIn, type Profile } from "../lib/api";
import { pinMatches, profiles } from "../lib/library";
import { Avatar } from "./shared";
import { Lock } from "./icons";

function QR({ text }: { text: string }) {
  const qr = qrcode(0, "M");
  qr.addData(text);
  qr.make();
  const n = qr.getModuleCount();
  let d = "";
  for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) d += `M${c} ${r}h1v1h-1z`;
  return <svg viewBox={`0 0 ${n} ${n}`} shape-rendering="crispEdges" role="img" aria-label="QR code to sign in with your iPhone"><path d={d} fill="#000" /></svg>;
}

export function SignIn() {
  const [code, setCode] = useState<string | null>(null);
  const [useEmail, setUseEmail] = useState(!encore.available());
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const email = useRef<HTMLInputElement>(null), password = useRef<HTMLInputElement>(null);

  // Show a code; sign in the moment a phone approves it; show a fresh one when it runs out.
  useEffect(() => {
    if (useEmail || !encore.available()) return;
    let live = true;
    (async () => {
      while (live) {
        try {
          const start = await encore.pairStart();
          if (!live) return;
          setCode(start.code);
          while (live && Date.now() / 1000 < start.expiresAt - 5) {
            await new Promise((r) => setTimeout(r, 2000));
            const done = await encore.pairPoll(start.pollToken);
            if (done && live) { auth.value = { key: done.authKey, email: done.email }; return; }
          }
        } catch {
          await new Promise((r) => setTimeout(r, 4000));
        }
      }
    })();
    return () => { live = false; };
  }, [useEmail]);

  const submit = async (e: Event) => {
    e.preventDefault();
    setError(""); setBusy(true);
    try {
      await signIn(email.current!.value.trim(), password.current!.value);
    } catch (err) {
      setError((err as Error).message || "That didn't work. Check the email and password.");
    } finally { setBusy(false); }
  };

  return (
    <div class="stage">
      {useEmail ? (
        <div style={{ width: "min(24rem, 100%)" }}>
          <h1 style={{ fontSize: "2.2rem", fontWeight: 800, letterSpacing: "-0.03em" }}>Sign In to Encore</h1>
          <p class="quiet" style={{ marginTop: "0.6rem" }}>With the Stremio account you use in Encore. Your password goes only to Stremio.</p>
          <form class="form" onSubmit={submit}>
            <input ref={email} class="field" type="email" placeholder="Email" autocomplete="username" autocapitalize="off" spellcheck={false} required />
            <input ref={password} class="field" type="password" placeholder="Password" autocomplete="current-password" required />
            {error && <p class="error">{error}</p>}
            <button class="pill primary" disabled={busy}>{busy ? "Signing In…" : "Sign In"}</button>
            {encore.available() && <button type="button" class="link" onClick={() => setUseEmail(false)}>Use a QR code instead</button>}
          </form>
        </div>
      ) : (
        <div class="signin">
          <div>
            <h1>Sign In to Encore</h1>
            <div class="steps">
              <div><i>1</i><span>Scan the code with your iPhone's camera.</span></div>
              <div><i>2</i><span>Tap Open Encore, check the account, and approve.</span></div>
            </div>
            <p class="quiet">Or in Encore on your iPhone, go to Settings › Encore Cloud › Sign In an Apple TV and enter:</p>
            <p class="code" style={{ margin: "0.7rem 0 1.6rem" }}>{code || "····-····"}</p>
            <button class="pill secondary" onClick={() => setUseEmail(true)}>Use Email and Password</button>
          </div>
          <div class="qr">{code && <QR text={encore.pairPage(code)} />}</div>
        </div>
      )}
    </div>
  );
}

/** One time per account: the relay's code, which the server's installer printed. */
export function LinkRelay({ onLinked }: { onLinked: () => void }) {
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const code = useRef<HTMLInputElement>(null);
  const submit = async (e: Event) => {
    e.preventDefault();
    setError(""); setBusy(true);
    try {
      await relayAuth(code.current!.value);
      onLinked();
    } catch (err) {
      setError(err instanceof NeedsCode ? err.message || "That code isn't right." : (err as Error).message);
    } finally { setBusy(false); }
  };
  return (
    <div class="stage">
      <div style={{ width: "min(26rem, 100%)" }}>
        <h1 style={{ fontSize: "2.2rem", fontWeight: 800, letterSpacing: "-0.03em" }}>Link This Server</h1>
        <p class="quiet" style={{ marginTop: "0.6rem" }}>Enter the code your Encore server's installer printed. It's asked once per account; your other devices won't need it.</p>
        <form class="form" onSubmit={submit}>
          <input ref={code} class="field code" style={{ fontSize: "1.5rem", height: "3.8rem", textAlign: "center" }} placeholder="ABCD-EFGH" autocapitalize="characters" autocomplete="off" spellcheck={false} required />
          {error && <p class="error">{error}</p>}
          <button class="pill primary" disabled={busy}>{busy ? "Linking…" : "Continue"}</button>
          <button type="button" class="link" onClick={() => { auth.value = null; }}>Sign in with a different account</button>
        </form>
      </div>
    </div>
  );
}

export function WhoIsWatching() {
  const [locked, setLocked] = useState<Profile | null>(null);
  const [digits, setDigits] = useState("");
  const [wrong, setWrong] = useState(false);

  const press = async (key: string) => {
    if (!locked) return;
    setWrong(false);
    if (key === "⌫") return setDigits((d) => d.slice(0, -1));
    const next = (digits + key).slice(0, 4);
    setDigits(next);
    if (next.length === 4) {
      if (await pinMatches(locked, next)) profileId.value = locked.id;
      else { setWrong(true); setDigits(""); }
    }
  };
  useEffect(() => {
    if (!locked) return;
    const onKey = (e: KeyboardEvent) => {
      if (/^\d$/.test(e.key)) press(e.key);
      else if (e.key === "Backspace") press("⌫");
      else if (e.key === "Escape") { setLocked(null); setDigits(""); }
    };
    addEventListener("keydown", onKey);
    return () => removeEventListener("keydown", onKey);
  });

  if (locked) {
    return (
      <div class="stage">
        <div class="who pin">
          <div class="avatar-wrap" style={{ fontSize: "2rem" }}><span style={{ display: "block", width: "5.5rem", height: "5.5rem" }}><AvatarBig profile={locked} /></span></div>
          <h1 style={{ fontSize: "1.5rem" }}>Enter PIN for {locked.name}</h1>
          <div class={"cells" + (wrong ? " wrong" : "")}>{[0, 1, 2, 3].map((i) => <i key={i} class={i < digits.length ? "on" : ""} />)}</div>
          <div class="pad">
            {["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"].map((k) => k ? <button key={k} onClick={() => press(k)} aria-label={k === "⌫" ? "Delete" : k}>{k}</button> : <span key="gap" />)}
          </div>
          <button class="link" onClick={() => { setLocked(null); setDigits(""); }}>Cancel</button>
        </div>
      </div>
    );
  }
  return (
    <div class="stage">
      <div class="who">
        <h1>Who's watching?</h1>
        <div class="people">
          {profiles.value.map((p) => (
            <button key={p.id} onClick={() => (p.pinHash ? setLocked(p) : (profileId.value = p.id))}>
              <span style={{ position: "relative" }}>
                <Avatar profile={p} />
                {p.pinHash && <span class="lock"><Lock /></span>}
              </span>
              {p.name}
            </button>
          ))}
        </div>
      </div>
    </div>
  );
}

function AvatarBig({ profile }: { profile: Profile }) {
  return <span style={{ display: "contents" }} class="big-avatar"><Avatar profile={profile} /></span>;
}
