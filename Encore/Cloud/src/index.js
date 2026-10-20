// Encore Cloud: syncs Encore households (profiles, their watch history, settings) across devices.
//
// Identity is the Stremio account. Every request carries `Authorization: Stremio <authKey>`; the Worker
// confirms it with api.strem.io once and caches the result (keyed by a SHA-256 of the key, never the key).
// A household document belongs to exactly one Stremio user and only that user's sessions can read or
// write it, so households can never see each other.
//
// Endpoints (all JSON):
//   GET    /v1/household                      -> { version, doc, updatedAt } | 404
//   PUT    /v1/household   { baseVersion, doc } -> { version } | 409 { version, doc }
//   DELETE /v1/household                      -> erase this account's cloud data
//   GET    /v1/directory                      -> { version, doc } | 404   (households this account manages)
//   PUT    /v1/directory   { baseVersion, doc } -> { version } | 409 { version, doc }
//   POST   /v1/share       { name }           -> { code, expiresAt }   (owner shares the household)
//   POST   /v1/share/redeem { code }          -> { ownerId, email, authKey, name }  (once)
//   POST   /v1/pair/start                     -> { code, pollToken, expiresAt }     (a TV, no auth)
//   POST   /v1/pair/approve { code }          -> { ok }        (a signed-in phone approves the TV)
//   GET    /v1/pair/poll?token=…              -> 202 waiting | 200 { authKey, email } (once)
//   GET    /v1/title?imdb=…&type=…            -> cast, original artwork (TMDB; see tmdb.js)
//   GET    /v1/trending                       -> this week's trending titles (TMDB)
//   GET    /v1/season?tmdb=…&season=N         -> each episode's runtime in minutes (TMDB)

import { tmdbRoute } from "./tmdb.js";
import { skipRoute } from "./skip.js";

const STREMIO_API = "https://api.strem.io/api/";
const SESSION_TTL = 6 * 60 * 60;         // seconds a verified Stremio session is trusted without re-checking
const CODE_TTL = 15 * 60;                // seconds a share or pairing code stays valid
const MAX_DOC_BYTES = 1_500_000;          // D1 rows top out around 2 MB
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O or 1/I

export default {
  async fetch(request, env, ctx) {
    // Wrap fetch: the Workers runtime throws "Illegal invocation" when fetch is called as a method of
    // another object (deps.fetchStremio(...)), which made every signed-in request fail with a 500.
    return handle(request, env, {
      fetchStremio: (url, init) => fetch(url, init),
      fetchTMDB: (url, init) => fetch(url, init),
      cache: typeof caches === "undefined" ? null : caches.default,
      now: () => Math.floor(Date.now() / 1000),
    });
  },
};

/** The request handler, with its outside world injected so tests can run it without the network. */
export async function handle(request, env, deps) {
  const url = new URL(request.url);
  const route = `${request.method} ${url.pathname}`;
  try {
    await env.DB.prepare("DELETE FROM codes WHERE expires_at < ?").bind(deps.now()).run();
    // The page a TV's QR code opens on the phone: it hands the code to the Encore app.
    const pairPage = url.pathname.match(/^\/pair\/([A-Za-z0-9-]{8,9})$/);
    if (request.method === "GET" && pairPage) return pairLanding(normalizeCode(pairPage[1]));
    switch (route) {
      case "GET /":
      case "GET /v1/health":
        return json({ ok: true, service: "encore-cloud" });
      case "POST /v1/pair/start":
        return pairStart(env, deps);
      case "GET /v1/pair/poll":
        return pairPoll(env, deps, url.searchParams.get("token"));
      case "GET /v1/skip": {
        const result = await skipRoute(url, deps);
        return json(result.body, result.status, result.status === 200 ? 3600 : 0);
      }
      case "GET /v1/title":
      case "GET /v1/season":
      case "GET /v1/trending": {
        const result = await tmdbRoute(route, url, env, deps);
        if (!result) return json({ error: "TMDB is not set up" }, 404);
        return json(result.body, result.status, result.status === 200 ? 3600 : 0);
      }
    }
    const user = await authenticate(request, env, deps);
    if (!user) return json({ error: "Sign in to Stremio again." }, 401);
    switch (route) {
      case "GET /v1/household": return getDocument(env, user, HOUSEHOLDS);
      case "PUT /v1/household": return putDocument(request, env, deps, user, HOUSEHOLDS);
      case "GET /v1/directory": return getDocument(env, user, DIRECTORIES);
      case "PUT /v1/directory": return putDocument(request, env, deps, user, DIRECTORIES);
      case "DELETE /v1/household": return deleteHousehold(env, user);
      case "POST /v1/share": return shareCreate(request, env, deps, user);
      case "POST /v1/share/redeem": return shareRedeem(request, env, deps);
      case "POST /v1/pair/approve": return pairApprove(request, env, deps, user);
      default: return json({ error: "Not found" }, 404);
    }
  } catch (error) {
    return json({ error: "Server error", detail: String(error && error.message || error) }, 500);
  }
}

