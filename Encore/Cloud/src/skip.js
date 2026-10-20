// Intro / recap / credits markers, fetched from TheIntroDB on the app's behalf. TheIntroDB sits behind
// Cloudflare's bot protection, which can turn away requests from TVs and phones; from the Worker (on
// Cloudflare's own network) they get through, and each answer is cached for a day.
//
//   GET /v1/skip?imdb=tt…&season=1&episode=1&duration_ms=… -> TheIntroDB's JSON, as is
//   GET /v1/skip?…&probe=1                                 -> what each candidate endpoint answered

const BASES = [
  "https://api.theintrodb.org/v3/media",
  "https://api.theintrodb.org/v2/media",
  "https://api.theintrodb.org/v1/media",
];

export async function skipRoute(url, deps) {
  const imdb = url.searchParams.get("imdb") || "";
  if (!/^tt\d{5,10}$/.test(imdb)) return { status: 400, body: { error: "Expected imdb=tt…" } };
  const query = new URLSearchParams({ imdb_id: imdb });
  for (const key of ["season", "episode", "duration_ms"]) {
    const value = url.searchParams.get(key);
    if (value && /^\d+$/.test(value)) query.set(key, value);
  }
  const headers = { accept: "application/json", "user-agent": "EncoreCloud/1.0 (+https://github.com/ivanxcc/Encore)" };

  if (url.searchParams.get("probe") === "1") {
    const attempts = [];
    for (const base of BASES) {
      try {
        const response = await deps.fetchTMDB(`${base}?${query}`, { headers });
        const text = await response.text();
        attempts.push({ url: `${base}?${query}`, status: response.status, body: text.slice(0, 600) });
      } catch (error) {
        attempts.push({ url: `${base}?${query}`, error: String(error) });
      }
    }
    return { status: 200, body: { attempts } };
  }

  const key = `skip:v1:${query}`;
  const cache = deps.cache;
  const cacheRequest = new Request(`https://encore-cache.internal/${encodeURIComponent(key)}`);
  if (cache) {
    const hit = await cache.match(cacheRequest);
    if (hit) return { status: 200, body: await hit.json() };
  }
  for (const base of BASES) {
    let response;
    try { response = await deps.fetchTMDB(`${base}?${query}`, { headers }); } catch { continue; }
    if (response.status === 404) return { status: 404, body: { error: "No markers" } };
    if (!response.ok) continue;
    const body = await response.json().catch(() => null);
    if (!body || typeof body !== "object") continue;
    if (cache) {
      await cache.put(cacheRequest, new Response(JSON.stringify(body), {
        headers: { "content-type": "application/json", "cache-control": "public, max-age=86400" },
      }));
    }
    return { status: 200, body };
  }
  return { status: 502, body: { error: "TheIntroDB is unavailable" } };
}
