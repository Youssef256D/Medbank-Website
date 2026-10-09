import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const TOKEN_PATTERN = /^mba_[A-Za-z0-9_-]{32,128}$/;
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const MAX_TITLE_LENGTH = 160;
const MAX_BODY_LENGTH = 4000;
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const RATE_LIMIT_MAX_REQUESTS = 60;
const AGENT_AUTH_TIMEOUT_MS = 20000;
const AGENT_AUDIT_TIMEOUT_MS = 3000;
const AGENT_ACTION_TIMEOUT_MS = 25000;
const MAX_BULK_IMPORT_QUESTIONS = 100;
const MAX_PROFILE_PHONE_SCAN_ROWS = 5000;
const ACCOUNT_DEACTIVATION_BAN_DURATION = "876000h";
const FULL_ADMIN_PERMISSION = "full_admin";
const rateLimitByAgent = new Map<string, { count: number; startedAt: number }>();

const ACTION_PERMISSIONS: Record<string, string> = {
  get_dashboard_summary: "read_dashboard",
  create_announcement_draft: "draft_announcements",
  request_publish_announcement: "request_content_publish",
};

const FULL_ADMIN_ACTIONS = new Set([
  "get_tool_catalog",
  "list_admin_records",
  "manage_admin_record",
  "bulk_import_mcqs",
  "create_user",
  "update_user_profile",
  "set_user_access",
  "set_user_password",
  "delete_user",
  "read_shared_setting",
  "write_shared_setting",
  "resolve_platform_enrollment_request",
]);

type ResourceSpec = {
  table: string;
  readFields: string[];
  writeFields: string[];
  matchFields: string[];
  conflict?: string;
};

const ADMIN_RESOURCES: Record<string, ResourceSpec> = {
  profiles: {
    table: "profiles",
    readFields: ["id", "full_name", "email", "phone", "role", "approved", "academic_year", "academic_semester", "created_at", "updated_at"],
    writeFields: [],
    matchFields: ["id"],
  },
  user_presence: {
    table: "user_presence",
    readFields: ["user_id", "full_name", "email", "role", "current_route", "is_online", "is_solving", "last_seen_at"],
    writeFields: [],
    matchFields: ["user_id"],
  },
  user_activity_sessions: {
    table: "user_activity_sessions",
    readFields: ["id", "user_id", "session_key", "full_name", "email", "role", "entry_route", "current_route", "exit_route", "page_views", "started_at", "last_seen_at", "ended_at"],
    writeFields: [],
    matchFields: ["id"],
  },
  mcq_courses: {
    table: "courses",
    readFields: ["id", "course_code", "course_name", "academic_year", "academic_semester", "is_active", "created_at", "updated_at"],
    writeFields: ["course_code", "course_name", "academic_year", "academic_semester", "is_active"],
    matchFields: ["id"],
  },
  mcq_topics: {
    table: "course_topics",
    readFields: ["id", "course_id", "topic_name", "sort_order", "is_active", "created_at", "updated_at"],
    writeFields: ["course_id", "topic_name", "sort_order", "is_active"],
    matchFields: ["id"],
  },
  mcq_questions: {
    table: "questions",
    readFields: ["id", "external_id", "course_id", "topic_id", "author_id", "stem", "explanation", "objective", "difficulty", "status", "created_at", "updated_at"],
    writeFields: ["external_id", "course_id", "topic_id", "author_id", "stem", "explanation", "objective", "difficulty", "status"],
    matchFields: ["id"],
    conflict: "external_id",
  },
  mcq_question_choices: {
    table: "question_choices",
    readFields: ["id", "question_id", "choice_label", "choice_text", "is_correct"],
    writeFields: ["question_id", "choice_label", "choice_text", "is_correct"],
    matchFields: ["id"],
  },
  mcq_enrollments: {
    table: "user_course_enrollments",
    readFields: ["user_id", "course_id", "assigned_by", "assigned_at"],
    writeFields: ["user_id", "course_id", "assigned_by"],
    matchFields: ["user_id", "course_id"],
    conflict: "user_id,course_id",
  },
  platform_courses: {
    table: "platform_courses",
    readFields: ["id", "course_code", "course_name", "visibility", "description", "cover_image_url", "intro_video_url", "instructor_name", "instructor_bio", "level", "estimated_duration", "is_active", "is_published", "enrollment_mode", "price", "created_by", "created_at", "updated_at"],
    writeFields: ["course_code", "course_name", "visibility", "description", "cover_image_url", "intro_video_url", "instructor_name", "instructor_bio", "level", "estimated_duration", "is_active", "is_published", "enrollment_mode", "price", "created_by"],
    matchFields: ["id"],
  },
  platform_modules: {
    table: "platform_course_modules",
    readFields: ["id", "course_id", "title", "description", "position", "is_published", "created_at", "updated_at"],
    writeFields: ["course_id", "title", "description", "position", "is_published"],
    matchFields: ["id"],
  },
  platform_lessons: {
    table: "platform_course_lessons",
    readFields: ["id", "course_id", "module_id", "title", "description", "lesson_type", "video_url", "video_provider", "duration_seconds", "content_html", "position", "is_free_preview", "is_published", "created_at", "updated_at"],
    writeFields: ["course_id", "module_id", "title", "description", "lesson_type", "video_url", "video_provider", "duration_seconds", "content_html", "position", "is_free_preview", "is_published"],
    matchFields: ["id"],
  },
  platform_resources: {
    table: "platform_course_resources",
    readFields: ["id", "course_id", "module_id", "lesson_id", "title", "resource_type", "file_url", "external_url", "description", "position", "is_published", "created_at"],
    writeFields: ["course_id", "module_id", "lesson_id", "title", "resource_type", "file_url", "external_url", "description", "position", "is_published"],
    matchFields: ["id"],
  },
  platform_announcements: {
    table: "platform_course_announcements",
    readFields: ["id", "course_id", "title", "body", "is_published", "created_by", "created_at"],
    writeFields: ["course_id", "title", "body", "is_published", "created_by"],
    matchFields: ["id"],
  },
  platform_suggestions: {
    table: "platform_course_suggestions",
    readFields: ["id", "course_id", "target_organization_id", "title", "reason", "priority", "is_active", "starts_at", "ends_at", "created_by", "created_at", "updated_at"],
    writeFields: ["course_id", "target_organization_id", "title", "reason", "priority", "is_active", "starts_at", "ends_at", "created_by"],
    matchFields: ["id"],
  },
  platform_enrollments: {
    table: "platform_course_enrollments",
    readFields: ["user_id", "course_id", "assigned_by", "assigned_at"],
    writeFields: ["user_id", "course_id", "assigned_by"],
    matchFields: ["user_id", "course_id"],
    conflict: "user_id,course_id",
  },
  platform_enrollment_requests: {
    table: "platform_course_enrollment_requests",
    readFields: ["id", "user_id", "course_id", "status", "created_at", "updated_at"],
    writeFields: ["user_id", "course_id", "status"],
    matchFields: ["id"],
  },
  notifications: {
    table: "notifications",
    readFields: ["id", "external_id", "recipient_user_id", "title", "message", "created_by", "created_by_name", "is_active", "created_at", "updated_at"],
    writeFields: ["external_id", "recipient_user_id", "title", "message", "created_by", "created_by_name", "is_active"],
    matchFields: ["id"],
    conflict: "external_id",
  },
  feature_flags: {
    table: "app_feature_flags",
    readFields: ["feature_key", "enabled", "description", "updated_by", "created_at", "updated_at"],
    writeFields: ["feature_key", "enabled", "description", "updated_by"],
    matchFields: ["feature_key"],
    conflict: "feature_key",
  },
  agents: {
    table: "admin_agents",
    readFields: ["id", "name", "description", "status", "token_hint", "last_used_at", "created_at", "updated_at"],
    writeFields: [],
    matchFields: ["id"],
  },
  agent_permissions: {
    table: "admin_agent_permissions",
    readFields: ["agent_id", "permission_key", "created_by", "created_at"],
    writeFields: [],
    matchFields: ["agent_id", "permission_key"],
    conflict: "agent_id,permission_key",
  },
};

