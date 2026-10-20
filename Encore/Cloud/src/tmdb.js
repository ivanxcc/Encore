// Artwork, cast, and "trending this week" from TMDB, the database behind most media apps' metadata.
// Optional: without a TMDB_API_KEY secret these routes answer 404 and the apps use Cinemeta alone.
//
//   GET /v1/title?imdb=tt…&type=movie|series -> { tmdbId, backdrop, logo, tagline, cast[], crew[], certification }
//   GET /v1/season?tmdb=…&season=N          -> { episodes: [{ episode, runtime }] } (minutes, exact per episode)
//   GET /v1/trending                         -> { items: [{ imdbId, type, name, backdrop, logo, overview, year, genres, rating }] }
//
// Responses are cached at the edge (a day for titles, six hours for trending) so a living room full of
// devices costs TMDB almost nothing.

const TMDB = "https://api.themoviedb.org/3";
const IMG = "https://image.tmdb.org/t/p/";

export async function tmdbRoute(route, url, env, deps) {
  if (!env.TMDB_API_KEY) return null;
  if (route === "GET /v1/title") {
    const imdb = url.searchParams.get("imdb") || "";
    const type = url.searchParams.get("type") === "series" ? "series" : "movie";
    if (!/^tt\d{5,10}$/.test(imdb)) return { status: 400, body: { error: "Expected imdb=tt…" } };
    return cached(deps, `title:v3:${type}:${imdb}`, 24 * 3600, () => title(imdb, type, env, deps));
  }
  if (route === "GET /v1/season") {
    const id = url.searchParams.get("tmdb") || "";
    const number = url.searchParams.get("season") || "";
    if (!/^\d{1,9}$/.test(id) || !/^\d{1,3}$/.test(number)) return { status: 400, body: { error: "Expected tmdb=…&season=N" } };
    return cached(deps, `season:v1:${id}:${number}`, 24 * 3600, () => season(id, number, env, deps));
  }
  if (route === "GET /v1/trending") {
    return cached(deps, "trending:v1", 6 * 3600, () => trending(env, deps));
  }
  return null;
}

async function cached(deps, key, ttl, produce) {
  const cache = deps.cache;
  const request = new Request(`https://encore-cache.internal/${encodeURIComponent(key)}`);
  if (cache) {
    const hit = await cache.match(request);
    if (hit) return { status: 200, body: await hit.json() };
  }
  const result = await produce();
  if (cache && result.status === 200) {
    await cache.put(request, new Response(JSON.stringify(result.body), {
      headers: { "content-type": "application/json", "cache-control": `public, max-age=${ttl}` },
    }));
  }
  return result;
}

async function call(path, params, env, deps) {
  const key = env.TMDB_API_KEY;
  const query = new URLSearchParams(params);
  const headers = { accept: "application/json" };
  // A v4 "read access token" is a long JWT sent as a bearer token; a v3 key is a short query parameter.
  if (key.length > 40) headers.authorization = `Bearer ${key}`; else query.set("api_key", key);
  const response = await deps.fetchTMDB(`${TMDB}${path}?${query}`, { headers });
  if (!response.ok) throw new Error(`TMDB ${path} ${response.status}`);
  return response.json();
}

async function title(imdb, type, env, deps) {
  const found = await call(`/find/${imdb}`, { external_source: "imdb_id" }, env, deps);
  const hit = type === "series" ? (found.tv_results || [])[0] || (found.movie_results || [])[0]
                                : (found.movie_results || [])[0] || (found.tv_results || [])[0];
  if (!hit) return { status: 404, body: { error: "Not on TMDB" } };
  const kind = hit.media_type === "tv" || (found.tv_results || []).includes(hit) ? "tv" : "movie";
  const detail = await call(`/${kind}/${hit.id}`, {
    append_to_response: kind === "tv" ? "aggregate_credits,images,content_ratings,videos" : "credits,images,release_dates,videos",
    include_image_language: "en,null",
    include_video_language: "en,null",
  }, env, deps);
  return { status: 200, body: shapeTitle(detail, kind) };
}

