-- The households an account manages besides its own (a sibling's shared household, a household with
-- no Stremio account), so every device signed in to that account shows the same list.
CREATE TABLE IF NOT EXISTS directories (
  owner_id   TEXT PRIMARY KEY,
  doc        TEXT NOT NULL,
  version    INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