const SHARED_SETTINGS: Record<string, string> = {
  site_maintenance: "g:mcq_site_maintenance",
  auto_approve_student_access: "g:mcq_auto_approve_student_access",
  student_refresh_trigger: "g:mcq_student_refresh_trigger",
  course_notebook_links: "g:mcq_course_notebook_links",
  course_topic_groups: "g:mcq_course_topic_groups",
  topic_new_catalog: "g:mcq_topic_new_catalog",
  invites: "g:mcq_invites",
  feedback: "g:mcq_feedback",
  system_logs: "g:mcq_system_logs",
};

function parseAllowedOrigins(): string[] {
  const configured = String(Deno.env.get("ALLOWED_ORIGIN") || "https://youssef256d.github.io")
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry && entry !== "*");
  return configured.length ? configured : ["https://youssef256d.github.io"];
}

function buildCorsHeaders(requestOrigin: string): HeadersInit {
  const configured = parseAllowedOrigins();
  // CORS never returns "*": parseAllowedOrigins() strips "*" and guarantees a non-empty allowlist.
  const origin = configured.includes(requestOrigin) ? requestOrigin : configured[0];
  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, X-Agent-Token, apikey, x-client-info",
    "Vary": "Origin",
  };
}

function jsonResponse(status: number, payload: unknown, requestOrigin = ""): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "X-Content-Type-Options": "nosniff",
      "X-Frame-Options": "DENY",
      "Cache-Control": "no-store",
      ...buildCorsHeaders(requestOrigin),
    },
  });
}

function readAgentToken(req: Request): string {
  const headerToken = String(req.headers.get("x-agent-token") || "").trim();
  if (headerToken) return headerToken;
  const authorization = String(req.headers.get("authorization") || "").trim();
  return authorization.toLowerCase().startsWith("bearer ")
    ? authorization.slice("bearer ".length).trim()
    : "";
}

