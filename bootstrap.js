(() => {
  const versionTag = document.querySelector('meta[name="app-version"]');
  const appVersion = String(versionTag?.getAttribute("content") || "").trim();
  let requestedAppVersion = "";
  try {
    requestedAppVersion = String(new URL(window.location.href).searchParams.get("appv") || "").trim();
  } catch {
    requestedAppVersion = "";
  }
  const effectiveAppVersion = requestedAppVersion || appVersion;
  const versionSuffix = effectiveAppVersion ? `?v=${encodeURIComponent(effectiveAppVersion)}` : "";
  const ROUTE_STATE_ROUTE_KEY = "mcq_last_route";
  const ROUTE_STATE_ROUTE_LOCAL_KEY = "mcq_last_route_local";
  const GOOGLE_OAUTH_PENDING_KEY = "mcq_google_oauth_pending";
  const SUPABASE_SDK_SOURCES = [
    "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2",
    "https://unpkg.com/@supabase/supabase-js@2",
  ];
  const GSAP_SDK_SOURCES = [
    "https://cdn.jsdelivr.net/npm/gsap@3.13.0/dist/gsap.min.js",
    "https://unpkg.com/gsap@3.13.0/dist/gsap.min.js",
  ];
  const GSAP_SCROLLTRIGGER_SOURCES = [
    "https://cdn.jsdelivr.net/npm/gsap@3.13.0/dist/ScrollTrigger.min.js",
    "https://unpkg.com/gsap@3.13.0/dist/ScrollTrigger.min.js",
  ];
  const LUCIDE_SDK_SOURCES = [
    "https://cdn.jsdelivr.net/npm/lucide@1.21.0/dist/umd/lucide.min.js",
    "https://unpkg.com/lucide@1.21.0/dist/umd/lucide.min.js",
  ];
  const SCRIPT_LOAD_TIMEOUT_MS = 45000;
  const GSAP_LOAD_TIMEOUT_MS = 9000;
  const LUCIDE_LOAD_TIMEOUT_MS = 5000;
  const APP_VERSION_FETCH_TIMEOUT_MS = 2500;
  const APP_BACKGROUND_PREFETCH_DELAY_MS = 1200;
  const BOOTSTRAP_STATUS_ID = "bootstrap-status";
  const STATIC_CACHE_PREFIX = "medbank-static-v";
  const APP_VERSION_SEEN_KEY = "mcq_app_version_seen";
  const APP_VERSION_FORCED_KEY = "mcq_app_version_forced";
  const BOOTSTRAP_RELOAD_TARGET_KEY = "mcq_bootstrap_reload_target";
  const KNOWN_ROUTES = new Set([
    "landing",
    "features",
    "pricing",
    "about",
    "contact",
    "login",
    "signup",
    "forgot",
    "reset-password",
    "complete-profile",
    "app-launcher",
    "courses",
    "video-courses",
    "dashboard",
    "notifications",
    "create-test",
    "qbank",
    "builder",
    "session",
    "review",
    "analytics",
    "profile",
    "admin",
  ]);
  const OAUTH_CALLBACK_QUERY_KEYS = new Set([
    "code",
    "state",
    "type",
    "error",
    "error_code",
    "error_description",
    "access_token",
    "refresh_token",
    "provider_token",
    "provider_refresh_token",
    "token_type",
    "expires_in",
    "expires_at",
  ]);
  const NATIVE_OAUTH_REDIRECT_PARAM = "native_redirect";
  const NATIVE_OAUTH_FLAG_PARAM = "native_oauth";
  let appLoadPromise = null;
  let appPrefetchTriggered = false;
  let supabaseSdkLoadPromise = null;
  let gsapSdkLoadPromise = null;
  let lucideSdkLoadPromise = null;

  function parseOAuthHashParams(hashValue) {
    const rawHash = String(hashValue || "").replace(/^#/, "").trim();
    if (!rawHash || !rawHash.includes("=")) {
      return new URLSearchParams();
    }
    return new URLSearchParams(rawHash);
  }

  function hasOAuthCallbackParams() {
    let currentUrl;
    try {
      currentUrl = new URL(window.location.href);
    } catch {
      return false;
    }

    const params = new URLSearchParams(currentUrl.search || "");
    const hashParams = parseOAuthHashParams(currentUrl.hash);
    hashParams.forEach((value, key) => {
      if (!params.has(key)) {
        params.set(key, value);
      }
    });
    return [...OAUTH_CALLBACK_QUERY_KEYS].some((key) => params.has(key));
  }

  function redirectNativeOAuthCallbackIfNeeded() {
    let currentUrl;
    try {
      currentUrl = new URL(window.location.href);
    } catch {
      return false;
    }

    const searchParams = new URLSearchParams(currentUrl.search || "");
    const hashParams = parseOAuthHashParams(currentUrl.hash);
    const nativeRedirect = String(searchParams.get(NATIVE_OAUTH_REDIRECT_PARAM) || "medbank://auth/callback").trim();
    const isNativeOAuth = searchParams.get(NATIVE_OAUTH_FLAG_PARAM) === "1"
      || searchParams.has(NATIVE_OAUTH_REDIRECT_PARAM);
    if (!isNativeOAuth || !nativeRedirect || !hasOAuthCallbackParams()) {
      return false;
    }

    let targetUrl;
    try {
      targetUrl = new URL(nativeRedirect);
    } catch {
      return false;
    }

    const callbackParams = new URLSearchParams();
    searchParams.forEach((value, key) => {
      if (key !== NATIVE_OAUTH_FLAG_PARAM && key !== NATIVE_OAUTH_REDIRECT_PARAM) {
        callbackParams.set(key, value);
      }
    });
    hashParams.forEach((value, key) => {
      if (!callbackParams.has(key)) {
        callbackParams.set(key, value);
      }
    });

    if (![...OAUTH_CALLBACK_QUERY_KEYS].some((key) => callbackParams.has(key))) {
      return false;
    }

    targetUrl.search = callbackParams.toString();
    targetUrl.hash = "";
    try {
      document.body?.classList.add("is-google-auth-loading");
      window.location.replace(targetUrl.toString());
    } catch {
      window.location.href = targetUrl.toString();
    }
    return true;
  }

  if (redirectNativeOAuthCallbackIfNeeded()) {
    return;
  }

  function isGoogleOAuthPendingState() {
    try {
      return sessionStorage.getItem(GOOGLE_OAUTH_PENDING_KEY) === "1";
    } catch {
      return false;
    }
  }

  function loadScript(src, options = {}) {
    const timeoutMs = Number.isFinite(options.timeoutMs) && options.timeoutMs > 0
      ? options.timeoutMs
      : SCRIPT_LOAD_TIMEOUT_MS;
    let existing = document.querySelector(`script[data-src="${src}"]`);
    if (existing) {
      if (existing.dataset.loaded === "1") {
        return Promise.resolve();
      }
      if (existing.dataset.failed === "1") {
        existing.remove();
        existing = null;
      }
    }

    if (existing) {
      return waitForScriptLoad(existing, src, timeoutMs);
    }

    const script = document.createElement("script");
    script.src = src;
    script.defer = Boolean(options.defer);
    script.async = Boolean(options.async);
    script.dataset.src = src;
    const loadPromise = waitForScriptLoad(script, src, timeoutMs);
    document.head.appendChild(script);
    return loadPromise;
  }

  function waitForScriptLoad(script, src, timeoutMs) {
    return new Promise((resolve, reject) => {
      let settled = false;
      const finalize = (handler, value) => {
        if (settled) {
          return;
        }
        settled = true;
        window.clearTimeout(timeoutId);
        script.removeEventListener("load", onLoad);
        script.removeEventListener("error", onError);
        handler(value);
      };

      const onLoad = () => {
        script.dataset.loaded = "1";
        script.dataset.failed = "0";
        finalize(resolve);
      };
      const onError = () => {
        script.dataset.failed = "1";
        script.remove();
        finalize(reject, new Error(`Failed to load ${src}`));
      };
      const timeoutId = window.setTimeout(() => {
        script.dataset.timedOut = "1";
        finalize(reject, new Error(`Timed out loading ${src}`));
      }, timeoutMs);

      script.addEventListener("load", onLoad, { once: true });
      script.addEventListener("error", onError, { once: true });
    });
  }

  async function loadScriptWithFallback(sources, options = {}) {
    const list = Array.isArray(sources) ? sources : [sources];
    let lastError = null;
    for (const src of list) {
      try {
        await loadScript(src, options);
        return src;
      } catch (error) {
        lastError = error;
        console.warn(`Script load failed: ${src}`, error?.message || error);
      }
    }
    throw lastError || new Error("Script loading failed.");
  }

  function rememberInitialRoute(route) {
    const safeRoute = String(route || "").trim().toLowerCase();
    if (!safeRoute || !KNOWN_ROUTES.has(safeRoute)) {
      return;
    }
    window.__APP_INITIAL_ROUTE__ = safeRoute;
    syncRouteHash(safeRoute);
  }

  function readRouteFromHash() {
    const rawHash = String(window.location.hash || "").replace(/^#/, "").trim().toLowerCase();
    if (!rawHash || rawHash.includes("=")) {
      return "";
    }
    return KNOWN_ROUTES.has(rawHash) ? rawHash : "";
  }

  function syncRouteHash(route) {
    let currentUrl;
    try {
      currentUrl = new URL(window.location.href);
    } catch {
      return;
    }

    const safeRoute = String(route || "").trim().toLowerCase();
    if (!KNOWN_ROUTES.has(safeRoute)) {
      return;
    }
    const nextHash = safeRoute === "landing" ? "" : `#${safeRoute}`;
    if ((currentUrl.hash || "") === nextHash) {
      return;
    }
    const query = currentUrl.searchParams.toString();
    const nextUrl = `${currentUrl.pathname}${query ? `?${query}` : ""}${nextHash}`;
    window.history.replaceState(window.history.state, document.title, nextUrl);
  }

  function setNavLoadingState(loading) {
    document.querySelectorAll("[data-nav]").forEach((node) => {
      if (!(node instanceof HTMLButtonElement)) {
        return;
      }
      if (loading) {
        if (!("bootstrapWasDisabled" in node.dataset)) {
          node.dataset.bootstrapWasDisabled = node.disabled ? "1" : "0";
        }
        node.disabled = true;
        node.style.cursor = "progress";
        return;
      }
      if (!("bootstrapWasDisabled" in node.dataset)) {
        return;
      }
      node.disabled = node.dataset.bootstrapWasDisabled === "1";
      delete node.dataset.bootstrapWasDisabled;
      node.style.cursor = "";
    });
  }

  function getBootstrapStatusElement() {
    let element = document.getElementById(BOOTSTRAP_STATUS_ID);
    if (element) {
      return element;
    }
    element = document.createElement("div");
    element.id = BOOTSTRAP_STATUS_ID;
    element.hidden = true;
    element.setAttribute("role", "status");
    element.setAttribute("aria-live", "polite");
    Object.assign(element.style, {
      position: "fixed",
      left: "50%",
      bottom: "1rem",
      transform: "translateX(-50%)",
      zIndex: "1300",
      borderRadius: "999px",
      padding: "0.45rem 0.8rem",
      fontSize: "0.85rem",
      fontWeight: "600",
      color: "#ffffff",
      background: "rgba(16, 42, 67, 0.92)",
      boxShadow: "0 10px 24px rgba(9, 25, 39, 0.16)",
    });
    document.body.appendChild(element);
    return element;
  }

  function showBootstrapStatus(message, tone = "info") {
    const element = getBootstrapStatusElement();
    element.textContent = String(message || "").trim();
    element.style.background = tone === "error" ? "rgba(180, 35, 24, 0.94)" : "rgba(16, 42, 67, 0.92)";
    element.hidden = false;
  }

  function clearBootstrapStatus() {
    const element = document.getElementById(BOOTSTRAP_STATUS_ID);
    if (element) {
      element.hidden = true;
    }
  }

  function getBootstrapLoadingMessage(route) {
    const safeRoute = String(route || "").trim().toLowerCase();
    if (safeRoute === "signup") {
      return "Opening sign up...";
    }
    if (safeRoute === "login") {
      return "Opening login...";
    }
    return "Loading app...";
  }

  function startAppLoad() {
    if (appLoadPromise) {
      return appLoadPromise;
    }

    appLoadPromise = Promise.resolve()
      .then(() => loadScript(`supabase.config.js${versionSuffix}`, { defer: true, timeoutMs: SCRIPT_LOAD_TIMEOUT_MS }))
      .then(() => ensureLucideLoaded())
      .then(() => {
        ensureGsapLoaded();
      })
      .then(() => loadScript(`video-courses-utils.js${versionSuffix}`, { defer: true, timeoutMs: SCRIPT_LOAD_TIMEOUT_MS }))
      .then(() => loadScript(`main.js${versionSuffix}`, { defer: true, timeoutMs: SCRIPT_LOAD_TIMEOUT_MS }))
      .then(() => {
        if (window.supabase?.createClient) {
          notifySupabaseSdkReady();
          return;
        }
        ensureSupabaseSdkLoaded();
      })
      .catch((error) => {
        appLoadPromise = null;
        console.error("Deferred app bootstrap failed.", error);
        throw error;
      });

    return appLoadPromise;
  }

  function notifyGsapReady() {
    if (window.gsap && window.ScrollTrigger && !window.__MCQ_GSAP_SCROLLTRIGGER_REGISTERED__) {
      try {
        window.gsap.registerPlugin(window.ScrollTrigger);
        window.__MCQ_GSAP_SCROLLTRIGGER_REGISTERED__ = true;
      } catch (error) {
        console.warn("GSAP ScrollTrigger registration failed.", error?.message || error);
      }
    }
    if (typeof window.__MCQ_ON_GSAP_READY__ === "function") {
      try {
        window.__MCQ_ON_GSAP_READY__();
      } catch (error) {
        console.warn("GSAP ready hook failed.", error?.message || error);
      }
    }
    try {
      window.dispatchEvent(new CustomEvent("mcq:gsap-ready"));
    } catch {
      // Ignore event dispatch failures in older embedded browsers.
    }
  }

  function ensureGsapLoaded() {
    if (window.gsap) {
      notifyGsapReady();
      return Promise.resolve();
    }
    if (gsapSdkLoadPromise) {
      return gsapSdkLoadPromise;
    }
    gsapSdkLoadPromise = loadScriptWithFallback(GSAP_SDK_SOURCES, { async: true, timeoutMs: GSAP_LOAD_TIMEOUT_MS })
      .then(() => loadScriptWithFallback(GSAP_SCROLLTRIGGER_SOURCES, { async: true, timeoutMs: GSAP_LOAD_TIMEOUT_MS })
        .catch((error) => {
          console.warn("GSAP ScrollTrigger did not finish loading.", error?.message || error);
        }))
      .then(() => {
        notifyGsapReady();
      })
      .catch((error) => {
        console.warn("GSAP did not finish loading; CSS motion fallback remains active.", error?.message || error);
      })
      .finally(() => {
        gsapSdkLoadPromise = null;
      });
    return gsapSdkLoadPromise;
  }

  function notifyLucideReady() {
    if (typeof window.__MCQ_ON_LUCIDE_READY__ === "function") {
      try {
        window.__MCQ_ON_LUCIDE_READY__();
      } catch (error) {
        console.warn("Lucide ready hook failed.", error?.message || error);
      }
    }
    try {
      window.dispatchEvent(new CustomEvent("mcq:lucide-ready"));
    } catch {
      // Ignore event dispatch failures in older embedded browsers.
    }
  }

  function ensureLucideLoaded() {
    if (window.lucide?.createIcons) {
      notifyLucideReady();
      return Promise.resolve();
    }
    if (lucideSdkLoadPromise) {
      return lucideSdkLoadPromise;
    }
    lucideSdkLoadPromise = loadScriptWithFallback(LUCIDE_SDK_SOURCES, { async: true, timeoutMs: LUCIDE_LOAD_TIMEOUT_MS })
      .then(() => {
        notifyLucideReady();
      })
      .catch((error) => {
        console.warn("Lucide icons did not finish loading; inline icon fallback remains active.", error?.message || error);
      })
      .finally(() => {
        lucideSdkLoadPromise = null;
      });
    return lucideSdkLoadPromise;
  }

  function notifySupabaseSdkReady() {
    if (typeof window.__MCQ_ON_SUPABASE_SDK_READY__ !== "function") {
      return;
    }
    try {
      window.__MCQ_ON_SUPABASE_SDK_READY__();
    } catch (error) {
      console.warn("Supabase SDK ready hook failed.", error?.message || error);
    }
  }

  function ensureSupabaseSdkLoaded() {
    if (window.supabase?.createClient) {
      notifySupabaseSdkReady();
      return Promise.resolve();
    }
    if (supabaseSdkLoadPromise) {
      return supabaseSdkLoadPromise;
    }
    supabaseSdkLoadPromise = loadScriptWithFallback(SUPABASE_SDK_SOURCES, { async: true, timeoutMs: SCRIPT_LOAD_TIMEOUT_MS })
      .then(() => {
        notifySupabaseSdkReady();
      })
      .catch((error) => {
        console.warn("Supabase SDK did not finish loading during bootstrap.", error?.message || error);
      })
      .finally(() => {
        supabaseSdkLoadPromise = null;
      });
    return supabaseSdkLoadPromise;
  }

  function ensureAppLoaded(options = {}) {
    const showBusyUi = Boolean(options.showBusyUi);
    const route = options.route;
    const loadPromise = startAppLoad();
    if (!showBusyUi) {
      return loadPromise;
    }
    setNavLoadingState(true);
    showBootstrapStatus(getBootstrapLoadingMessage(route));
    return loadPromise
      .then((value) => {
        clearBootstrapStatus();
        return value;
      })
      .catch((error) => {
        showBootstrapStatus("Could not open the page. Check your connection and try again.", "error");
        throw error;
      })
      .finally(() => {
        setNavLoadingState(false);
      });
  }

  function persistVersionMarker(storageKey, value) {
    const normalized = String(value || "").trim();
    if (!storageKey || !normalized) {
      return;
    }
    const serialized = JSON.stringify(normalized);
    try {
      localStorage.setItem(storageKey, serialized);
    } catch {
      // Ignore storage failures and continue with the reload path.
    }
    try {
      sessionStorage.setItem(storageKey, serialized);
    } catch {
      // Ignore storage failures and continue with the reload path.
    }
  }

  function readSessionValue(storageKey) {
    try {
      return String(sessionStorage.getItem(storageKey) || "").trim();
    } catch {
      return "";
    }
  }

  function clearSessionValue(storageKey) {
    try {
      sessionStorage.removeItem(storageKey);
    } catch {
      // Ignore storage cleanup failures.
    }
  }

  async function fetchPublishedAppVersion() {
    try {
      const checkUrl = new URL(window.location.href);
      checkUrl.searchParams.set("__app_version_check", String(Date.now()));
      const controller = typeof AbortController !== "undefined" ? new AbortController() : null;
      const timeoutHandle = controller
        ? window.setTimeout(() => {
          controller.abort();
        }, APP_VERSION_FETCH_TIMEOUT_MS)
        : null;
      const response = await fetch(checkUrl.toString(), {
        cache: "no-store",
        headers: { "Cache-Control": "no-cache" },
        ...(controller ? { signal: controller.signal } : {}),
      }).finally(() => {
        if (timeoutHandle) {
          window.clearTimeout(timeoutHandle);
        }
      });
      if (!response.ok) {
        return "";
      }
      const html = await response.text();
      const match = html.match(/<meta\s+name=["']app-version["']\s+content=["']([^"']+)["']/i);
      return String(match?.[1] || "").trim();
    } catch {
      return "";
    }
  }

  async function clearOutdatedStaticState() {
    if ("serviceWorker" in navigator) {
      try {
        const registrations = await navigator.serviceWorker.getRegistrations();
        await Promise.all(registrations.map((registration) => registration.unregister().catch(() => false)));
      } catch (error) {
        console.warn("Could not clean existing service worker registrations.", error?.message || error);
      }
    }
    if ("caches" in window) {
      try {
        const keys = await caches.keys();
        await Promise.all(
          keys
            .filter((key) => key.startsWith(STATIC_CACHE_PREFIX))
            .map((key) => caches.delete(key)),
        );
      } catch (error) {
        console.warn("Could not clean existing static caches.", error?.message || error);
      }
    }
  }

  async function ensureLatestPublishedVersionOnStartup() {
    const publishedVersion = await fetchPublishedAppVersion();
    if (!publishedVersion || publishedVersion === effectiveAppVersion) {
      clearSessionValue(BOOTSTRAP_RELOAD_TARGET_KEY);
      return false;
    }

    const attemptedVersion = readSessionValue(BOOTSTRAP_RELOAD_TARGET_KEY);
    const currentUrl = new URL(window.location.href);
    const currentTargetVersion = String(currentUrl.searchParams.get("appv") || "").trim();
    if (attemptedVersion === publishedVersion && currentTargetVersion === publishedVersion) {
      return false;
    }

    persistVersionMarker(APP_VERSION_SEEN_KEY, publishedVersion);
    persistVersionMarker(APP_VERSION_FORCED_KEY, publishedVersion);
    try {
      sessionStorage.setItem(BOOTSTRAP_RELOAD_TARGET_KEY, publishedVersion);
    } catch {
      // Ignore storage failures and continue with the reload path.
    }
    await clearOutdatedStaticState();
    currentUrl.searchParams.set("appv", publishedVersion);
    window.location.replace(currentUrl.toString());
    return true;
  }

  function prefetchAppOnIntent() {
    if (appPrefetchTriggered) {
      return;
    }
    appPrefetchTriggered = true;
    ensureAppLoaded().catch(() => {
      appPrefetchTriggered = false;
    });
  }

  function registerServiceWorker() {
    if (!("serviceWorker" in navigator)) {
      return;
    }
    let reloadedForControllerChange = false;
    window.addEventListener("load", () => {
      const currentSwUrl = new URL(`./sw.js${versionSuffix}`, window.location.href).href;
      const currentCacheName = `medbank-static-v${effectiveAppVersion.replaceAll(".", "-") || "runtime"}`;

      navigator.serviceWorker.addEventListener("controllerchange", () => {
        if (reloadedForControllerChange) {
          return;
        }
        reloadedForControllerChange = true;
        window.location.reload();
      });

      navigator.serviceWorker.getRegistrations()
        .then((registrations) => Promise.all(registrations.map(async (registration) => {
          const scriptUrl = registration.active?.scriptURL
            || registration.waiting?.scriptURL
            || registration.installing?.scriptURL
            || "";
          if (scriptUrl && scriptUrl !== currentSwUrl) {
            await registration.unregister();
          }
        })))
        .catch((error) => {
          console.warn("Could not clean old service worker registrations.", error);
        })
        .finally(() => {
          if ("caches" in window) {
            caches.keys()
              .then((keys) => Promise.all(
                keys
                  .filter((key) => key.startsWith("medbank-static-v") && key !== currentCacheName)
                  .map((key) => caches.delete(key)),
              ))
              .catch((error) => {
                console.warn("Could not clean old static caches.", error);
              });
          }

          navigator.serviceWorker.register(`./sw.js${versionSuffix}`)
            .then((registration) => {
              registration.update().catch(() => {});
            })
            .catch((error) => {
              console.error("Service worker registration failed.", error);
            });
        });
    });
  }

  function readPersistedRoute() {
    const hashRoute = readRouteFromHash();
    if (hashRoute) {
      return hashRoute;
    }

    let persistedRoute = "";
    try {
      persistedRoute = String(sessionStorage.getItem(ROUTE_STATE_ROUTE_KEY) || "").trim().toLowerCase();
    } catch {
      persistedRoute = "";
    }
    if (KNOWN_ROUTES.has(persistedRoute)) {
      return persistedRoute;
    }
    try {
      persistedRoute = String(localStorage.getItem(ROUTE_STATE_ROUTE_LOCAL_KEY) || "").trim().toLowerCase();
    } catch {
      persistedRoute = "";
    }
    return KNOWN_ROUTES.has(persistedRoute) ? persistedRoute : "";
  }

  document.addEventListener(
    "click",
    (event) => {
      if (!(event.target instanceof Element)) {
        return;
      }
      const navTarget = event.target.closest("[data-nav]");
      if (!navTarget) {
        return;
      }
      const route = navTarget.getAttribute("data-nav");
      rememberInitialRoute(route);
      ensureAppLoaded({ showBusyUi: true, route }).catch(() => {});
    },
    { capture: true },
  );

  document.addEventListener(
    "pointerover",
    (event) => {
      if (!(event.target instanceof Element)) {
        return;
      }
      const navTarget = event.target.closest('[data-nav="login"], [data-nav="signup"]');
      if (!navTarget) {
        return;
      }
      prefetchAppOnIntent();
    },
    { capture: true },
  );

  document.addEventListener(
    "touchstart",
    (event) => {
      if (!(event.target instanceof Element)) {
        return;
      }
      const navTarget = event.target.closest('[data-nav="login"], [data-nav="signup"]');
      if (!navTarget) {
        return;
      }
      prefetchAppOnIntent();
    },
    { capture: true, passive: true },
  );

  (async () => {
    const redirectedToLatestVersion = await ensureLatestPublishedVersionOnStartup().catch((error) => {
      console.warn("Startup version check failed.", error?.message || error);
      return false;
    });
    if (redirectedToLatestVersion) {
      return;
    }

    const persistedRoute = readPersistedRoute();
    if (persistedRoute && persistedRoute !== "landing") {
      ensureAppLoaded().catch(() => {});
    } else if (hasOAuthCallbackParams() || isGoogleOAuthPendingState()) {
      ensureAppLoaded().catch(() => {});
    } else {
      window.setTimeout(() => {
        prefetchAppOnIntent();
      }, APP_BACKGROUND_PREFETCH_DELAY_MS);
    }

    registerServiceWorker();
  })();
})();
