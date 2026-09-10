(function initAppPopupsUtils(root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  if (root) {
    root.MedBankAppPopups = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function createAppPopupsUtils() {
  "use strict";

  const POPUP_TARGET_ROUTES = Object.freeze([
    "app-launcher", "dashboard", "create-test", "analytics", "video-courses", "profile", "notifications",
  ]);
  const POPUP_AUDIENCE_ROLES = Object.freeze(["all", "student", "creator", "admin"]);
  const POPUP_DISPLAY_RULES = Object.freeze(["once", "daily", "every_launch"]);
  const text = (value) => String(value ?? "").trim();
  function normalizePopupTargetRoute(value) {
    const route = text(value).toLowerCase();
    return POPUP_TARGET_ROUTES.includes(route) ? route : null;
  }
  function resolvePopupCampaignState(popup, now = Date.now()) {
    if (!popup?.is_active) return "Inactive";
    const time = new Date(now).getTime();
    if (popup.ends_at && new Date(popup.ends_at).getTime() <= time) return "Ended";
    if (popup.starts_at && new Date(popup.starts_at).getTime() > time) return "Scheduled";
    return "Live";
  }
  function validatePopupCampaign(popup = {}) {
    const errors = [];
    const route = normalizePopupTargetRoute(popup.target_route);
    if (!text(popup.title)) errors.push("Title is required, including for image-only adverts.");
    if (text(popup.target_route) && !route) errors.push("Choose a supported pop-up destination.");
    if (popup.image_fills_card && !text(popup.image_url)) errors.push("An image is required when it fills the card.");
    if (text(popup.image_url) && !/^https:\/\//i.test(text(popup.image_url))) errors.push("The image must have a public HTTPS URL.");
    if (route !== "create-test" && (text(popup.target_mcq_subject) || text(popup.target_mcq_topic))) errors.push("MCQ subject and topic only apply to Create test.");
    if (text(popup.target_mcq_topic) && !text(popup.target_mcq_subject)) errors.push("Choose a subject before choosing a topic.");
    if (route !== "video-courses" && text(popup.target_video_course_id)) errors.push("A video course only applies to Video Courses.");
    if (!POPUP_AUDIENCE_ROLES.includes(popup.audience_role)) errors.push("Choose a valid audience role.");
    if (!POPUP_DISPLAY_RULES.includes(popup.display_rule)) errors.push("Choose a valid display rule.");
    if (popup.audience_academic_year != null && (!Number.isInteger(popup.audience_academic_year) || popup.audience_academic_year < 1 || popup.audience_academic_year > 5)) errors.push("Academic year must be between 1 and 5, or any year.");
    if (!Number.isInteger(popup.priority) || popup.priority < -2147483648 || popup.priority > 2147483647) errors.push("Priority must be a whole number within the database integer range.");
    for (const key of ["starts_at", "ends_at"]) {
      if (popup[key] && !Number.isFinite(Date.parse(popup[key]))) errors.push("Choose valid start and end dates.");
    }
    if (popup.starts_at && popup.ends_at && Date.parse(popup.ends_at) <= Date.parse(popup.starts_at)) errors.push("End must be after start.");
    return { ok: errors.length === 0, errors };
  }
  function aggregatePopupPerformance(rows = []) {
    const totals = Object.create(null);
    for (const row of rows) {
      const metric = totals[row.popup_id] ||= { shown: 0, dismissed: 0, tapped: 0, tapThroughRate: 0 };
      if (Number(row.seen_count) > 0) metric.shown += 1;
      if (row.dismissed_at) metric.dismissed += 1;
      if (row.clicked_at) metric.tapped += 1;
    }
    for (const metric of Object.values(totals)) {
      metric.tapThroughRate = metric.shown ? metric.tapped / metric.shown * 100 : 0;
    }
    return totals;
  }
  return Object.freeze({ POPUP_TARGET_ROUTES, POPUP_AUDIENCE_ROLES, POPUP_DISPLAY_RULES,
    normalizePopupTargetRoute, resolvePopupCampaignState, validatePopupCampaign, aggregatePopupPerformance });
});
