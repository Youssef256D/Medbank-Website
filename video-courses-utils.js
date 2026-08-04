(function initVideoCoursesUtils(root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  if (root) {
    root.MedBankVideoCourses = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function createVideoCoursesUtils() {
  "use strict";

  const YOUTUBE_VIDEO_ID_PATTERN = /^[A-Za-z0-9_-]{11}$/;
  const YOUTUBE_HOST_PATTERN = /(^|\.)youtube\.com$|(^|\.)youtu\.be$|(^|\.)youtube-nocookie\.com$/i;
  const COUPON_ERROR_MESSAGES = Object.freeze({
    INVALID_COUPON: "That coupon code is not valid. Check the code and try again.",
    COUPON_ALREADY_USED: "That coupon has already been activated.",
    COUPON_EXPIRED: "That coupon has expired.",
    COUPON_DISABLED: "That coupon has been disabled. Please contact support.",
    COURSE_UNAVAILABLE: "That course is not currently available.",
    MODULE_UNAVAILABLE: "One or more modules on this coupon are no longer available.",
    ALREADY_HAS_ACCESS: "Your account already has the access provided by this coupon.",
    UNAUTHORIZED: "Your account is not eligible to activate this coupon.",
    REDEMPTION_FAILED: "The coupon could not be activated. Please try again.",
  });

  function extractYouTubeVideoId(value) {
    const source = String(value || "").trim();
    if (YOUTUBE_VIDEO_ID_PATTERN.test(source)) {
      return source;
    }

    let parsed;
    try {
      parsed = new URL(source);
    } catch {
      return "";
    }
    if (!/^https?:$/.test(parsed.protocol) || !YOUTUBE_HOST_PATTERN.test(parsed.hostname)) {
      return "";
    }

    let candidate = "";
    if (/(^|\.)youtu\.be$/i.test(parsed.hostname)) {
      candidate = parsed.pathname.split("/").filter(Boolean)[0] || "";
    } else if (parsed.pathname === "/watch") {
      candidate = parsed.searchParams.get("v") || "";
    } else {
      const segments = parsed.pathname.split("/").filter(Boolean);
      if (["embed", "shorts", "live"].includes(String(segments[0] || "").toLowerCase())) {
        candidate = segments[1] || "";
      }
    }
    return YOUTUBE_VIDEO_ID_PATTERN.test(candidate) ? candidate : "";
  }

  function buildYouTubeEmbedUrl(videoId) {
    const normalizedId = extractYouTubeVideoId(videoId);
    return normalizedId
      ? `https://www.youtube-nocookie.com/embed/${normalizedId}?rel=0&modestbranding=1`
      : "";
  }

  function normalizeYouTubeVideoInput(value) {
    const originalUrl = String(value || "").trim();
    const videoId = extractYouTubeVideoId(originalUrl);
    return {
      ok: Boolean(videoId),
      videoId,
      originalUrl,
      embedUrl: buildYouTubeEmbedUrl(videoId),
    };
  }

  function normalizeCouponCode(value) {
    const compact = String(value || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (!compact) {
      return "";
    }
    const prefix = compact.startsWith("MBK") ? compact.slice(0, 3) : "";
    const body = prefix ? compact.slice(3) : compact;
    const groups = body.match(/.{1,4}/g) || [];
    return [prefix, ...groups].filter(Boolean).join("-");
  }

  function couponErrorMessage(code) {
    return COUPON_ERROR_MESSAGES[String(code || "").trim().toUpperCase()]
      || COUPON_ERROR_MESSAGES.REDEMPTION_FAILED;
  }

  function resolveCourseAccess(accessRows, courseId) {
    const targetId = String(courseId || "");
    const row = (Array.isArray(accessRows) ? accessRows : []).find(
      (item) => String(item?.course_id || item?.courseId || "") === targetId,
    );
    const scope = row?.access_scope || row?.accessScope || "none";
    return {
      hasAccess: scope === "full" || scope === "partial",
      isFullCourse: scope === "full",
      accessScope: scope,
      accessSource: row?.access_source || row?.accessSource || "",
      moduleIds: new Set(Array.isArray(row?.module_ids || row?.moduleIds) ? (row.module_ids || row.moduleIds).map(String) : []),
    };
  }

  function canAccessModule(accessRows, courseId, moduleId) {
    const access = resolveCourseAccess(accessRows, courseId);
    return access.isFullCourse || access.moduleIds.has(String(moduleId || ""));
  }

  return Object.freeze({
    YOUTUBE_VIDEO_ID_PATTERN,
    extractYouTubeVideoId,
    buildYouTubeEmbedUrl,
    normalizeYouTubeVideoInput,
    normalizeCouponCode,
    couponErrorMessage,
    resolveCourseAccess,
    canAccessModule,
  });
});
