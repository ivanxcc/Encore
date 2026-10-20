// Runs the Worker against a real SQLite database standing in for D1, with Stremio mocked out.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import worker, { handle, normalizeCode } from "../src/index.js";

function fakeD1() {
  const db = new DatabaseSync(":memory:");
  for (const file of ["0001_init.sql", "0002_directory.sql"]) {
    db.exec(readFileSync(new URL(`../migrations/${file}`, import.meta.url), "utf8"));
  }
  return {
    prepare(sql) {
      let params = [];
      const statement = {
        bind(...values) { params = values.map((v) => (v === undefined ? null : v)); return statement; },
        async first() { return db.prepare(sql).get(...params) ?? null; },
        async all() { return { results: db.prepare(sql).all(...params) }; },
        async run() { const r = db.prepare(sql).run(...params); return { meta: { changes: Number(r.changes) } }; },
      };
      return statement;
    },
  };
}

const USERS = { "key-ivan": { _id: "u-ivan", email: "ivan@example.com" }, "key-sis": { _id: "u-sis", email: "sis@example.com" } };

function makeWorld() {
  const env = { DB: fakeD1() };
  const world = { env, clock: 1_000_000, stremioCalls: 0 };
  world.deps = {
    now: () => world.clock,
    fetchStremio: async (_url, init) => {
      world.stremioCalls += 1;
      const { authKey } = JSON.parse(init.body);
      const user = USERS[authKey];
      return new Response(JSON.stringify(user ? { result: user } : { error: { message: "Session not found" } }));
    },
  };
  world.call = async (method, path, { key, body } = {}) => {
    const headers = { "content-type": "application/json" };
    if (key) headers.authorization = `Stremio ${key}`;
    const response = await handle(new Request("https://cloud.test" + path, { method, headers, body: body && JSON.stringify(body) }), env, world.deps);
    return { status: response.status, body: await response.json() };
  };
  return world;
}

test("health needs no sign-in", async () => {
  const w = makeWorld();
  assert.equal((await w.call("GET", "/v1/health")).status, 200);
});

test("rejects unknown and missing Stremio sessions", async () => {
  const w = makeWorld();
  assert.equal((await w.call("GET", "/v1/household")).status, 401);
  assert.equal((await w.call("GET", "/v1/household", { key: "nope" })).status, 401);
});

test("verifies a session once and then trusts the cache until it expires", async () => {
  const w = makeWorld();
  await w.call("GET", "/v1/household", { key: "key-ivan" });
  await w.call("GET", "/v1/household", { key: "key-ivan" });
  assert.equal(w.stremioCalls, 1);
  w.clock += 7 * 60 * 60;
  await w.call("GET", "/v1/household", { key: "key-ivan" });
  assert.equal(w.stremioCalls, 2);
});

test("household writes are versioned and conflicts return the current document", async () => {
  const w = makeWorld();
  assert.equal((await w.call("GET", "/v1/household", { key: "key-ivan" })).status, 404);
  const first = await w.call("PUT", "/v1/household", { key: "key-ivan", body: { baseVersion: 0, doc: { name: "Home" } } });
  assert.deepEqual(first, { status: 200, body: { version: 1 } });
  const stale = await w.call("PUT", "/v1/household", { key: "key-ivan", body: { baseVersion: 0, doc: { name: "Stale" } } });
  assert.equal(stale.status, 409);
  assert.deepEqual(stale.body, { version: 1, doc: { name: "Home" } });
  const second = await w.call("PUT", "/v1/household", { key: "key-ivan", body: { baseVersion: 1, doc: { name: "Home 2" } } });
  assert.equal(second.body.version, 2);
  const read = await w.call("GET", "/v1/household", { key: "key-ivan" });
  assert.deepEqual(read.body.doc, { name: "Home 2" });
  assert.equal(read.body.version, 2);
});