function isUuid(value: unknown): boolean {
  return UUID_PATTERN.test(String(value || "").trim());
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function assertPayloadSize(value: unknown): void {
  if (JSON.stringify(value ?? null).length > 120000) {
    throw new Error("Payload is too large.");
  }
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
  return Array.from(new Uint8Array(digest))
    .map((entry) => entry.toString(16).padStart(2, "0"))
    .join("");
}

function withTimeout<T>(promise: PromiseLike<T>, timeoutMs: number, message: string): Promise<T> {
  let timeoutId: number | undefined;
  const timeoutPromise = new Promise<T>((_, reject) => {
    timeoutId = setTimeout(() => reject(new Error(message)), timeoutMs);
  });
  return Promise.race([Promise.resolve(promise), timeoutPromise]).finally(() => {
    if (timeoutId !== undefined) clearTimeout(timeoutId);
  });
}

function isTimeoutMessage(message: string): boolean {
  return /timed out|timeout/i.test(message);
}

async function logAction(
  adminClient: ReturnType<typeof createClient>,
  agentId: string | null,
  actionKey: string,
  actionStatus: string,
  requestPayload: Record<string, unknown>,
  responseSummary: Record<string, unknown>,
) {
  try {
    const { error } = await withTimeout(
      adminClient.from("admin_agent_action_log").insert({
        agent_id: agentId,
        action_key: actionKey,
        action_status: actionStatus,
        request_payload: requestPayload,
        response_summary: responseSummary,
      }),
      AGENT_AUDIT_TIMEOUT_MS,
      "Agent audit insert timed out.",
    );
    if (error) console.error("Agent audit insert failed.", error.message);
  } catch (error) {
    console.error("Agent audit insert failed.", error instanceof Error ? error.message : error);
  }
}

function isRateLimited(agentId: string): boolean {
  const now = Date.now();
  const current = rateLimitByAgent.get(agentId);
  if (!current || now - current.startedAt > RATE_LIMIT_WINDOW_MS) {
    rateLimitByAgent.set(agentId, { count: 1, startedAt: now });
    return false;
  }
  current.count += 1;
  return current.count > RATE_LIMIT_MAX_REQUESTS;
}

function summarizeRequestPayload(action: string, input: Record<string, unknown>): Record<string, unknown> {
  if (action === "set_user_password") {
    return { targetUserId: String(input.targetUserId || "").trim(), passwordChanged: true };
  }
  if (action === "manage_admin_record") {
    return {
      resource: String(input.resource || "").trim(),
      operation: String(input.operation || "").trim(),
      match: asRecord(input.match),
    };
  }
  if (action === "bulk_import_mcqs") {
    const records = Array.isArray(input.records) ? input.records : [];
    return {
      recordCount: records.length,
      importAsDraft: input.importAsDraft !== false,
      createMissingTopics: input.createMissingTopics !== false,
      defaultCourseId: String(input.defaultCourseId || "").trim() || undefined,
      defaultCourse: String(input.defaultCourse || "").trim() || undefined,
      externalIds: records.slice(0, 20).map((row) => {
        const record = asRecord(row);
        return String(record.externalId || record.external_id || "").trim();
      }).filter(Boolean),
    };
  }
  if (action === "write_shared_setting") {
    return { setting: String(input.setting || "").trim() };
  }
  const safe = { ...input };
  delete safe.password;
  assertPayloadSize(safe);
  return safe;
}

function pickFields(
  raw: unknown,
  allowed: string[],
  label: string,
): Record<string, unknown> {
  const data = asRecord(raw);
  const invalid = Object.keys(data).filter((key) => !allowed.includes(key));
  if (invalid.length) {
    throw new Error(`${label} contains unsupported field(s): ${invalid.join(", ")}.`);
  }
  return Object.fromEntries(Object.entries(data).filter(([key]) => allowed.includes(key)));
}

function validateRecordInput(resource: string, record: Record<string, unknown>): void {
  assertPayloadSize(record);
  if (resource === "mcq_questions" && "status" in record && !["draft", "published", "archived"].includes(String(record.status))) {
    throw new Error("Question status must be draft, published, or archived.");
  }
  if (resource === "platform_enrollment_requests" && "status" in record && !["pending", "approved", "rejected"].includes(String(record.status))) {
    throw new Error("Request status must be pending, approved, or rejected.");
  }
  if (resource === "platform_courses" && "enrollment_mode" in record && !["assigned", "request"].includes(String(record.enrollment_mode))) {
    throw new Error("Course enrollment mode must be assigned or request.");
  }
  if (resource === "agent_permissions" && "permission_key" in record && ![
    "read_dashboard",
    "manage_content_drafts",
    "request_content_publish",
    "review_enrollments",
    "draft_announcements",
    FULL_ADMIN_PERMISSION,
  ].includes(String(record.permission_key))) {
    throw new Error("Unknown agent permission.");
  }
  if (resource === "notifications") {
    if ("title" in record && String(record.title || "").trim().length > MAX_TITLE_LENGTH) throw new Error("Notification title is too long.");
    if ("message" in record && String(record.message || "").trim().length > MAX_BODY_LENGTH) throw new Error("Notification message is too long.");
  }
}

function applyExactMatch(query: any, match: Record<string, unknown>): any {
  let nextQuery = query;
  Object.entries(match).forEach(([key, value]) => {
    nextQuery = value === null ? nextQuery.is(key, null) : nextQuery.eq(key, value);
  });
  return nextQuery;
}

function normalizePhoneDigits(value: unknown): string {
  const digits = String(value || "").replace(/\D+/g, "");
  return digits.startsWith("00") ? digits.slice(2) : digits;
}

function buildPhoneLookupKeys(value: unknown): Set<string> {
  const digits = normalizePhoneDigits(value);
  const keys = new Set<string>();
  if (!digits) return keys;
  keys.add(digits);

  if (digits.startsWith("20") && digits.length === 12 && digits[2] === "1") {
    keys.add(`0${digits.slice(2)}`);
    keys.add(`0020${digits.slice(2)}`);
  } else if (digits.startsWith("0") && digits.length === 11 && digits[1] === "1") {
    keys.add(`20${digits.slice(1)}`);
    keys.add(`0020${digits.slice(1)}`);
  } else if (digits.length === 10 && digits[0] === "1") {
    keys.add(`0${digits}`);
    keys.add(`20${digits}`);
    keys.add(`0020${digits}`);
  }

  return keys;
}

function phoneValuesMatch(storedPhone: unknown, searchPhone: unknown): boolean {
  const storedKeys = buildPhoneLookupKeys(storedPhone);
  const searchKeys = buildPhoneLookupKeys(searchPhone);
  if (!storedKeys.size || !searchKeys.size) return false;
  for (const key of searchKeys) {
    if (storedKeys.has(key)) return true;
  }

  const storedDigits = normalizePhoneDigits(storedPhone);
  const searchDigits = normalizePhoneDigits(searchPhone);
  return storedDigits.length >= 8
    && searchDigits.length >= 8
    && (storedDigits.endsWith(searchDigits) || searchDigits.endsWith(storedDigits));
}

function buildRequiredMatch(spec: ResourceSpec, raw: unknown): Record<string, unknown> {
  const match = pickFields(raw, spec.matchFields, "match");
  const missing = spec.matchFields.filter((key) => !(key in match) || String(match[key] ?? "").trim() === "");
  if (missing.length) {
    throw new Error(`match must include ${spec.matchFields.join(" and ")}.`);
  }
  return match;
}

async function listAdminRecords(adminClient: ReturnType<typeof createClient>, input: Record<string, unknown>) {
  const resource = String(input.resource || "").trim();
  const spec = ADMIN_RESOURCES[resource];
  if (!spec) throw new Error("Unknown admin resource.");
  const rawFilters = pickFields(input.filters, [...new Set([...spec.readFields, ...spec.matchFields])], "filters");
  const filters = { ...rawFilters };
  const shouldNormalizePhoneFilter = resource === "profiles"
    && Object.prototype.hasOwnProperty.call(filters, "phone")
    && filters.phone !== null
    && normalizePhoneDigits(filters.phone).length > 0;
  const phoneFilter = shouldNormalizePhoneFilter
    ? filters.phone
    : undefined;
  if (shouldNormalizePhoneFilter) {
    delete filters.phone;
  }
  const limit = Math.min(Math.max(Number(input.limit) || 25, 1), 100);
  const orderBy = String(input.orderBy || "").trim();

  if (phoneFilter !== undefined) {
    const rows: any[] = [];
    for (let offset = 0; offset < MAX_PROFILE_PHONE_SCAN_ROWS && rows.length < limit; offset += 1000) {
      let pageQuery: any = adminClient
        .from(spec.table)
        .select(spec.readFields.join(","))
        .range(offset, Math.min(offset + 999, MAX_PROFILE_PHONE_SCAN_ROWS - 1));
      pageQuery = applyExactMatch(pageQuery, filters);
      if (orderBy && spec.readFields.includes(orderBy)) {
        pageQuery = pageQuery.order(orderBy, { ascending: input.ascending === true });
      }
      const { data, error } = await pageQuery;
      if (error) throw error;
      const pageRows = Array.isArray(data) ? data : [];
      rows.push(...pageRows.filter((row) => phoneValuesMatch(row?.phone, phoneFilter)).slice(0, limit - rows.length));
      if (pageRows.length < 1000) break;
    }
    return { resource, rows };
  }

  let query: any = adminClient.from(spec.table).select(spec.readFields.join(",")).limit(limit);
  query = applyExactMatch(query, filters);
  if (orderBy && spec.readFields.includes(orderBy)) {
    query = query.order(orderBy, { ascending: input.ascending === true });
  }
  const { data, error } = await query;
  if (error) throw error;
  return { resource, rows: Array.isArray(data) ? data : [] };
}

async function manageAdminRecord(adminClient: ReturnType<typeof createClient>, input: Record<string, unknown>) {
  const resource = String(input.resource || "").trim();
  const operation = String(input.operation || "").trim();
  const spec = ADMIN_RESOURCES[resource];
  if (!spec || !spec.writeFields.length) throw new Error("This resource cannot be modified through the agent.");
  if (!["insert", "upsert", "update", "delete"].includes(operation)) throw new Error("Operation must be insert, upsert, update, or delete.");
  if (operation === "insert" || operation === "upsert") {
    const record = pickFields(input.record, spec.writeFields, "record");
    if (!Object.keys(record).length) throw new Error("record is required.");
    validateRecordInput(resource, record);
    let query: any = operation === "upsert"
      ? adminClient.from(spec.table).upsert(record, spec.conflict ? { onConflict: spec.conflict, defaultToNull: false } : undefined)
      : adminClient.from(spec.table).insert(record);
    const { data, error } = await query.select(spec.readFields.join(",")).limit(1);
    if (error) throw error;
    return { resource, operation, rows: data || [] };
  }
  const match = buildRequiredMatch(spec, input.match);
  if (operation === "delete") {
    const { data, error } = await applyExactMatch(adminClient.from(spec.table).delete(), match).select(spec.readFields.join(","));
    if (error) throw error;
    return { resource, operation, rows: data || [] };
  }
  const changes = pickFields(input.changes, spec.writeFields, "changes");
  if (!Object.keys(changes).length) throw new Error("changes is required.");
  validateRecordInput(resource, changes);
  const { data, error } = await applyExactMatch(adminClient.from(spec.table).update(changes), match).select(spec.readFields.join(","));
  if (error) throw error;
  return { resource, operation, rows: data || [] };
}

function normalizeBulkDifficulty(value: unknown): number {
  if ([1, 2, 3].includes(Number(value))) return Number(value);
  const normalized = String(value || "").trim().toLowerCase();
  if (normalized === "easy") return 1;
  if (normalized === "hard") return 3;
  return 2;
}

function normalizeBulkCorrectLabels(value: unknown): Set<string> {
  const tokens = Array.isArray(value) ? value : String(value || "").split(/[\s,|;/]+/);
  const numberedLabels: Record<string, string> = { "1": "A", "2": "B", "3": "C", "4": "D", "5": "E" };
  return new Set(tokens.map((token) => {
    const label = String(token || "").trim().toUpperCase().replace(/[^A-Z0-9]/g, "");
    return numberedLabels[label] || label;
  }).filter((label) => /^[A-E]$/.test(label)));
}

function normalizeBulkChoices(record: Record<string, unknown>): Array<{ choice_label: string; choice_text: string; is_correct: boolean }> {
  const rawChoices = Array.isArray(record.choices) ? record.choices : [];
  const choiceTextByLabel = new Map<string, string>();
  const markedCorrect = new Set<string>();

  rawChoices.forEach((rawChoice, index) => {
    const choice = asRecord(rawChoice);
    const fallbackLabel = ["A", "B", "C", "D", "E"][index] || "";
    const label = String(choice.label || choice.id || fallbackLabel).trim().toUpperCase();
    const text = String(choice.text || choice.choice_text || rawChoice || "").trim();
    if (/^[A-E]$/.test(label) && text) {
      choiceTextByLabel.set(label, text);
      if (choice.isCorrect === true || choice.is_correct === true) markedCorrect.add(label);
    }
  });

  ["A", "B", "C", "D", "E"].forEach((label) => {
    const text = String(record[`choice${label}`] || record[`choice_${label.toLowerCase()}`] || "").trim();
    if (text) choiceTextByLabel.set(label, text);
  });
  const correctLabels = normalizeBulkCorrectLabels(record.correct ?? record.correctAnswer ?? record.correct_answer);
  markedCorrect.forEach((label) => correctLabels.add(label));

  if (choiceTextByLabel.size < 2) throw new Error("At least two non-empty choices are required.");
  if (!correctLabels.size) throw new Error("At least one correct answer label is required.");
  if ([...correctLabels].some((label) => !choiceTextByLabel.has(label))) {
    throw new Error("Correct answer labels must refer to provided choices.");
  }

  return ["A", "B", "C", "D", "E"]
    .filter((label) => choiceTextByLabel.has(label))
    .map((label) => ({
      choice_label: label,
      choice_text: choiceTextByLabel.get(label) || "",
      is_correct: correctLabels.has(label),
    }));
}

async function bulkImportMcqs(adminClient: ReturnType<typeof createClient>, input: Record<string, unknown>) {
  const rawRecords = Array.isArray(input.records) ? input.records : [];
  if (!rawRecords.length) throw new Error("Provide records with at least one MCQ row.");
  if (rawRecords.length > MAX_BULK_IMPORT_QUESTIONS) {
    throw new Error(`Import a maximum of ${MAX_BULK_IMPORT_QUESTIONS} questions per request.`);
  }
  assertPayloadSize(rawRecords);

  const importAsDraft = input.importAsDraft !== false;
  const createMissingTopics = input.createMissingTopics !== false;
  const defaultCourseId = String(input.defaultCourseId || "").trim();
  const defaultCourse = String(input.defaultCourse || "").trim();
  const defaultTopicId = String(input.defaultTopicId || "").trim();
  const defaultTopic = String(input.defaultTopic || "").trim();
  const errors: Array<{ row: number; externalId?: string; error: string }> = [];
  const normalizedRows: Array<{
    row: number;
    externalId: string;
    courseId: string;
    course: string;
    topicId: string;
    topic: string;
    stem: string;
    explanation: string;
    objective: string | null;
    difficulty: number;
    status: string;
    choices: Array<{ choice_label: string; choice_text: string; is_correct: boolean }>;
  }> = [];
  const seenExternalIds = new Set<string>();

  rawRecords.forEach((rawRecord, index) => {
    const rowNumber = index + 1;
    const record = asRecord(rawRecord);
    const externalId = String(record.externalId || record.external_id || "").trim();
    try {
      if (!externalId || externalId.length > 180) throw new Error("externalId is required and must be 180 characters or fewer.");
      if (seenExternalIds.has(externalId)) throw new Error("externalId is duplicated in this import batch.");
      seenExternalIds.add(externalId);
      const stem = String(record.stem || record.question || "").trim();
      if (!stem) throw new Error("stem is required.");
      const requestedStatus = String(record.status || (importAsDraft ? "draft" : "published")).trim().toLowerCase();
      if (!["draft", "published", "archived"].includes(requestedStatus)) {
        throw new Error("status must be draft, published, or archived.");
      }
      normalizedRows.push({
        row: rowNumber,
        externalId,
        courseId: String(record.courseId || record.course_id || defaultCourseId).trim(),
        course: String(record.course || record.courseName || defaultCourse).trim(),
        topicId: String(record.topicId || record.topic_id || defaultTopicId).trim(),
        topic: String(record.topic || record.topicName || defaultTopic).trim(),
        stem,
        explanation: String(record.explanation || "").trim() || "No explanation provided.",
        objective: String(record.objective || "").trim() || null,
        difficulty: normalizeBulkDifficulty(record.difficulty),
        status: importAsDraft ? "draft" : requestedStatus,
        choices: normalizeBulkChoices(record),
      });
    } catch (error) {
      errors.push({ row: rowNumber, externalId: externalId || undefined, error: String(error instanceof Error ? error.message : error) });
    }
  });

  const { data: courses, error: courseError } = await adminClient
    .from("courses")
    .select("id,course_name,is_active");
  if (courseError) throw courseError;
  const courseById = new Map((courses || []).map((course) => [String(course.id), course]));
  const coursesByName = new Map<string, any[]>();
  (courses || []).forEach((course) => {
    const key = String(course.course_name || "").trim().toLowerCase();
    coursesByName.set(key, [...(coursesByName.get(key) || []), course]);
  });

  const courseResolvedRows = normalizedRows.flatMap((record) => {
    let course = record.courseId ? courseById.get(record.courseId) : null;
    if (!course && record.course) {
      const matches = coursesByName.get(record.course.toLowerCase()) || [];
      if (matches.length === 1) course = matches[0];
      if (matches.length > 1) {
        errors.push({ row: record.row, externalId: record.externalId, error: "Course name is not unique. Supply courseId." });
        return [];
      }
    }
    if (!course) {
      errors.push({ row: record.row, externalId: record.externalId, error: "A matching courseId or exact course name is required." });
      return [];
    }
    return [{ ...record, courseId: String(course.id), course: String(course.course_name) }];
  });
  const relevantCourseIds = [...new Set(courseResolvedRows.map((record) => record.courseId))];
  const { data: topics, error: topicError } = relevantCourseIds.length
    ? await adminClient.from("course_topics").select("id,course_id,topic_name").in("course_id", relevantCourseIds)
    : { data: [], error: null };
  if (topicError) throw topicError;
  const topicById = new Map((topics || []).map((topic) => [String(topic.id), topic]));
  const topicByCourseAndName = new Map(
    (topics || []).map((topic) => [`${topic.course_id}::${String(topic.topic_name || "").trim().toLowerCase()}`, topic]),
  );
  const createdTopics: Array<{ id: string; courseId: string; topic: string }> = [];
  const readyRows: typeof courseResolvedRows = [];

  for (const record of courseResolvedRows) {
    try {
      let topic = record.topicId ? topicById.get(record.topicId) : null;
      if (topic && String(topic.course_id) !== record.courseId) {
        throw new Error("topicId does not belong to the selected course.");
      }
      const topicName = record.topic.trim();
      if (!topic && topicName) {
        topic = topicByCourseAndName.get(`${record.courseId}::${topicName.toLowerCase()}`) || null;
      }
      if (!topic && topicName && createMissingTopics) {
        const { data: created, error: createTopicError } = await adminClient.from("course_topics").insert({
          course_id: record.courseId,
          topic_name: topicName,
          sort_order: 999,
          is_active: true,
        }).select("id,course_id,topic_name").single();
        if (createTopicError) throw createTopicError;
        topic = created;
        topicById.set(String(created.id), created);
        topicByCourseAndName.set(`${record.courseId}::${String(created.topic_name).trim().toLowerCase()}`, created);
        createdTopics.push({ id: String(created.id), courseId: record.courseId, topic: String(created.topic_name) });
      }
      if (!topic) throw new Error("A matching topicId or topic name is required.");
      readyRows.push({ ...record, topicId: String(topic.id), topic: String(topic.topic_name) });
    } catch (error) {
      errors.push({ row: record.row, externalId: record.externalId, error: String(error instanceof Error ? error.message : error) });
    }
  }

  const imported: Array<{ externalId: string; id: string; course: string; topic: string; status: string }> = [];
  for (const record of readyRows) {
    try {
      const { data: question, error: questionError } = await adminClient.from("questions").upsert({
        external_id: record.externalId,
        course_id: record.courseId,
        topic_id: record.topicId,
        stem: record.stem,
        explanation: record.explanation,
        objective: record.objective,
        difficulty: record.difficulty,
        status: record.status,
      }, { onConflict: "external_id", defaultToNull: false }).select("id,external_id,status").single();
      if (questionError || !question?.id) throw questionError || new Error("Question could not be saved.");
      const { error: removeChoicesError } = await adminClient.from("question_choices").delete().eq("question_id", question.id);
      if (removeChoicesError) throw removeChoicesError;
      const { error: choiceError } = await adminClient.from("question_choices").insert(
        record.choices.map((choice) => ({ ...choice, question_id: question.id })),
      );
      if (choiceError) throw choiceError;
      imported.push({
        externalId: record.externalId,
        id: String(question.id),
        course: record.course,
        topic: record.topic,
        status: record.status,
      });
    } catch (error) {
      errors.push({ row: record.row, externalId: record.externalId, error: String(error instanceof Error ? error.message : error) });
    }
  }

  return {
    requested: rawRecords.length,
    imported: imported.length,
    failed: errors.length,
    importAsDraft,
    createdTopics,
    questions: imported,
    errors,
  };
}

async function getDashboardSummary(adminClient: ReturnType<typeof createClient>) {
  const [courses, requests, students, questions, platformCourses] = await Promise.all([
    adminClient.from("courses").select("id", { count: "exact", head: true }),
    adminClient.from("platform_course_enrollment_requests").select("id", { count: "exact", head: true }).eq("status", "pending"),
    adminClient.from("profiles").select("id", { count: "exact", head: true }).eq("role", "student"),
    adminClient.from("questions").select("id", { count: "exact", head: true }),
    adminClient.from("platform_courses").select("id", { count: "exact", head: true }),
  ]);
  return {
    mcqCourses: courses.count || 0,
    platformCourses: platformCourses.count || 0,
    questions: questions.count || 0,
    pendingEnrollmentRequests: requests.count || 0,
    students: students.count || 0,
  };
}

async function executeAdminAction(
  adminClient: ReturnType<typeof createClient>,
  agent: { id: string; name: string },
  action: string,
  input: Record<string, unknown>,
) {
  if (action === "get_tool_catalog") {
    return {
      scopedActions: Object.keys(ACTION_PERMISSIONS),
      fullAdminActions: [...FULL_ADMIN_ACTIONS],
      resources: Object.keys(ADMIN_RESOURCES),
      sharedSettings: Object.keys(SHARED_SETTINGS),
      bulkImportMcqs: {
        action: "bulk_import_mcqs",
        maxRecordsPerRequest: MAX_BULK_IMPORT_QUESTIONS,
        behavior: "Imports structured MCQ records directly into the question bank. Defaults to draft visibility and creates missing topics unless disabled.",
        requiredPerRecord: ["externalId", "stem", "correct", "choiceA", "choiceB"],
        identifyCourseAndTopicWith: ["courseId or exact course name", "topicId or topic name"],
        optionalInput: ["defaultCourseId", "defaultCourse", "defaultTopicId", "defaultTopic", "importAsDraft", "createMissingTopics"],
        publishRule: "Set input.importAsDraft to false and record.status to published only when publication is intended.",
      },
    };
  }
  if (action === "get_dashboard_summary") {
    return await getDashboardSummary(adminClient);
  }
  if (action === "list_admin_records") {
    return await listAdminRecords(adminClient, input);
  }
  if (action === "manage_admin_record") {
    return await manageAdminRecord(adminClient, input);
  }
  if (action === "bulk_import_mcqs") {
    return await bulkImportMcqs(adminClient, input);
  }
  if (action === "create_user") {
    const email = String(input.email || "").trim().toLowerCase();
    const password = String(input.password || "");
    const fullName = String(input.fullName || "").trim();
    const role = String(input.role || "student").trim();
    const approved = input.approved === true;
    if (!email || !fullName || password.length < 6 || password.length > 128 || !["student", "admin"].includes(role)) {
      throw new Error("Provide email, fullName, a password between 6 and 128 characters, and role student or admin.");
    }
    const { data: authData, error: authError } = await adminClient.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: { full_name: fullName },
    });
    if (authError || !authData.user?.id) throw authError || new Error("User account could not be created.");
    const profileId = authData.user.id;
    const { data: profile, error: profileError } = await adminClient.from("profiles").upsert({
      id: profileId,
      full_name: fullName,
      email,
      role,
      approved,
      phone: String(input.phone || "").trim() || null,
      academic_year: input.academicYear ?? null,
      academic_semester: input.academicSemester ?? null,
    }, { onConflict: "id", defaultToNull: false }).select("id,full_name,email,role,approved").single();
    if (profileError) throw profileError;
    if (!approved) {
      const { error: banError } = await adminClient.auth.admin.updateUserById(profileId, {
        ban_duration: ACCOUNT_DEACTIVATION_BAN_DURATION,
      });
      if (banError) throw banError;
    }
    return { profile };
  }
  if (action === "update_user_profile") {
    const targetUserId = String(input.targetUserId || "").trim();
    if (!isUuid(targetUserId)) throw new Error("targetUserId must be a valid UUID.");
    const changes = pickFields(input.changes, ["full_name", "phone", "role", "approved", "academic_year", "academic_semester"], "changes");
    if ("role" in changes && !["student", "admin"].includes(String(changes.role))) throw new Error("Role must be student or admin.");
    const { data, error } = await adminClient.from("profiles").update(changes).eq("id", targetUserId).select("id,full_name,email,role,approved,academic_year,academic_semester").maybeSingle();
    if (error) throw error;
    return { profile: data };
  }
  if (action === "set_user_access") {
    const targetUserId = String(input.targetUserId || "").trim();
    const approved = input.approved;
    if (!isUuid(targetUserId) || typeof approved !== "boolean") throw new Error("Provide targetUserId and approved.");
    const { data: profile, error: profileError } = await adminClient.from("profiles").update({ approved }).eq("id", targetUserId).select("id,role,approved").maybeSingle();
    if (profileError) throw profileError;
    const { error: authError } = await adminClient.auth.admin.updateUserById(targetUserId, {
      ban_duration: approved ? "none" : ACCOUNT_DEACTIVATION_BAN_DURATION,
    });
    if (authError) throw authError;
    return { profile, accessEnabled: approved };
  }
  if (action === "set_user_password") {
    const targetUserId = String(input.targetUserId || "").trim();
    const password = String(input.password || "");
    if (!isUuid(targetUserId) || password.length < 6 || password.length > 128) throw new Error("Provide a valid targetUserId and password between 6 and 128 characters.");
    const { error } = await adminClient.auth.admin.updateUserById(targetUserId, { password });
    if (error) throw error;
    return { targetUserId, passwordChanged: true };
  }
  if (action === "delete_user") {
    const targetUserId = String(input.targetUserId || "").trim();
    if (!isUuid(targetUserId) || String(input.confirm || "") !== "DELETE_USER") throw new Error("Provide targetUserId and confirm DELETE_USER.");
    const { data: target } = await adminClient.from("profiles").select("role,approved").eq("id", targetUserId).maybeSingle();
    if (target?.role === "admin" && String(input.confirmAdmin || "") !== "DELETE_ADMIN_USER") {
      throw new Error("Deleting an admin also requires confirmAdmin DELETE_ADMIN_USER.");
    }
    const { error } = await adminClient.auth.admin.deleteUser(targetUserId);
    if (error && !/not found/i.test(String(error.message || ""))) throw error;
    return { targetUserId, deleted: true };
  }
  if (action === "read_shared_setting") {
    const setting = String(input.setting || "").trim();
    const storageKey = SHARED_SETTINGS[setting];
    if (!storageKey) throw new Error("Unknown shared setting.");
    const { data, error } = await adminClient.from("app_state").select("storage_key,payload,updated_at").eq("storage_key", storageKey).maybeSingle();
    if (error) throw error;
    return { setting, row: data };
  }
  if (action === "write_shared_setting") {
    const setting = String(input.setting || "").trim();
    const storageKey = SHARED_SETTINGS[setting];
    if (!storageKey) throw new Error("Unknown shared setting.");
    if (input.payload === undefined || input.payload === null) throw new Error("payload is required.");
    assertPayloadSize(input.payload);
    const { data, error } = await adminClient.from("app_state").upsert({
      storage_key: storageKey,
      payload: input.payload ?? null,
      updated_at: new Date().toISOString(),
    }, { onConflict: "storage_key", defaultToNull: false }).select("storage_key,updated_at").single();
    if (error) throw error;
    return { setting, updatedAt: data.updated_at };
  }
  if (action === "resolve_platform_enrollment_request") {
    const requestId = String(input.requestId || "").trim();
    const status = String(input.status || "").trim();
    if (!isUuid(requestId) || !["approved", "rejected"].includes(status)) throw new Error("Provide requestId and status approved or rejected.");
    const { data: request, error: findError } = await adminClient.from("platform_course_enrollment_requests").select("id,user_id,course_id,status").eq("id", requestId).maybeSingle();
    if (findError || !request) throw findError || new Error("Enrollment request not found.");
    const { error: updateError } = await adminClient.from("platform_course_enrollment_requests").update({ status }).eq("id", requestId);
    if (updateError) throw updateError;
    if (status === "approved") {
      const { error: enrollError } = await adminClient.from("platform_course_enrollments").upsert({
        user_id: request.user_id,
        course_id: request.course_id,
      }, { onConflict: "user_id,course_id", defaultToNull: false });
      if (enrollError) throw enrollError;
    }
    return { requestId, status };
  }
  if (action === "create_announcement_draft") {
    const courseId = String(input.courseId || "").trim();
    const title = String(input.title || "").trim();
    const body = String(input.body || "").trim();
    if (!isUuid(courseId) || !title || title.length > MAX_TITLE_LENGTH || !body || body.length > MAX_BODY_LENGTH) {
      throw new Error("Provide a courseId, a short title, and body text under 4000 characters.");
    }
    const { data, error } = await adminClient.from("platform_course_announcements").insert({
      course_id: courseId,
      title,
      body,
      is_published: false,
    }).select("id,course_id,title,is_published,created_at").single();
    if (error) throw error;
    return data;
  }
  const announcementId = String(input.announcementId || "").trim();
  if (!isUuid(announcementId)) throw new Error("announcementId is required.");
  const { data: draft, error: draftError } = await adminClient.from("platform_course_announcements")
    .select("id,course_id,title,body,is_published").eq("id", announcementId).maybeSingle();
  if (draftError || !draft || draft.is_published) throw new Error("Only an existing unpublished announcement can be submitted for approval.");
  const { data, error } = await adminClient.from("admin_agent_approval_requests").insert({
    agent_id: agent.id,
    action_key: action,
    request_payload: { announcementId, courseId: draft.course_id, title: draft.title, body: draft.body },
    reason: String(input.reason || "").trim() || null,
  }).select("id,status,created_at").single();
  if (error) throw error;
  return { approvalRequired: true, approval: data };
}

