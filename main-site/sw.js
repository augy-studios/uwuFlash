/* uwuFlash service worker.

   Bump VERSION on every deploy that changes anything this worker serves.
   The browser compares this file byte for byte, so an unchanged worker means
   no update is detected however much else in the build has moved, and the
   update bar is then a prompt nobody ever sees.

   VERSION is a plain integer: 1, 2, 3. No "v" prefix, no dots, and no
   trailing decimal, so bumping it is always +1 and never a judgement about
   whether a change is a major or a minor one. It is a counter, not a release
   number, and nothing but this file ever reads it.

   Note what is deliberately absent: there is no skipWaiting() in install and
   no clients.claim() in activate. A new worker downloads, installs, and then
   waits. The only thing that promotes it is a person pressing Reload in the
   update bar, which posts the message handled at the bottom of this file.
   See update-bar-spec.md at the repo root. */

const VERSION = 2;
const CACHE = `uwuFlash-${VERSION}`;

/* Everything the app needs to start with no network at all. The editor, the
   presenter and the saved deck are all local, so a complete precache is the
   difference between an app that works on a train and one that does not. */
const ASSETS = [
  "/",
  "/index.html",
  "/404.html",
  "/style.css",
  "/404.css",
  "/css/theme.css",
  "/js/app.js",
  "/js/theme.js",
  "/js/icons.js",
  "/js/ui.js",
  "/js/update.js",
  "/js/store.js",
  "/js/deck.js",
  "/js/render.js",
  "/UFCS-192.png",
  "/UFCS-512.png",
  "/favicon.ico",
  "/manifest.json",
];

/* -- Install: cache shell -- */

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) =>
      // Individually rather than addAll, which rejects the whole install if
      // any one asset 404s. A missing screenshot should not leave a reader
      // with no worker at all.
      Promise.all(
        ASSETS.map((url) =>
          cache.add(new Request(url, { cache: "reload" })).catch(() => {
            console.warn("sw: could not precache", url);
          })
        )
      )
    )
  );
});

/* -- Activate: clean old caches -- */

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
  );
});

/* -- Fetch: strategy per route -- */

self.addEventListener("fetch", (event) => {
  const { request } = event;

  // Only GET is cacheable, and only this origin plus the font CDN is worth
  // caching. Analytics and ads go straight to the network and are never
  // stored, which also keeps them from filling the cache while offline.
  if (request.method !== "GET") return;

  // A range request is a partial read of something already being streamed.
  // Answering one from a whole cached body is how audio and video break.
  if (request.headers.has("range")) return;

  const url = new URL(request.url);
  const sameOrigin = url.origin === self.location.origin;
  const isFont = url.hostname === "fonts.googleapis.com" || url.hostname === "fonts.gstatic.com";

  if (!sameOrigin && !isFont) return;

  // API - network-first
  if (sameOrigin && url.pathname.startsWith("/api/")) {
    event.respondWith(networkFirst(request));
    return;
  }

  // Navigations - network-first with the cached shell as the fallback, so a
  // deploy reaches a reader's next navigation rather than waiting for the
  // cache to expire, and an offline reader still gets the app.
  if (request.mode === "navigate") {
    event.respondWith(navigationHandler(request));
    return;
  }

  // Google Fonts and static assets - cache-first, refreshed in the
  // background so the next load has the newer copy.
  event.respondWith(staleWhileRevalidate(request));
});

/* -- Strategies -- */

async function networkFirst(request) {
  try {
    return await fetch(request);
  } catch {
    return new Response(JSON.stringify({ success: false, error: "You appear to be offline." }), {
      status: 503,
      headers: { "Content-Type": "application/json" },
    });
  }
}

async function navigationHandler(request) {
  try {
    const response = await fetch(request);
    if (response.ok) {
      const cache = await caches.open(CACHE);
      cache.put(request, response.clone());
    }
    return response;
  } catch {
    return (await caches.match(request)) || (await caches.match("/index.html")) || offline();
  }
}

async function staleWhileRevalidate(request) {
  const cached = await caches.match(request);

  const network = fetch(request)
    .then(async (response) => {
      // Opaque cross-origin responses have status 0 and are still worth
      // keeping: that is what a Google Fonts file comes back as.
      if (response.ok || response.type === "opaque") {
        const cache = await caches.open(CACHE);
        cache.put(request, response.clone());
      }
      return response;
    })
    .catch(() => null);

  return cached || (await network) || offline();
}

function offline() {
  return new Response("Offline", { status: 503, headers: { "Content-Type": "text/plain" } });
}

/* -- The one place this worker is ever promoted -- */

self.addEventListener("message", (event) => {
  const type = typeof event.data === "string" ? event.data : event.data?.type;

  // The only place either of these is ever called. Anything that calls
  // skipWaiting() outside this handler turns the update bar back into a
  // silent takeover, which is the bug it exists to prevent.
  if (type === "skip-waiting") {
    event.waitUntil(self.skipWaiting().then(() => self.clients.claim()));
  }
});
