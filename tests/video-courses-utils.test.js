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

const utils = require("../video-courses-utils.js");

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

test("quiz lesson type is matched case-insensitively", () => {
  assert.equal(utils.isQuizLessonType("quiz"), true);
  assert.equal(utils.isQuizLessonType(" Quiz "), true);
  assert.equal(utils.isQuizLessonType("video"), false);
  assert.equal(utils.isQuizLessonType(null), false);
});

test("quiz settings are clamped and default sensibly", () => {
  assert.deepEqual(utils.normalizeQuizSettings({ pass_percent: "150", max_attempts: "", is_required: "on", show_answers: "on" }), {
    pass_percent: 100,
    is_required: true,
    max_attempts: null,
    shuffle_questions: false,
    show_answers: true,
  });
  assert.equal(utils.normalizeQuizSettings({ pass_percent: "abc" }).pass_percent, 70);
  assert.equal(utils.normalizeQuizSettings({ max_attempts: "0" }).max_attempts, 1);
  assert.equal(utils.normalizeQuizSettings({ max_attempts: "3" }).max_attempts, 3);
});

test("a quiz question needs a prompt, two options and exactly one correct answer", () => {
  assert.equal(utils.buildQuizQuestionPayload({ option_1: "a", option_2: "b", correct_option: "1" }).error, "Write the question.");
  assert.equal(utils.buildQuizQuestionPayload({ prompt: "Q", option_1: "a", correct_option: "1" }).error, "Add at least two options.");
  assert.match(utils.buildQuizQuestionPayload({ prompt: "Q", option_1: "a", option_2: "b" }).error, /exactly one/);
  // The mark on a blank option does not count.
  assert.match(utils.buildQuizQuestionPayload({ prompt: "Q", option_1: "a", option_2: "b", correct_option: "3" }).error, /exactly one/);

  const ok = utils.buildQuizQuestionPayload({ prompt: " Q ", option_1: "a", option_3: "c", correct_option: "3", explanation: "" });
  assert.equal(ok.ok, true);
  assert.equal(ok.prompt, "Q");
  assert.equal(ok.explanation, null);
  assert.deepEqual(ok.options, [
    { body: "a", is_correct: false, position: 1 },
    { body: "c", is_correct: true, position: 2 },
  ]);
});

test("quiz server codes map to readable messages", () => {
  assert.match(utils.quizErrorMessage(new Error("quiz_locked")), /Finish the lessons/);
  assert.equal(utils.quizErrorMessage(new Error("something else")), "");
});