Deno.serve(async (req) => {
  const requestOrigin = String(req.headers.get("origin") || "").trim();
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: buildCorsHeaders(requestOrigin) });
  if (req.method !== "POST") return jsonResponse(405, { ok: false, error: "Method not allowed." }, requestOrigin);

  const supabaseUrl = String(Deno.env.get("SUPABASE_URL") || "").trim().replace(/\/+$/, "");
  const serviceRoleKey = String(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "").trim();
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse(500, { ok: false, error: "Agent service is not configured." }, requestOrigin);

  const token = readAgentToken(req);
  if (!TOKEN_PATTERN.test(token)) return jsonResponse(401, { ok: false, error: "Invalid agent token." }, requestOrigin);

  let body: { action?: string; input?: Record<string, unknown> } = {};
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { ok: false, error: "Invalid JSON payload." }, requestOrigin);
  }
  const action = String(body.action || "").trim();
  const input = asRecord(body.input);
  const auditInput = summarizeRequestPayload(action, input);
  if (!ACTION_PERMISSIONS[action] && !FULL_ADMIN_ACTIONS.has(action)) {
    return jsonResponse(400, { ok: false, error: "Unknown agent action." }, requestOrigin);
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const tokenHash = await sha256Hex(token);
  let agent: { id: string; name: string; status: string } | null = null;
  let permissionRows: Array<{ permission_key: string }> = [];
  let rawAgent: Record<string, unknown> | null = null;

  const envTokenHash = String(Deno.env.get("HERMES_AGENT_TOKEN_HASH") || "").trim().toLowerCase();
  const envAgentId = String(Deno.env.get("HERMES_AGENT_ID") || "").trim();
  if (envTokenHash && envTokenHash === tokenHash && isUuid(envAgentId)) {
    agent = {
      id: envAgentId,
      name: String(Deno.env.get("HERMES_AGENT_NAME") || "Hermes Admin Assistant").trim() || "Hermes Admin Assistant",
      status: "active",
    };
    permissionRows = [
      { permission_key: FULL_ADMIN_PERMISSION },
      { permission_key: "read_dashboard" },
      { permission_key: "draft_announcements" },
      { permission_key: "request_content_publish" },
    ];
  } else {
    try {
      const agentResult = await withTimeout(
        adminClient
          .from("admin_agents")
          .select("id,name,status,admin_agent_permissions(permission_key)")
          .eq("token_hash", tokenHash)
          .maybeSingle(),
        AGENT_AUTH_TIMEOUT_MS,
        "Agent authorization check timed out.",
      );
      if (agentResult.error) {
        console.error("Agent authorization lookup failed.", agentResult.error.message);
        return jsonResponse(503, { ok: false, error: "Agent authorization is temporarily unavailable. Try again shortly." }, requestOrigin);
      }
      rawAgent = agentResult.data as Record<string, unknown> | null;
      agent = rawAgent
        ? {
          id: String(rawAgent.id || ""),
          name: String(rawAgent.name || ""),
          status: String(rawAgent.status || ""),
        }
        : null;
    } catch (error) {
      const message = String(error instanceof Error ? error.message : error || "").trim();
      console.error("Agent authorization check failed.", message);
      return jsonResponse(503, {
        ok: false,
        error: isTimeoutMessage(message)
          ? "Agent authorization timed out. Try again shortly."
          : "Agent authorization is temporarily unavailable. Try again shortly.",
      }, requestOrigin);
    }
    permissionRows = Array.isArray(rawAgent?.admin_agent_permissions)
      ? rawAgent.admin_agent_permissions as Array<{ permission_key: string }>
      : [];
  }
  if (!agent || agent.status !== "active") {
    return jsonResponse(401, {
      ok: false,
      error: "Agent is not authorized. Rotate the Hermes token in the admin dashboard and update Hermes with the new token.",
    }, requestOrigin);
  }
  if (isRateLimited(agent.id)) {
    void logAction(adminClient, agent.id, action, "denied", auditInput, { error: "Rate limit exceeded." });
    return jsonResponse(429, { ok: false, error: "Agent request limit reached. Try again shortly." }, requestOrigin);
  }

  const permissions = new Set((permissionRows || []).map((row) => String(row.permission_key || "")));
  const authorized = permissions.has(FULL_ADMIN_PERMISSION) || (
    Boolean(ACTION_PERMISSIONS[action]) && permissions.has(ACTION_PERMISSIONS[action])
  );
  if (!authorized) {
    void logAction(adminClient, agent.id, action, "denied", auditInput, { error: "Missing permission." });
    return jsonResponse(403, { ok: false, error: "Agent is not permitted to perform this action." }, requestOrigin);
  }

  void withTimeout(
    adminClient.from("admin_agents").update({ last_used_at: new Date().toISOString() }).eq("id", agent.id),
    AGENT_AUDIT_TIMEOUT_MS,
    "Agent last-used update timed out.",
  ).catch((error) => {
    console.error("Agent last-used update failed.", error instanceof Error ? error.message : error);
  });
  try {
    const result = await withTimeout(
      executeAdminAction(adminClient, agent, action, input),
      AGENT_ACTION_TIMEOUT_MS,
      "Agent action timed out before completion.",
    );
    const status = action === "request_publish_announcement" ? "approval_requested" : "success";
    void logAction(adminClient, agent.id, action, status, auditInput, {
      resource: String(input.resource || "").trim() || undefined,
      successful: true,
    });
    return jsonResponse(action === "request_publish_announcement" ? 202 : 200, { ok: true, agent: agent.name, result }, requestOrigin);
  } catch (error) {
    const message = String(error instanceof Error ? error.message : error || "").trim() || "Agent action failed.";
    const status = isTimeoutMessage(message) ? 504 : 400;
    void logAction(adminClient, agent.id, action, "failed", auditInput, { error: message });
    return jsonResponse(status, { ok: false, error: message }, requestOrigin);
  }
});
