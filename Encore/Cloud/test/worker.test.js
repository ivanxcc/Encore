// Runs the Worker against a real SQLite database standing in for D1, with Stremio mocked out.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { DatabaseSync } from "node:sqlite";
import { handle, normalizeCode } from "../src/index.js";

function fakeD1() {
  const db = new DatabaseSync(":memory:");
  db.exec(readFileSync(new URL("../migrations/0001_init.sql", import.meta.url), "utf8"));
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