test("accounts never see each other's household", async () => {
  const w = makeWorld();
  await w.call("PUT", "/v1/household", { key: "key-ivan", body: { baseVersion: 0, doc: { name: "Ivan" } } });
  assert.equal((await w.call("GET", "/v1/household", { key: "key-sis" })).status, 404);
});

test("rejects malformed household writes", async () => {
  const w = makeWorld();
  assert.equal((await w.call("PUT", "/v1/household", { key: "key-ivan", body: { doc: {} } })).status, 400);
  assert.equal((await w.call("PUT", "/v1/household", { key: "key-ivan", body: { baseVersion: 0, doc: "x" } })).status, 400);
});

test("deleting erases the household", async () => {
  const w = makeWorld();
  await w.call("PUT", "/v1/household", { key: "key-ivan", body: { baseVersion: 0, doc: { name: "Home" } } });
  assert.equal((await w.call("DELETE", "/v1/household", { key: "key-ivan" })).status, 200);
  assert.equal((await w.call("GET", "/v1/household", { key: "key-ivan" })).status, 404);
});

test("a share code hands the household over once", async () => {
  const w = makeWorld();
  const share = await w.call("POST", "/v1/share", { key: "key-sis", body: { name: "Sis's place" } });
  assert.match(share.body.code, /^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
  const typed = share.body.code.toLowerCase().replace("-", " ");
  const redeemed = await w.call("POST", "/v1/share/redeem", { key: "key-ivan", body: { code: typed } });
  assert.deepEqual(redeemed.body, { ownerId: "u-sis", email: "sis@example.com", authKey: "key-sis", name: "Sis's place" });
  assert.equal((await w.call("POST", "/v1/share/redeem", { key: "key-ivan", body: { code: share.body.code } })).status, 404);
});

test("share codes expire", async () => {
  const w = makeWorld();
  const share = await w.call("POST", "/v1/share", { key: "key-sis", body: {} });
  w.clock += 16 * 60;
  assert.equal((await w.call("POST", "/v1/share/redeem", { key: "key-ivan", body: { code: share.body.code } })).status, 404);
});

test("a TV signs in by having a phone approve its code", async () => {
  const w = makeWorld();
  const start = await w.call("POST", "/v1/pair/start");
  assert.equal(start.status, 200);
  const poll = (token) => w.call("GET", `/v1/pair/poll?token=${token}`);
  assert.equal((await poll(start.body.pollToken)).status, 202);
  assert.equal((await w.call("POST", "/v1/pair/approve", { key: "key-ivan", body: { code: "ZZZZ-ZZZZ" } })).status, 404);
  assert.equal((await w.call("POST", "/v1/pair/approve", { key: "key-ivan", body: { code: start.body.code } })).status, 200);
  // A second phone can't take over an already approved code.
  assert.equal((await w.call("POST", "/v1/pair/approve", { key: "key-sis", body: { code: start.body.code } })).status, 404);
  const done = await poll(start.body.pollToken);
  assert.deepEqual(done, { status: 200, body: { authKey: "key-ivan", email: "ivan@example.com" } });
  assert.equal((await poll(start.body.pollToken)).status, 410);
});

test("pairing codes expire", async () => {
  const w = makeWorld();
  const start = await w.call("POST", "/v1/pair/start");
  w.clock += 16 * 60;
  assert.equal((await w.call("GET", `/v1/pair/poll?token=${start.body.pollToken}`)).status, 410);
  assert.equal((await w.call("GET", "/v1/pair/poll")).status, 400);
});

test("codes are read forgivingly", () => {
  assert.equal(normalizeCode(" abcd-efgh "), "ABCDEFGH");
  assert.equal(normalizeCode(null), "");
});

test("the deployed entry point calls fetch the way the Workers runtime requires", async () => {
  const real = globalThis.fetch;
  // Like workerd: fetch refuses to run as a method of some other object.
  globalThis.fetch = function (url, init) {
    if (this !== undefined && this !== globalThis) throw new TypeError("Illegal invocation");
    return Promise.resolve(new Response(JSON.stringify({ result: USERS["key-ivan"] })));
  };
  try {
    const env = { DB: fakeD1() };
    const request = new Request("https://cloud.test/v1/household", { headers: { authorization: "Stremio key-ivan" } });
    const response = await worker.fetch(request, env, {});
    assert.equal(response.status, 404);   // authenticated; no household stored yet
  } finally {
    globalThis.fetch = real;
  }
});

test("each account keeps its own versioned directory of households, separate from its household", async () => {
  const w = makeWorld();
  assert.equal((await w.call("GET", "/v1/directory", { key: "key-ivan" })).status, 404);
  const doc = { households: [{ key: "account:u-sis", name: "Sis" }] };
  assert.deepEqual((await w.call("PUT", "/v1/directory", { key: "key-ivan", body: { baseVersion: 0, doc } })).body, { version: 1 });
  assert.equal((await w.call("PUT", "/v1/directory", { key: "key-ivan", body: { baseVersion: 0, doc: {} } })).status, 409);
  assert.deepEqual((await w.call("GET", "/v1/directory", { key: "key-ivan" })).body.doc, doc);
  assert.equal((await w.call("GET", "/v1/household", { key: "key-ivan" })).status, 404);
  assert.equal((await w.call("GET", "/v1/directory", { key: "key-sis" })).status, 404);
  await w.call("DELETE", "/v1/household", { key: "key-ivan" });
  assert.equal((await w.call("GET", "/v1/directory", { key: "key-ivan" })).status, 404);
});

// MARK: TMDB

function tmdbWorld() {
  const w = makeWorld();
  w.env.TMDB_API_KEY = "0123456789abcdef0123456789abcdef";
  w.tmdbCalls = [];
  const store = new Map();
  w.deps.cache = {
    async match(req) { const hit = store.get(req.url); return hit ? new Response(hit) : undefined; },
    async put(req, res) { store.set(req.url, await res.text()); },
  };
  const img = (path, lang, vote) => ({ file_path: path, iso_639_1: lang, vote_average: vote });
  w.deps.fetchTMDB = async (url) => {
    const u = new URL(url);
    w.tmdbCalls.push(u.pathname);
    assert.equal(u.searchParams.get("api_key"), w.env.TMDB_API_KEY);
    const routes = {
      "/3/find/tt1442437": { tv_results: [{ id: 1421, media_type: "tv" }], movie_results: [] },
      "/3/tv/1421": {
        id: 1421, tagline: "One big (straight, gay, multi-cultural, traditional) happy family.",
        backdrop_path: "/plain.jpg", created_by: [{ name: "Steven Levitan" }],
        aggregate_credits: { cast: [{ name: "Ed O'Neill", roles: [{ character: "Jay Pritchett" }], profile_path: "/ed.jpg" },
                                    { name: "Sofía Vergara", roles: [{ character: "Gloria" }], profile_path: null }] },
        images: { backdrops: [img("/text.jpg", "en", 9), img("/clean.jpg", null, 7)], logos: [img("/logo.svg", "en", 9), img("/logo.png", "en", 8)] },
        content_ratings: { results: [{ iso_3166_1: "US", rating: "TV-PG" }] },
        videos: { results: [
          { site: "YouTube", key: "teaser1", type: "Teaser", official: true, iso_639_1: "en", size: 2160 },
          { site: "YouTube", key: "fan", type: "Trailer", official: false, iso_639_1: "en", size: 2160 },
          { site: "YouTube", key: "official", type: "Trailer", official: true, iso_639_1: "en", size: 1080, name: "Official Trailer" },
          { site: "Vimeo", key: "v", type: "Trailer", official: true, iso_639_1: "en", size: 2160 },
        ] },
      },
      "/3/trending/all/week": { results: [{ id: 1, media_type: "movie" }, { id: 2, media_type: "person" }, { id: 3, media_type: "tv" }] },
      "/3/movie/1": { imdb_id: "tt100", title: "Dune", release_date: "2024-03-01", genres: [{ name: "Sci-Fi" }], vote_average: 8.24,
                      images: { backdrops: [img("/dune.jpg", null, 8)], logos: [] } },
      "/3/tv/3": { name: "No IMDb", first_air_date: "2024", external_ids: {}, images: { backdrops: [] } },
    };
    const body = routes[u.pathname];
    return new Response(JSON.stringify(body || {}), { status: body ? 200 : 404 });
  };
  return w;
}

test("TMDB routes answer 404 until a key is set", async () => {
  const w = makeWorld();
  assert.equal((await w.call("GET", "/v1/title?imdb=tt1442437&type=series")).status, 404);
  assert.equal((await w.call("GET", "/v1/trending")).status, 404);
});

test("title extras: cast with photos, textless original backdrop, English PNG logo, creator, rating", async () => {
  const w = tmdbWorld();
  const res = await w.call("GET", "/v1/title?imdb=tt1442437&type=series");
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.cast[0], { name: "Ed O'Neill", character: "Jay Pritchett", photo: "https://image.tmdb.org/t/p/h632/ed.jpg" });
  assert.equal(res.body.cast[1].photo, null);
  assert.equal(res.body.backdrop, "https://image.tmdb.org/t/p/original/clean.jpg");
  assert.equal(res.body.logo, "https://image.tmdb.org/t/p/original/logo.png");
  assert.deepEqual(res.body.crew, [{ name: "Steven Levitan", job: "Creator" }]);
  assert.equal(res.body.certification, "TV-PG");
  assert.deepEqual(res.body.trailer, { site: "YouTube", key: "official", name: "Official Trailer", size: 1080 });
  // Cached: a second request makes no TMDB calls.
  const calls = w.tmdbCalls.length;
  assert.equal((await w.call("GET", "/v1/title?imdb=tt1442437&type=series")).status, 200);
  assert.equal(w.tmdbCalls.length, calls);
  assert.equal((await w.call("GET", "/v1/title?imdb=nope")).status, 400);
});

