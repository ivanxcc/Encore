// Encore Web's service worker: the app's own files are kept on the device, so it opens at once and
// opens at all without a connection. Nothing else is touched: the relay's streams and the APIs go
// straight to the network.
const SHELL = "encore-shell-1";
const ASSETS = "encore-assets-1";
const CORE = ["/", "/manifest.webmanifest", "/icon.svg", "/icon-180.png", "/icon-512.png"];

self.addEventListener("install", (event) => {
  event.waitUntil(caches.open(SHELL).then((c) => c.addAll(CORE)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (event) => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) if (name !== SHELL && name !== ASSETS) await caches.delete(name);
    await self.clients.claim();
  })());
});

// The page, fresh when the network answers quickly; the kept copy when it doesn't (or there is none).
async function page(request) {
  const cache = await caches.open(SHELL);
  try {
    const fresh = await Promise.race([
      fetch(request),
      new Promise((_, reject) => setTimeout(() => reject(new Error("slow")), 2500)),
    ]);
    if (fresh.ok) {
      cache.put("/", fresh.clone());
      prune(await fresh.clone().text());
    }
    return fresh;
  } catch {
    return (await cache.match("/")) || Response.error();
  }
}

// Old builds' files go once a new page no longer names them.
async function prune(html) {
  const cache = await caches.open(ASSETS);
  for (const request of await cache.keys()) {
    const path = new URL(request.url).pathname;
    if (!html.includes(path)) await cache.delete(request);
  }
}

self.addEventListener("fetch", (event) => {
  const request = event.request;
  const url = new URL(request.url);
  if (request.method !== "GET" || url.origin !== location.origin) return;
  if (url.pathname.startsWith("/v1/") || url.pathname.startsWith("/lab")) return;
  if (request.mode === "navigate") { event.respondWith(page(request)); return; }
  if (url.pathname.startsWith("/assets/")) {
    // Named by their content: a kept copy is always right.
    event.respondWith(caches.open(ASSETS).then(async (cache) => {
      const hit = await cache.match(request);
      if (hit) return hit;
      const fresh = await fetch(request);
      if (fresh.ok) cache.put(request, fresh.clone());
      return fresh;
    }));
    return;
  }
  if (CORE.includes(url.pathname) || url.pathname === "/config.json") {
    event.respondWith(caches.open(SHELL).then(async (cache) => {
      try {
        const fresh = await fetch(request);
        if (fresh.ok) cache.put(request, fresh.clone());
        return fresh;
      } catch {
        return (await cache.match(request)) || Response.error();
      }
    }));
  }
});
