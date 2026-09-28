// University + college: who may use the MCQ Bank.
//
// Pure helpers shared by main.js and the node tests. The rule itself lives in
// the database (migration 20260928083023: a trigger keeps
// profiles.mcq_access_enabled false for ineligible students, and
// private.can_current_user_access_mcq() re-checks it). Everything here only
// mirrors that rule so the UI can explain it and hide MCQ entry points; it is
// never what grants access.
(function initUniversitiesUtils(root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) {
    module.exports = api;
  }
  if (root) {
    root.MedBankUniversities = api;
  }
})(typeof globalThis !== "undefined" ? globalThis : this, function createUniversitiesUtils() {
  "use strict";

  // Must match the profiles_college_ck CHECK constraint exactly.
  const COLLEGE_OPTIONS = Object.freeze([
    Object.freeze({ value: "medicine", label: "Medicine" }),
    Object.freeze({ value: "dentistry", label: "Dentistry" }),
    Object.freeze({ value: "pharmacy", label: "Pharmacy" }),
    Object.freeze({ value: "nursing", label: "Nursing" }),
    Object.freeze({ value: "physical_therapy", label: "Physical Therapy" }),
    Object.freeze({ value: "applied_health_sciences", label: "Applied Health Sciences" }),
    Object.freeze({ value: "other", label: "Other" }),
  ]);
  const COLLEGE_VALUES = Object.freeze(COLLEGE_OPTIONS.map((entry) => entry.value));
  const MCQ_COLLEGE = "medicine";
  const MCQ_INELIGIBLE_NOTE = "The MCQ Bank is available for Medicine students at October 6 University. You'll have full access to Video Courses.";
  const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  const text = (value) => String(value ?? "").trim();

  function normalizeCollege(value) {
    const college = text(value).toLowerCase();
    return COLLEGE_VALUES.includes(college) ? college : null;
  }

  function getCollegeLabel(value) {
    const college = normalizeCollege(value);
    const option = COLLEGE_OPTIONS.find((entry) => entry.value === college);
    return option ? option.label : "";
  }

  function normalizeUniversityId(value) {
    const id = text(value).toLowerCase();
    return UUID_PATTERN.test(id) ? id : null;
  }

  function normalizeUniversityRow(row) {
    const id = normalizeUniversityId(row?.id);
    const name = text(row?.name);
    if (!id || !name) return null;
    const sortOrder = Number(row?.sort_order);
    return {
      id,
      name,
      name_ar: text(row?.name_ar) || null,
      mcq_bank_available: row?.mcq_bank_available === true,
      is_active: row?.is_active !== false,
      sort_order: Number.isInteger(sortOrder) ? sortOrder : 100,
      created_at: row?.created_at || null,
      updated_at: row?.updated_at || null,
    };
  }

  // Same order the sign-up list is read in: sort_order, then name.
  function sortUniversities(rows = []) {
    return (Array.isArray(rows) ? rows : [])
      .map(normalizeUniversityRow)
      .filter(Boolean)
      .sort((a, b) => a.sort_order - b.sort_order
        || a.name.localeCompare(b.name, "en", { sensitivity: "base" })
        || a.id.localeCompare(b.id));
  }

  function findUniversity(universities, universityId) {
    const id = normalizeUniversityId(universityId);
    if (!id || !Array.isArray(universities)) return null;
    return universities.find((entry) => entry && entry.id === id) || null;
  }

  // true / false when the answer is known, null when it cannot be decided from
  // what the browser holds (university list not loaded, or the student's
  // university is hidden from the public list). Callers must treat null as
  // "defer to the server flag", never as "ineligible".
  function resolveMcqEligibility({ role, universityId, college } = {}, universities = null) {
    if (text(role) && text(role) !== "student") return true;
    const normalizedCollege = normalizeCollege(college);
    if (normalizedCollege && normalizedCollege !== MCQ_COLLEGE) return false;
    const normalizedUniversityId = normalizeUniversityId(universityId);
    if (college === null || universityId === null) return false;
    if (!normalizedCollege || !normalizedUniversityId) return null;
    const university = findUniversity(universities, normalizedUniversityId);
    if (!university) return null;
    return university.mcq_bank_available === true;
  }

  function validateUniversityDraft(draft = {}) {
    const errors = [];
    const name = text(draft.name).replace(/\s+/g, " ");
    const nameAr = text(draft.name_ar).replace(/\s+/g, " ");
    const rawSort = draft.sort_order;
    const sortOrder = rawSort === "" || rawSort === null || rawSort === undefined ? 100 : Number(rawSort);
    if (name.length < 2) errors.push("Enter a university name (at least 2 characters).");
    if (name.length > 160) errors.push("The university name is too long.");
    if (nameAr.length > 160) errors.push("The Arabic name is too long.");
    if (!Number.isInteger(sortOrder) || sortOrder < -100000 || sortOrder > 100000) {
      errors.push("Sort order must be a whole number.");
    }
    return {
      ok: errors.length === 0,
      errors,
      payload: {
        name,
        name_ar: nameAr || null,
        sort_order: Number.isInteger(sortOrder) ? sortOrder : 100,
        is_active: draft.is_active !== false,
        mcq_bank_available: draft.mcq_bank_available === true,
      },
    };
  }

  // Friendly wording for the Postgres errors the universities/profile writes
  // can raise. Raw database text is never shown.
  function describeUniversityError(error, fallback = "Could not save the university. Check your connection and admin session, then retry.") {
    const code = text(error?.code);
    const message = text(error?.message);
    if (code === "23503") {
      return "This university still has students, so it cannot be deleted. Hide it from sign-up instead.";
    }
    if (code === "23505") {
      return "A university with this name already exists.";
    }
    if (/UNIVERSITY_NOT_AVAILABLE/.test(message)) {
      return "That university is no longer available. Refresh the page and choose another one.";
    }
    if (code === "23514") {
      return "The university or college value was rejected. Refresh the page and try again.";
    }
    if (code === "42501" || /row-level security|permission denied/i.test(message)) {
      return "You don't have permission to make this change.";
    }
    if (code === "42P01" || code === "PGRST205") {
      return "The universities table is not available yet.";
    }
    return fallback;
  }

  return Object.freeze({
    COLLEGE_OPTIONS,
    COLLEGE_VALUES,
    MCQ_COLLEGE,
    MCQ_INELIGIBLE_NOTE,
    normalizeCollege,
    getCollegeLabel,
    normalizeUniversityId,
    normalizeUniversityRow,
    sortUniversities,
    findUniversity,
    resolveMcqEligibility,
    validateUniversityDraft,
    describeUniversityError,
  });
});