// MARK: Auth

async function authenticate(request, env, deps) {
  const header = request.headers.get("authorization") || "";
  const match = header.match(/^Stremio\s+(.+)$/i);
  if (!match) return null;
  const authKey = match[1].trim();
  const tokenHash = await sha256(authKey);
  const cached = await env.DB.prepare("SELECT user_id, email FROM sessions WHERE token_hash = ? AND expires_at > ?")
    .bind(tokenHash, deps.now()).first();
  if (cached) return { id: cached.user_id, email: cached.email, authKey };
  const response = await deps.fetchStremio(STREMIO_API + "getUser", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ type: "GetUser", authKey }),
  });
  if (!response.ok) return null;
  const body = await response.json().catch(() => null);
  const user = body && body.result;
  if (!user || !user._id) return null;
  await env.DB.prepare("INSERT OR REPLACE INTO sessions (token_hash, user_id, email, expires_at) VALUES (?, ?, ?, ?)")
    .bind(tokenHash, user._id, user.email || null, deps.now() + SESSION_TTL).run();
  return { id: user._id, email: user.email || null, authKey };
}

// MARK: Versioned documents (a household, or an account's directory of households)

const HOUSEHOLDS = { table: "households", hasEmail: true, missing: "No household yet" };
const DIRECTORIES = { table: "directories", hasEmail: false, missing: "No directory yet" };

async function getDocument(env, user, kind) {
  const row = await env.DB.prepare(`SELECT doc, version, updated_at FROM ${kind.table} WHERE owner_id = ?`).bind(user.id).first();
  if (!row) return json({ error: kind.missing }, 404);
  return json({ version: row.version, doc: JSON.parse(row.doc), updatedAt: row.updated_at });
}

async function putDocument(request, env, deps, user, kind) {
  const body = await readJSON(request);
  if (!body || typeof body.doc !== "object" || body.doc === null || !Number.isInteger(body.baseVersion)) {
    return json({ error: "Expected { baseVersion, doc }" }, 400);
  }
  const doc = JSON.stringify(body.doc);
  if (doc.length > MAX_DOC_BYTES) return json({ error: "Too large to sync" }, 413);
  const now = deps.now();
  const select = `SELECT doc, version FROM ${kind.table} WHERE owner_id = ?`;
  const current = await env.DB.prepare(select).bind(user.id).first();
  const currentVersion = current ? current.version : 0;
  if (body.baseVersion !== currentVersion) {
    return json({ version: currentVersion, doc: current ? JSON.parse(current.doc) : null }, 409);
  }
  const next = currentVersion + 1;
  // The WHERE clause makes the write atomic against a concurrent writer that read the same version.
  let statement;
  if (current) {
    statement = kind.hasEmail
      ? env.DB.prepare(`UPDATE ${kind.table} SET doc = ?, version = ?, updated_at = ?, owner_email = ? WHERE owner_id = ? AND version = ?`)
          .bind(doc, next, now, user.email, user.id, currentVersion)
      : env.DB.prepare(`UPDATE ${kind.table} SET doc = ?, version = ?, updated_at = ? WHERE owner_id = ? AND version = ?`)
          .bind(doc, next, now, user.id, currentVersion);
  } else {
    statement = kind.hasEmail
      ? env.DB.prepare(`INSERT OR IGNORE INTO ${kind.table} (owner_id, owner_email, doc, version, updated_at) VALUES (?, ?, ?, ?, ?)`)
          .bind(user.id, user.email, doc, next, now)
      : env.DB.prepare(`INSERT OR IGNORE INTO ${kind.table} (owner_id, doc, version, updated_at) VALUES (?, ?, ?, ?)`)
          .bind(user.id, doc, next, now);
  }
  const result = await statement.run();
  if (!result.meta || result.meta.changes !== 1) {
    const latest = await env.DB.prepare(select).bind(user.id).first();
    return json({ version: latest ? latest.version : 0, doc: latest ? JSON.parse(latest.doc) : null }, 409);
  }
  return json({ version: next });
}

async function deleteHousehold(env, user) {
  await env.DB.prepare("DELETE FROM households WHERE owner_id = ?").bind(user.id).run();
  await env.DB.prepare("DELETE FROM directories WHERE owner_id = ?").bind(user.id).run();
  await env.DB.prepare("DELETE FROM codes WHERE user_id = ?").bind(user.id).run();
  return json({ ok: true });
}

// MARK: Sharing a household ("let Ivan manage mine")