export function shapeTitle(detail, kind) {
  const people = kind === "tv" ? (detail.aggregate_credits || {}).cast || [] : (detail.credits || {}).cast || [];
  const cast = people.slice(0, 20).map((p) => ({
    name: p.name,
    character: p.character || ((p.roles || [])[0] || {}).character || null,
    photo: p.profile_path ? `${IMG}h632${p.profile_path}` : null,
  }));
  const crew = kind === "tv"
    ? (detail.created_by || []).map((p) => ({ name: p.name, job: "Creator" }))
    : ((detail.credits || {}).crew || []).filter((p) => p.job === "Director").map((p) => ({ name: p.name, job: "Director" }));
  return {
    tmdbId: detail.id,
    backdrop: bestBackdrop(detail),
    logo: bestLogo(detail),
    tagline: detail.tagline || null,
    cast,
    crew: crew.slice(0, 4),
    certification: certification(detail, kind),
    trailer: bestTrailer(detail),
    runtime: typeof detail.runtime === "number" && detail.runtime > 0 ? detail.runtime : null,
  };
}

/** The official trailer at the highest resolution (YouTube serves it adaptively, up to 4K). */
export function bestTrailer(detail) {
  const videos = ((detail.videos || {}).results || []).filter((v) => v.site === "YouTube" && v.key);
  const score = (v) => (v.type === "Trailer" ? 1000 : v.type === "Teaser" ? 500 : 0)
    + (v.official ? 200 : 0) + (v.iso_639_1 === "en" ? 100 : 0) + (v.size || 0) / 100
    + (Date.parse(v.published_at || 0) || 0) / 1e13;
  const best = videos.filter((v) => v.type === "Trailer" || v.type === "Teaser").sort((a, b) => score(b) - score(a))[0];
  return best ? { site: "YouTube", key: best.key, name: best.name || "Trailer", size: best.size || null } : null;
}

/** The best-voted backdrop without text on it, at original resolution (up to 4K). */
function bestBackdrop(detail) {
  const backdrops = ((detail.images || {}).backdrops || []).slice().sort((a, b) => b.vote_average - a.vote_average);
  const textless = backdrops.find((b) => !b.iso_639_1) || backdrops[0];
  const path = (textless && textless.file_path) || detail.backdrop_path;
  return path ? `${IMG}original${path}` : null;
}

/** The best-voted English title logo (a transparent PNG). */
function bestLogo(detail) {
  const logos = ((detail.images || {}).logos || []).filter((l) => l.iso_639_1 === "en" && !String(l.file_path).endsWith(".svg"));
  logos.sort((a, b) => b.vote_average - a.vote_average);
  return logos[0] ? `${IMG}original${logos[0].file_path}` : null;
}

function certification(detail, kind) {
  if (kind === "tv") {
    const us = ((detail.content_ratings || {}).results || []).find((r) => r.iso_3166_1 === "US");
    return (us && us.rating) || null;
  }
  const us = ((detail.release_dates || {}).results || []).find((r) => r.iso_3166_1 === "US");
  const rated = us && (us.release_dates || []).find((d) => d.certification);
  return (rated && rated.certification) || null;
}

/** Each episode's own length, which Stremio add-ons don't carry. */
async function season(id, number, env, deps) {
  let detail;
  try {
    detail = await call(`/tv/${id}/season/${number}`, {}, env, deps);
  } catch {
    return { status: 404, body: { error: "No such season" } };
  }
  const episodes = (detail.episodes || [])
    .filter((e) => Number.isInteger(e.episode_number) && typeof e.runtime === "number" && e.runtime > 0)
    .map((e) => ({ episode: e.episode_number, runtime: e.runtime }));
  return { status: 200, body: { episodes } };
}

async function trending(env, deps) {
  const list = await call("/trending/all/week", {}, env, deps);
  const picks = (list.results || []).filter((r) => r.media_type === "movie" || r.media_type === "tv").slice(0, 20);
  const detailed = await Promise.all(picks.map(async (r) => {
    try {
      const detail = await call(`/${r.media_type}/${r.id}`, {
        append_to_response: "external_ids,images", include_image_language: "en,null",
      }, env, deps);
      const imdbId = detail.imdb_id || (detail.external_ids || {}).imdb_id;
      if (!imdbId) return null;
      const date = detail.release_date || detail.first_air_date || "";
      return {
        imdbId,
        type: r.media_type === "tv" ? "series" : "movie",
        name: detail.title || detail.name,
        backdrop: bestBackdrop(detail),
        logo: bestLogo(detail),
        overview: detail.overview || null,
        year: date.slice(0, 4) || null,
        genres: (detail.genres || []).map((g) => g.name),
        rating: typeof detail.vote_average === "number" ? Math.round(detail.vote_average * 10) / 10 : null,
      };
    } catch {
      return null;
    }
  }));
  return { status: 200, body: { items: detailed.filter((i) => i && i.backdrop) } };
}
