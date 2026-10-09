const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("node:crypto");
const fs = require("node:fs");
const vm = require("node:vm");

const mainSource = fs.readFileSync("main.js", "utf8");
const configSource = fs.readFileSync("supabase.config.js", "utf8");
const indexSource = fs.readFileSync("index.html", "utf8");

function topLevelFunction(name) {
  const start = mainSource.indexOf(`\nfunction ${name}(`);
  const end = mainSource.indexOf("\n}\n", start);
  assert.ok(start >= 0 && end > start, `main.js function moved: ${name}`);
  return `${mainSource.slice(start, end)}\n}\n`;
}

test("videoCoursesVisible defaults to hidden only when explicitly false", () => {
  let currentUser = null;
  const context = vm.createContext({
    window: { __SUPABASE_CONFIG: { videoCoursesVisible: false } },
    getCurrentUser: () => currentUser,
  });
  vm.runInContext(topLevelFunction("isVideoCoursesHidden"), context);

  assert.equal(context.isVideoCoursesHidden(), true);
  currentUser = { role: "student" };
  assert.equal(context.isVideoCoursesHidden(), true);
  currentUser = { role: "creator" };
  assert.equal(context.isVideoCoursesHidden(), true);
  currentUser = { role: "admin" };
  assert.equal(context.isVideoCoursesHidden(), false);

  context.window.__SUPABASE_CONFIG.videoCoursesVisible = true;
  assert.equal(context.isVideoCoursesHidden({ role: "student" }), false);
  delete context.window.__SUPABASE_CONFIG.videoCoursesVisible;
  assert.equal(context.isVideoCoursesHidden({ role: "student" }), false);
});

test("the shipped config and first paint hide public Video Courses surfaces", () => {
  assert.match(configSource, /videoCoursesVisible:\s*false/);
  assert.doesNotMatch(indexSource, /data-nav="courses-platform"/);
  assert.doesNotMatch(indexSource, /id="landing-courses-platform"/);
  assert.doesNotMatch(indexSource, /screen-05-video-courses/);
  assert.doesNotMatch(indexSource, />Video learning</);
  assert.doesNotMatch(indexSource, /continue video courses/i);
  assert.doesNotMatch(indexSource, /Video Courses/);
  assert.match(indexSource, /MedBank \| Medical MCQ Bank &amp; Mobile App/);
  assert.match(indexSource, /app-version" content="\d{4}-\d{2}-\d{2}\.\d{2}"/);
});

test("hidden landing and mobile renderers omit course marketing", () => {
  const context = vm.createContext({
    GOOGLE_PLAY_APP_URL: "https://example.test/app",
    getCurrentUser: () => null,
    isVideoCoursesHidden: () => true,
    landingMobileAppsSectionHtml: () => "mobile",
    landingMcqBankSectionHtml: () => "mcq",
    landingCoursesSectionHtml: () => "COURSES_MARKER",
    landingContactSectionHtml: () => "contact",
  });
  vm.runInContext(
    topLevelFunction("landingMobileAppsSectionHtml") + topLevelFunction("renderLanding"),
    context,
  );

  const landing = context.renderLanding();
  assert.match(landing, /A medical MCQ bank/);
  assert.match(landing, /once an admin approves them/);
  assert.doesNotMatch(landing, /COURSES_MARKER|landing-courses-platform|Video Courses/);

  const mobile = context.landingMobileAppsSectionHtml();
  assert.doesNotMatch(mobile, /screen-05-video-courses|Video learning|continue video courses/i);
  assert.match(mobile, /explore all five screens/);
});

test("student routes, actions, data loading, and realtime use the visibility guard", () => {
  assert.match(mainSource, /state\.route === "video-courses" && isVideoCoursesHidden\(user\)/);
  assert.match(mainSource, /isVideoCoursesHidden\(\) && String\(action\)\.startsWith\("courses-"\)/);
  assert.match(mainSource, /async function loadStudentCoursesWithProgress[\s\S]*?isVideoCoursesHidden\(user\)/);
  assert.match(mainSource, /async function loadCoursesComingSoonFlag[\s\S]*?isVideoCoursesHidden\(\)/);
  assert.match(mainSource, /function ensureVideoCourseRealtimeSubscription[\s\S]*?isVideoCoursesHidden\(currentUser\)/);
  assert.match(mainSource, /const ADMIN_COURSES_PLATFORM_PAGE = "video-courses"/);
  assert.match(mainSource, /id: "video-courses",\s*label: "Video Courses"/);
});

test("every inline script body still has a matching CSP hash", () => {
  const withoutComments = indexSource.replace(/<!--[\s\S]*?-->/g, "");
  const scriptBodies = [...withoutComments.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)]
    .map((match) => match[1]);
  assert.ok(scriptBodies.length > 0);
  scriptBodies.forEach((body) => {
    const digest = crypto.createHash("sha256").update(body).digest("base64");
    assert.match(indexSource, new RegExp(`sha256-${digest.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}`));
  });
});
