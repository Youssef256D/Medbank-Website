const serviceWorkerUrl = new URL(self.location.href);
const cacheVersion = String(serviceWorkerUrl.searchParams.get("v") || "").trim();
const versionSuffix = cacheVersion ? `?v=${encodeURIComponent(cacheVersion)}` : "";
const CACHE_NAME = `medbank-static-v${(cacheVersion || "runtime").replace(/\./g, "-")}`;
const APP_SHELL_URL = new URL("./index.html", self.location.href).toString();
const APP_ROOT_URL = new URL("./", self.location.href).toString();
const APP_SHELL_PATHNAME = new URL(APP_SHELL_URL).pathname;
const APP_ROOT_PATHNAME = new URL(APP_ROOT_URL).pathname;

const PRECACHE_URLS = [
  "./",
  "./index.html",
  `./styles.css${versionSuffix}`,
  `./bootstrap.js${versionSuffix}`,
  `./video-courses-utils.js${versionSuffix}`,
  `./main.js${versionSuffix}`,
  `./supabase.config.js${versionSuffix}`,
  "./manifest.webmanifest",
  "./robots.txt",
  "./sitemap.xml",
  "./Assets/branding/medbank-logo.png",
  "./Assets/branding/about-study-workspace.svg",
  "./Assets/branding/about-review-flow.svg",
  "./Assets/branding/about-analytics.svg",
  "./Assets/branding/apple-touch-icon.png",
  "./Assets/branding/favicon-192x192.png",
  "./Assets/branding/favicon.png"
];

function buildOfflineResponse(body = "Offline", status = 503, contentType = "text/plain;charset=utf-8") {
  return new Response(body, {
    status,
    headers: {
      "Content-Type": contentType,
      "Cache-Control": "no-store",
    },
  });
}

async function matchFirst(requests) {
  for (const candidate of requests) {
    try {
      const match = await caches.match(candidate);
      if (match) {
        return match;
      }
    } catch {
      // Ignore cache lookup failures and continue to the next fallback.
    }
  }
  return null;
}

function isSuccessfulBasicResponse(response) {
  return Boolean(response) && response.status === 200 && response.type === "basic";
}

function cacheResponse(request, response) {
  if (!isSuccessfulBasicResponse(response)) {
    return;
  }
  const clone = response.clone();
  caches.open(CACHE_NAME)
    .then((cache) => cache.put(request, clone))
    .catch(() => {
      // Ignore cache write failures to avoid breaking the fetch response path.
    });
}

function isAppShellRequestUrl(requestUrl) {
  const normalizedPathname = String(requestUrl.pathname || "");
  const normalizedRootPath = APP_ROOT_PATHNAME.endsWith("/")
    ? APP_ROOT_PATHNAME.slice(0, -1)
    : APP_ROOT_PATHNAME;
  return normalizedPathname === APP_ROOT_PATHNAME
    || normalizedPathname === normalizedRootPath
    || normalizedPathname === APP_SHELL_PATHNAME;
}

async function getAppShellFallback(request) {
  const cached = await matchFirst([
    APP_ROOT_URL,
    APP_SHELL_URL,
    "./",
    "./index.html",
    request,
  ]);
  if (cached) {
    return cached;
  }
  return buildOfflineResponse(
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>Offline</title></head><body><h1>Offline</h1><p>The app shell is unavailable right now.</p></body></html>",
    503,
    "text/html;charset=utf-8",
  );
}

async function handleNavigationRequest(request) {
  try {
    return await fetch(request, { cache: "no-store" });
  } catch {
    return getAppShellFallback(request);
  }
}

async function handleStaticRequest(request, requestUrl) {
  const isVersioned = requestUrl.searchParams.has("v");
  const appShellRequest = isAppShellRequestUrl(requestUrl);

  if (isVersioned) {
    const cached = await matchFirst([request]);
    if (cached) {
      return cached;
    }
    try {
      const response = await fetch(request);
      cacheResponse(request, response);
      return response;
    } catch {
      return appShellRequest ? getAppShellFallback(request) : buildOfflineResponse();
    }
  }

  try {
    const response = await fetch(request);
    cacheResponse(request, response);
    return response;
  } catch {
    const cached = await matchFirst([request]);
    if (cached) {
      return cached;
    }
    if (appShellRequest) {
      return getAppShellFallback(request);
    }
    return buildOfflineResponse();
  }
}

self.addEventListener("install", (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(PRECACHE_URLS)),
  );
  self.skipWaiting();
});

self.addEventListener("activate", (event) => {
  event.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener("fetch", (event) => {
  const request = event.request;
  if (request.method !== "GET") {
    return;
  }

  const requestUrl = new URL(request.url);
  if (requestUrl.origin !== self.location.origin) {
    return;
  }

  if (request.mode === "navigate") {
    event.respondWith(handleNavigationRequest(request));
    return;
  }

  event.respondWith(handleStaticRequest(request, requestUrl));
});