test("trending keeps titles with an IMDb id and artwork", async () => {
  const w = tmdbWorld();
  const res = await w.call("GET", "/v1/trending");
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.items, [{
    imdbId: "tt100", type: "movie", name: "Dune", backdrop: "https://image.tmdb.org/t/p/original/dune.jpg",
    logo: null, overview: null, year: "2024", genres: ["Sci-Fi"], rating: 8.2,
  }]);
});

test("skip markers are fetched from TheIntroDB, falling back across API versions, and cached", async () => {
  const w = makeWorld();
  const store = new Map();
  w.deps.cache = {
    async match(req) { const hit = store.get(req.url); return hit ? new Response(hit) : undefined; },
    async put(req, res) { store.set(req.url, await res.text()); },
  };
  const calls = [];
  w.deps.fetchTMDB = async (url) => {
    calls.push(url);
    if (url.includes("/v3/")) return new Response("<html>blocked</html>", { status: 403 });
    return new Response(JSON.stringify({ intro: [{ start_ms: 0, end_ms: 30000 }] }));
  };
  const res = await w.call("GET", "/v1/skip?imdb=tt1442437&season=1&episode=1&duration_ms=1300000");
  assert.equal(res.status, 200);
  assert.deepEqual(res.body.intro, [{ start_ms: 0, end_ms: 30000 }]);
  assert.ok(calls[1].includes("/v2/media?imdb_id=tt1442437&season=1&episode=1&duration_ms=1300000"));
  const before = calls.length;
  await w.call("GET", "/v1/skip?imdb=tt1442437&season=1&episode=1&duration_ms=1300000");
  assert.equal(calls.length, before, "cached");
  const probe = await w.call("GET", "/v1/skip?imdb=tt1442437&season=1&episode=1&probe=1");
  assert.equal(probe.body.attempts.length, 3);
  assert.equal(probe.body.attempts[0].status, 403);
});