async function shareCreate(request, env, deps, user) {
  const body = (await readJSON(request)) || {};
  const code = randomCode();
  const expiresAt = deps.now() + CODE_TTL;
  await env.DB.prepare("INSERT INTO codes (code, kind, user_id, email, auth_key, name, expires_at) VALUES (?, 'share', ?, ?, ?, ?, ?)")
    .bind(code, user.id, user.email, user.authKey, String(body.name || "").slice(0, 60) || null, expiresAt).run();
  return json({ code: formatCode(code), expiresAt });
}

async function shareRedeem(request, env, deps) {
  const body = (await readJSON(request)) || {};
  const code = normalizeCode(body.code);
  const row = await env.DB.prepare("SELECT * FROM codes WHERE code = ? AND kind = 'share' AND expires_at > ?").bind(code, deps.now()).first();
  if (!row) return json({ error: "That code is invalid or has expired." }, 404);
  await env.DB.prepare("DELETE FROM codes WHERE code = ?").bind(code).run();   // one use only
  return json({ ownerId: row.user_id, email: row.email, authKey: row.auth_key, name: row.name });
}

// MARK: TV sign-in from a phone

async function pairStart(env, deps) {
  const code = randomCode();
  const pollToken = randomToken();
  const expiresAt = deps.now() + CODE_TTL;
  await env.DB.prepare("INSERT INTO codes (code, kind, poll_token, expires_at) VALUES (?, 'pair', ?, ?)")
    .bind(code, pollToken, expiresAt).run();
  return json({ code: formatCode(code), pollToken, expiresAt });
}

async function pairApprove(request, env, deps, user) {
  const body = (await readJSON(request)) || {};
  const code = normalizeCode(body.code);
  const result = await env.DB.prepare("UPDATE codes SET user_id = ?, email = ?, auth_key = ? WHERE code = ? AND kind = 'pair' AND auth_key IS NULL AND expires_at > ?")
    .bind(user.id, user.email, user.authKey, code, deps.now()).run();
  if (!result.meta || result.meta.changes !== 1) return json({ error: "That code is invalid or has expired." }, 404);
  return json({ ok: true });
}

async function pairPoll(env, deps, token) {
  if (!token) return json({ error: "Missing token" }, 400);
  const row = await env.DB.prepare("SELECT * FROM codes WHERE poll_token = ? AND kind = 'pair' AND expires_at > ?").bind(token, deps.now()).first();
  if (!row) return json({ error: "Expired" }, 410);
  if (!row.auth_key) return json({ waiting: true }, 202);
  await env.DB.prepare("DELETE FROM codes WHERE code = ?").bind(row.code).run();   // hand the session over once
  return json({ authKey: row.auth_key, email: row.email });
}

// MARK: Helpers

function json(body, status = 200, maxAge = 0) {
  const cache = maxAge > 0 ? `public, max-age=${maxAge}` : "no-store";
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": cache } });
}

async function readJSON(request) {
  try { return await request.json(); } catch { return null; }
}

async function sha256(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function randomCode() {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  return [...bytes].map((b) => CODE_ALPHABET[b % CODE_ALPHABET.length]).join("");
}

function randomToken() {
  const bytes = crypto.getRandomValues(new Uint8Array(24));
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function formatCode(code) { return code.slice(0, 4) + "-" + code.slice(4); }

export function normalizeCode(raw) {
  // "abcd efgh", "ABCD-EFGH" and "abcdefgh" are the same code.
  return String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "").slice(0, 8);
}

// MARK: QR sign-in landing page

/** Opens Encore with the code (encore://pair?code=…); if Encore is not installed, says how to finish. */
export function pairLanding(code) {
  const display = formatCode(code);
  const deepLink = `encore://pair?code=${code}`;
  const html = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="dark">
<title>Sign in to Encore</title>
<style>
  :root{color-scheme:dark}
  body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#000;color:#fff;
       font:17px/1.45 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;text-align:center}
  main{padding:32px 24px;max-width:420px}
  h1{font-size:28px;margin:0 0 8px}
  p{color:rgba(255,255,255,.7);margin:0 0 24px}
  a.button{display:block;background:#fff;color:#000;text-decoration:none;font-weight:600;padding:16px;border-radius:999px;margin-bottom:24px}
  .code{font:700 34px/1 ui-monospace,"SF Mono",monospace;letter-spacing:.12em;padding:18px;border-radius:18px;background:rgba(255,255,255,.1)}
  small{display:block;margin-top:16px;color:rgba(255,255,255,.5)}
</style></head><body><main>
<h1>Sign in your TV</h1>
<p>Open Encore on this iPhone to approve the sign-in.</p>
<a class="button" href="${deepLink}">Open Encore</a>
<div class="code">${display}</div>
<small>Or in Encore, go to Settings › Encore Cloud › Sign In an Apple TV and enter this code. It expires in 15 minutes.</small>
</main><script>setTimeout(function(){location.href=${JSON.stringify(deepLink)}},150)</script></body></html>`;
  return new Response(html, { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } });
}
