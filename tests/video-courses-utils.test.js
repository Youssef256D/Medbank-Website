const test = require("node:test");
const assert = require("node:assert/strict");

const {
  extractYouTubeVideoId,
  buildYouTubeEmbedUrl,
  normalizeYouTubeVideoInput,
  normalizeCouponCode,
  couponErrorMessage,
  resolveCourseAccess,
  canAccessModule,
} = require("../video-courses-utils.js");

const VIDEO_ID = "dQw4w9WgXcQ";

test("normalizes supported YouTube URL formats", () => {
  const supported = [
    `https://www.youtube.com/watch?v=${VIDEO_ID}`,
    `https://youtu.be/${VIDEO_ID}?si=test`,
    `https://www.youtube.com/embed/${VIDEO_ID}`,
    `https://www.youtube.com/shorts/${VIDEO_ID}`,
    `https://youtube.com/live/${VIDEO_ID}`,
    `https://www.youtube-nocookie.com/embed/${VIDEO_ID}`,
    VIDEO_ID,
  ];
  for (const source of supported) {
    assert.equal(extractYouTubeVideoId(source), VIDEO_ID, source);
  }
});

test("rejects invalid or non-YouTube video sources", () => {
  const invalid = [
    "",
    "https://example.com/watch?v=dQw4w9WgXcQ",
    "https://youtube.example.com/watch?v=dQw4w9WgXcQ",
    ["java", "script:alert(1)"].join(""),
    "https://youtube.com/watch?v=too-short",
  ];
  for (const source of invalid) {
    assert.equal(extractYouTubeVideoId(source), "", source);
    assert.equal(normalizeYouTubeVideoInput(source).ok, false, source);
  }
});

test("builds only privacy-enhanced embed URLs", () => {
  assert.equal(
    buildYouTubeEmbedUrl(VIDEO_ID),
    `https://www.youtube-nocookie.com/embed/${VIDEO_ID}?rel=0&modestbranding=1`,
  );
  assert.equal(buildYouTubeEmbedUrl("invalid"), "");
});

test("normalizes coupon presentation without changing its logical code", () => {
  assert.equal(
    normalizeCouponCode(" mbk abcd ef23 4567 "),
    "MBK-ABCD-EF23-4567",
  );
  assert.equal(normalizeCouponCode(""), "");
});

test("maps stable coupon errors to safe student messages", () => {
  assert.match(couponErrorMessage("COUPON_EXPIRED"), /expired/i);
  assert.equal(couponErrorMessage("internal database detail"), couponErrorMessage("REDEMPTION_FAILED"));
});

test("resolves full and partial course access consistently", () => {
  const rows = [
    { course_id: "course-a", access_scope: "partial", access_source: "coupon", module_ids: ["module-a"] },
    { course_id: "course-b", access_scope: "full", access_source: "manual", module_ids: [] },
  ];
  assert.deepEqual(
    { ...resolveCourseAccess(rows, "course-a"), moduleIds: [...resolveCourseAccess(rows, "course-a").moduleIds] },
    { hasAccess: true, isFullCourse: false, accessScope: "partial", accessSource: "coupon", moduleIds: ["module-a"] },
  );
  assert.equal(canAccessModule(rows, "course-a", "module-a"), true);
  assert.equal(canAccessModule(rows, "course-a", "module-b"), false);
  assert.equal(canAccessModule(rows, "course-b", "future-module"), true);
});
