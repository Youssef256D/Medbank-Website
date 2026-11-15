// University + college (program): who may use the MCQ Bank.
//
// Pure helpers shared by main.js and the node tests. The rule itself lives in
// the database (migrations 20260928083023 and 20261116090000_mcq_programs: a
// trigger keeps profiles.mcq_access_enabled aligned with whether the student's
// program offers the MCQ Bank, and private.can_current_user_access_mcq()
// re-checks it). Everything here only mirrors that rule so the UI can explain
// it and hide MCQ entry points early; it is never what grants access.
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

  // Known college labels; custom colleges added in `university_colleges` may
  // use any key matching COLLEGE_KEY_PATTERN and fall back to their program name.
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
  const COLLEGE_KEY_PATTERN = /^[a-z][a-z0-9_]{1,39}$/;
  const MIN_PROGRAM_YEARS = 1;
  const MAX_PROGRAM_YEARS = 7;
  const DEFAULT_PROGRAM_YEARS = 5;
  const MIN_PROGRAM_SEMESTERS = 1;
  const MAX_PROGRAM_SEMESTERS = 3;
  const DEFAULT_PROGRAM_SEMESTERS = 2;
  const MCQ_COLLEGE = "medicine";
  const MCQ_INELIGIBLE_NOTE = "The MCQ Bank is available for Medicine – October 6 University. You'll have full access to Video Courses.";
  const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

  const text = (value) => String(value ?? "").trim();

  function normalizeCollege(value) {
    const college = text(value).toLowerCase();
    return COLLEGE_KEY_PATTERN.test(college) ? college : null;
  }

  function normalizeUniversityId(value) {
    const id = text(value).toLowerCase();
    return UUID_PATTERN.test(id) ? id : null;
  }

  function clampProgramCount(value, min, max, fallback) {
    const num = Number(value);
    return Number.isInteger(num) && num >= min && num <= max ? num : fallback;
  }

  function normalizeProgramRow(row) {
    const id = normalizeUniversityId(row?.program_id ?? row?.id);
    const universityId = normalizeUniversityId(row?.university_id);
    const collegeKey = normalizeCollege(row?.college_key);
    const name = text(row?.name);
    if (!id || !universityId || !collegeKey || !name) return null;
    const sortOrder = Number(row?.sort_order);
    return {
      id,
      program_id: id,
      university_id: universityId,
      college_key: collegeKey,
      name,
      name_ar: text(row?.name_ar) || null,
      years_count: clampProgramCount(row?.years_count, MIN_PROGRAM_YEARS, MAX_PROGRAM_YEARS, DEFAULT_PROGRAM_YEARS),
      semesters_per_year: clampProgramCount(row?.semesters_per_year, MIN_PROGRAM_SEMESTERS, MAX_PROGRAM_SEMESTERS, DEFAULT_PROGRAM_SEMESTERS),
      mcq_bank_available: row?.mcq_bank_available === true,
      is_active: row?.is_active !== false,
      sort_order: Number.isInteger(sortOrder) ? sortOrder : 100,
      created_at: row?.created_at || null,
      updated_at: row?.updated_at || null,
    };
  }

  function sortUniversityColleges(rows = []) {
    return (Array.isArray(rows) ? rows : [])
      .map(normalizeProgramRow)
      .filter(Boolean)
      .sort((a, b) => a.sort_order - b.sort_order
        || a.name.localeCompare(b.name, "en", { sensitivity: "base" })
        || a.id.localeCompare(b.id));
  }

  function findProgram(programs, universityId, college) {
    const uid = normalizeUniversityId(universityId);
    const key = normalizeCollege(college);
    if (!uid || !key || !Array.isArray(programs)) return null;
    return programs.find((entry) => entry
      && normalizeUniversityId(entry.university_id) === uid
      && normalizeCollege(entry.college_key) === key) || null;
  }

  function getProgramTermBounds(program = null) {
    return {
      yearsCount: clampProgramCount(program?.years_count, MIN_PROGRAM_YEARS, MAX_PROGRAM_YEARS, DEFAULT_PROGRAM_YEARS),
      semestersPerYear: clampProgramCount(program?.semesters_per_year, MIN_PROGRAM_SEMESTERS, MAX_PROGRAM_SEMESTERS, DEFAULT_PROGRAM_SEMESTERS),
    };
  }

  function getCollegeLabel(value, programs = null) {
    const college = normalizeCollege(value);
    if (!college) return "";
    const option = COLLEGE_OPTIONS.find((entry) => entry.value === college);
    if (option) return option.label;
    if (Array.isArray(programs)) {
      const matched = programs.find((entry) => normalizeCollege(entry?.college_key) === college && text(entry?.name));
      if (matched) return text(matched.name);
    }
    return college;
  }

  function getProgramsForUniversity(programs, universityId, { includeInactive = false } = {}) {
    const uid = normalizeUniversityId(universityId);
    if (!uid || !Array.isArray(programs)) return [];
    return sortUniversityColleges(programs).filter((entry) => entry.university_id === uid && (includeInactive || entry.is_active));
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
  // what the browser holds (lists not loaded, or the student's university or
  // college is hidden from the public list). Callers must treat null as
  // "defer to the server flag", never as "ineligible".
  function resolveMcqEligibility({ role, universityId, college } = {}, universities = null, programs = null) {
    if (text(role) && text(role) !== "student") return true;
    const normalizedCollege = normalizeCollege(college);
    const normalizedUniversityId = normalizeUniversityId(universityId);
    if (college === null || universityId === null) return false;
    if (!normalizedCollege || !normalizedUniversityId) return null;

    if (Array.isArray(programs) && programs.length > 0) {
      const program = findProgram(programs, normalizedUniversityId, normalizedCollege);
      if (!program) return null;
      const university = findUniversity(universities, normalizedUniversityId);
      if (university) {
        return university.mcq_bank_available === true && program.mcq_bank_available === true;
      }
      return program.mcq_bank_available === true;
    }

    if (normalizedCollege !== MCQ_COLLEGE) return false;
    const university = findUniversity(universities, normalizedUniversityId);
    if (!university) return null;
    return university.mcq_bank_available === true;
  }

  function formatMcqIneligibleNote(programs = null, universities = null, options = {}) {
    const videoHidden = Boolean(options?.videoCoursesHidden);
    const suffix = videoHidden ? "" : " You'll have full access to Video Courses.";
    const activeUniversities = Array.isArray(universities) ? universities : [];
    const normalizedPrograms = sortUniversityColleges(programs);
    const pairs = [];
    const seen = new Set();

    normalizedPrograms.forEach((program) => {
      if (!program.is_active || !program.mcq_bank_available) return;
      const university = findUniversity(activeUniversities, program.university_id);
      if (university && !university.is_active) return;
      if (university && !university.mcq_bank_available) return;
      const universityName = university?.name || "";
      if (!universityName) return;
      const collegeName = program.name || getCollegeLabel(program.college_key, normalizedPrograms);
      const label = `${collegeName} – ${universityName}`;
      if (!seen.has(label)) {
        seen.add(label);
        pairs.push(label);
      }
    });

    if (!pairs.length && activeUniversities.length && !normalizedPrograms.length) {
      activeUniversities
        .filter((entry) => entry && entry.is_active && entry.mcq_bank_available)
        .forEach((entry) => {
          const label = `Medicine – ${entry.name}`;
          if (!seen.has(label)) {
            seen.add(label);
            pairs.push(label);
          }
        });
    }

    if (pairs.length) {
      return `The MCQ Bank is available for ${pairs.join(", ")}.${suffix}`;
    }
    if (normalizedPrograms.length && activeUniversities.length) {
      return `The MCQ Bank is not currently offered for your selected program.${suffix}`;
    }
    return `The MCQ Bank is available for Medicine – October 6 University.${suffix}`;
  }

  function validateUniversityCollegeDraft(draft = {}, { isNew = false } = {}) {
    const errors = [];
    const name = text(draft.name).replace(/\s+/g, " ");
    const nameAr = text(draft.name_ar).replace(/\s+/g, " ");
    const collegeKey = text(draft.college_key).toLowerCase();
    const yearsCount = Number(draft.years_count);
    const semestersPerYear = Number(draft.semesters_per_year);
    const rawSort = draft.sort_order;
    const sortOrder = rawSort === "" || rawSort === null || rawSort === undefined ? 100 : Number(rawSort);

    if (isNew && !COLLEGE_KEY_PATTERN.test(collegeKey)) {
      errors.push("College key must be 2–40 lowercase letters, numbers, or underscores, starting with a letter.");
    }
    if (name.length < 2) errors.push("Enter a college name (at least 2 characters).");
    if (name.length > 160) errors.push("The college name is too long.");
    if (nameAr.length > 160) errors.push("The Arabic name is too long.");
    if (!Number.isInteger(yearsCount) || yearsCount < MIN_PROGRAM_YEARS || yearsCount > MAX_PROGRAM_YEARS) {
      errors.push("Years must be a whole number from 1 to 7.");
    }
    if (!Number.isInteger(semestersPerYear) || semestersPerYear < MIN_PROGRAM_SEMESTERS || semestersPerYear > MAX_PROGRAM_SEMESTERS) {
      errors.push("Semesters per year must be a whole number from 1 to 3.");
    }
    if (!Number.isInteger(sortOrder) || sortOrder < -100000 || sortOrder > 100000) {
      errors.push("Sort order must be a whole number.");
    }

    const payload = {
      name,
      name_ar: nameAr || null,
      years_count: clampProgramCount(yearsCount, MIN_PROGRAM_YEARS, MAX_PROGRAM_YEARS, DEFAULT_PROGRAM_YEARS),
      semesters_per_year: clampProgramCount(semestersPerYear, MIN_PROGRAM_SEMESTERS, MAX_PROGRAM_SEMESTERS, DEFAULT_PROGRAM_SEMESTERS),
      sort_order: Number.isInteger(sortOrder) ? sortOrder : 100,
      is_active: draft.is_active !== false,
      mcq_bank_available: draft.mcq_bank_available === true,
    };
    if (isNew) {
      payload.college_key = collegeKey;
    }

    return {
      ok: errors.length === 0,
      errors,
      payload,
    };
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
  // HTTP 402 from the Supabase gateway: the project is restricted (quota or
  // billing). supabase-js drops the status from the error, so the gateway's
  // message text is the reliable signal.
  function isServiceRestrictedError(error) {
    const status = text(error?.status || error?.statusCode);
    return status === "402"
      || /service for this project is restricted|exceed_\w+_quota/i.test(text(error?.message));
  }

  function describeUniversityError(error, fallback = "Could not save the university. Check your connection and admin session, then retry.") {
    const code = text(error?.code);
    const message = text(error?.message);
    if (isServiceRestrictedError(error)) {
      return "MedBank is temporarily unavailable. Your connection is fine; please try again later.";
    }
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

  // -------------------------------------------------------------------------
  // Auto MCQ access for new students (migration 20260928125817).
  //
  // `app_feature_flags.student_auto_mcq_access`: on, a new eligible student
  // gets the MCQ Bank at once; off, they are created with MCQ off and
  // `profiles.mcq_access_held_at` stamped ("waiting for MCQ activation").
  // Enabling a student's MCQ access clears the hold in the database, and
  // turning the switch back on activates every student still held. A missing
  // flag row reads as off, exactly as private.is_app_feature_enabled does.
  // -------------------------------------------------------------------------
  const AUTO_MCQ_ACCESS_FEATURE_KEY = "student_auto_mcq_access";
  const AUTO_MCQ_ACCESS_FEATURE_DESCRIPTION = "When enabled, new eligible students get MCQ Bank access immediately. When disabled, new accounts wait for an admin to activate MCQ access; turning it back on activates everyone still waiting.";
  const AUTO_MCQ_ACCESS_LABEL = "Auto MCQ access for new students";
  const AUTO_MCQ_ACCESS_OFF_CONFIRM = "New students will get Video Courses only until you activate MCQ access for each of them, or turn this back on.";
  const MCQ_HELD_BADGE_LABEL = "Waiting for MCQ";

  // Friendly names for app_feature_flags keys, for any list of site switches.
  const FEATURE_FLAG_LABELS = Object.freeze({
    student_auto_mcq_access: AUTO_MCQ_ACCESS_LABEL,
    student_auto_approval: "Auto-approve new students",
    courses_coming_soon: "Video Courses: coming soon",
  });

  function getFeatureFlagLabel(featureKey) {
    const key = text(featureKey);
    return FEATURE_FLAG_LABELS[key] || key;
  }

  // An ISO timestamp, or null for anything that is not a real date.
  function normalizeMcqAccessHeldAt(value) {
    if (value === null || value === undefined || text(value) === "") return null;
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date.toISOString();
  }

  // Held = a student with a hold stamp whose MCQ access is still off. The
  // access check keeps a just-activated row from showing the badge in the
  // moment between the write and the re-read.
  function isMcqAccessHeld(account) {
    return text(account?.role) === "student"
      && account?.mcqAccessEnabled === false
      && normalizeMcqAccessHeldAt(account?.mcqAccessHeldAt) !== null;
  }

  function formatMcqHeldSince(value, locale = "en-GB") {
    const iso = normalizeMcqAccessHeldAt(value);
    if (!iso) return "";
    return new Date(iso).toLocaleDateString(locale, { day: "numeric", month: "short", year: "numeric" });
  }

  const pluralStudents = (count) => `${count} student${count === 1 ? "" : "s"}`;
  const normalizeCount = (value) => (Number.isInteger(value) && value >= 0 ? value : null);

  // The one line under the switch. `enabled` null = not read yet / unreadable.
  function describeAutoMcqAccessState(enabled, heldCount = null) {
    const count = normalizeCount(heldCount);
    if (enabled === true) {
      return "On: new Medicine students at a university with the MCQ Bank get MCQ access as soon as they sign up."
        + (count ? ` ${pluralStudents(count)} from before are still waiting; activate them below or turn this off and on again.` : "");
    }
    if (enabled === false) {
      const waiting = count === null ? "" : ` ${count ? `${pluralStudents(count)} waiting now.` : "Nobody is waiting now."}`;
      return `Off: new eligible students get Video Courses only and wait for you to activate MCQ access.${waiting}`;
    }
    return "Checking whether new students get MCQ access automatically…";
  }

  function buildAutoMcqAccessConfirmMessage(nextEnabled, heldCount = null) {
    if (!nextEnabled) {
      return `Turn off ${AUTO_MCQ_ACCESS_LABEL.toLowerCase()}?\n\n${AUTO_MCQ_ACCESS_OFF_CONFIRM}`;
    }
    const count = normalizeCount(heldCount);
    let waiting;
    if (count === null) {
      waiting = "The number of waiting students could not be read. Every student still waiting for MCQ activation will be activated now.";
    } else if (count === 0) {
      waiting = "No students are waiting for MCQ activation right now.";
    } else {
      waiting = `${pluralStudents(count)} waiting for MCQ activation will all be activated now.`;
    }
    return `Turn on ${AUTO_MCQ_ACCESS_LABEL.toLowerCase()}?\n\nNew eligible students will get MCQ access as soon as they sign up.\n\n${waiting}`;
  }

  return Object.freeze({
    AUTO_MCQ_ACCESS_FEATURE_KEY,
    AUTO_MCQ_ACCESS_FEATURE_DESCRIPTION,
    AUTO_MCQ_ACCESS_LABEL,
    AUTO_MCQ_ACCESS_OFF_CONFIRM,
    MCQ_HELD_BADGE_LABEL,
    FEATURE_FLAG_LABELS,
    getFeatureFlagLabel,
    normalizeMcqAccessHeldAt,
    isMcqAccessHeld,
    formatMcqHeldSince,
    describeAutoMcqAccessState,
    buildAutoMcqAccessConfirmMessage,
    COLLEGE_OPTIONS,
    COLLEGE_VALUES,
    COLLEGE_KEY_PATTERN,
    MIN_PROGRAM_YEARS,
    MAX_PROGRAM_YEARS,
    DEFAULT_PROGRAM_YEARS,
    MIN_PROGRAM_SEMESTERS,
    MAX_PROGRAM_SEMESTERS,
    DEFAULT_PROGRAM_SEMESTERS,
    MCQ_COLLEGE,
    MCQ_INELIGIBLE_NOTE,
    normalizeCollege,
    getCollegeLabel,
    normalizeUniversityId,
    normalizeUniversityRow,
    sortUniversities,
    findUniversity,
    normalizeProgramRow,
    sortUniversityColleges,
    findProgram,
    getProgramsForUniversity,
    getProgramTermBounds,
    resolveMcqEligibility,
    formatMcqIneligibleNote,
    validateUniversityDraft,
    validateUniversityCollegeDraft,
    describeUniversityError,
    isServiceRestrictedError,
  });
});
