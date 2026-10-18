-- Encore Cloud schema. One row per household, keyed by the Stremio user that owns it.
CREATE TABLE IF NOT EXISTS households (
  owner_id   TEXT PRIMARY KEY,
  owner_email TEXT,
  doc        TEXT NOT NULL,          -- the household document (JSON, written by the app)
  version    INTEGER NOT NULL,       -- optimistic concurrency: every write must name the version it read
  updated_at INTEGER NOT NULL
);

-- Cached Stremio session checks, so every request does not round-trip to api.strem.io.
CREATE TABLE IF NOT EXISTS sessions (
  token_hash TEXT PRIMARY KEY,       -- SHA-256 of the Stremio authKey; the key itself is never stored here
  user_id    TEXT NOT NULL,
  email      TEXT,
  expires_at INTEGER NOT NULL
);

-- One-time share codes ("let Ivan manage my household") and TV sign-in codes. Short-lived.
CREATE TABLE IF NOT EXISTS codes (
  code       TEXT PRIMARY KEY,
  kind       TEXT NOT NULL,          -- 'share' | 'pair'
  poll_token TEXT,                   -- pair: the TV polls with this secret, never with the visible code
  user_id    TEXT,                   -- share: the owner; pair: the approving user
  email      TEXT,
  auth_key   TEXT,                   -- handed over exactly once on redeem/poll, then deleted
  name       TEXT,                   -- share: the household's display name
  expires_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS codes_poll ON codes(poll_token);
