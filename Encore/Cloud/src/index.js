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
//   POST   /v1/share       { name }           -> { code, expiresAt }   (owner shares the household)
//   POST   /v1/share/redeem { code }          -> { ownerId, email, authKey, name }  (once)
//   POST   /v1/pair/start                     -> { code, pollToken, expiresAt }     (a TV, no auth)
//   POST   /v1/pair/approve { code }          -> { ok }        (a signed-in phone approves the TV)
//   GET    /v1/pair/poll?token=…              -> 202 waiting | 200 { authKey, email } (once)

const STREMIO_API = "https://api.strem.io/api/";
const SESSION_TTL = 6 * 60 * 60;         // seconds a verified Stremio session is trusted without re-checking
const CODE_TTL = 15 * 60;                // seconds a share or pairing code stays valid
const MAX_DOC_BYTES = 1_500_000;          // D1 rows top out around 2 MB
const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O or 1/I

export default {
  async fetch(request, env, ctx) {
    return handle(request, env, { fetchStremio: fetch, now: () => Math.floor(Date.now() / 1000) });
  },
};

/** The request handler, with its outside world injected so tests can run it without the network. */
export async function handle(request, env, deps) {
  const url = new URL(request.url);
  const route = `${request.method} ${url.pathname}`;
  try {
    await env.DB.prepare("DELETE FROM codes WHERE expires_at < ?").bind(deps.now()).run();
    switch (route) {
      case "GET /":
      case "GET /v1/health":
        return json({ ok: true, service: "encore-cloud" });
      case "POST /v1/pair/start":
        return pairStart(env, deps);
      case "GET /v1/pair/poll":
        return pairPoll(env, deps, url.searchParams.get("token"));
    }
    const user = await authenticate(request, env, deps);
    if (!user) return json({ error: "Sign in to Stremio again." }, 401);
    switch (route) {
      case "GET /v1/household": return getHousehold(env, user);
      case "PUT /v1/household": return putHousehold(request, env, deps, user);
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

// MARK: Household documents

async function getHousehold(env, user) {
  const row = await env.DB.prepare("SELECT doc, version, updated_at FROM households WHERE owner_id = ?").bind(user.id).first();
  if (!row) return json({ error: "No household yet" }, 404);
  return json({ version: row.version, doc: JSON.parse(row.doc), updatedAt: row.updated_at });
}

async function putHousehold(request, env, deps, user) {
  const body = await readJSON(request);
  if (!body || typeof body.doc !== "object" || body.doc === null || !Number.isInteger(body.baseVersion)) {
    return json({ error: "Expected { baseVersion, doc }" }, 400);
  }
  const doc = JSON.stringify(body.doc);
  if (doc.length > MAX_DOC_BYTES) return json({ error: "Household is too large to sync" }, 413);
  const now = deps.now();
  const current = await env.DB.prepare("SELECT doc, version FROM households WHERE owner_id = ?").bind(user.id).first();
  const currentVersion = current ? current.version : 0;
  if (body.baseVersion !== currentVersion) {
    return json({ version: currentVersion, doc: current ? JSON.parse(current.doc) : null }, 409);
  }
  const next = currentVersion + 1;
  // The WHERE clause makes the write atomic against a concurrent writer that read the same version.
  const result = current
    ? await env.DB.prepare("UPDATE households SET doc = ?, version = ?, updated_at = ?, owner_email = ? WHERE owner_id = ? AND version = ?")
        .bind(doc, next, now, user.email, user.id, currentVersion).run()
    : await env.DB.prepare("INSERT OR IGNORE INTO households (owner_id, owner_email, doc, version, updated_at) VALUES (?, ?, ?, ?, ?)")
        .bind(user.id, user.email, doc, next, now).run();
  if (!result.meta || result.meta.changes !== 1) {
    const latest = await env.DB.prepare("SELECT doc, version FROM households WHERE owner_id = ?").bind(user.id).first();
    return json({ version: latest ? latest.version : 0, doc: latest ? JSON.parse(latest.doc) : null }, 409);
  }
  return json({ version: next });
}

async function deleteHousehold(env, user) {
  await env.DB.prepare("DELETE FROM households WHERE owner_id = ?").bind(user.id).run();
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

function json(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } });
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
