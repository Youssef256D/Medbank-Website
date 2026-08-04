import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function allowedOrigins(): string[] {
  const values = String(Deno.env.get("ALLOWED_ORIGIN") || "https://youssef256d.github.io")
    .split(",").map((value) => value.trim()).filter((value) => value && value !== "*");
  return values.length ? values : ["https://youssef256d.github.io"];
}

function cors(origin: string): HeadersInit {
  const values = allowedOrigins();
  return {
    "Access-Control-Allow-Origin": origin && values.includes(origin) ? origin : values[0],
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, apikey, x-client-info",
    Vary: "Origin",
  };
}

function json(status: number, payload: unknown, origin: string): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff", ...cors(origin) },
  });
}

function bearer(value: string): string {
  const raw = String(value || "").trim();
  return raw.toLowerCase().startsWith("bearer ") ? raw.slice(7).trim() : "";
}

function parseStorageSource(value: string): { bucket: string; path: string } | null {
  const raw = String(value || "").trim();
  const match = raw.match(/^supabase-storage:\/\/([^/]+)\/(.+)$/i);
  if (!match) return null;
  try {
    return { bucket: decodeURIComponent(match[1]), path: match[2].split("/").map(decodeURIComponent).join("/") };
  } catch {
    return null;
  }
}

Deno.serve(async (request) => {
  const origin = String(request.headers.get("origin") || "").trim();
  if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: cors(origin) });
  if (request.method !== "POST") return json(405, { ok: false, code: "METHOD_NOT_ALLOWED" }, origin);

  const supabaseUrl = String(Deno.env.get("SUPABASE_URL") || "").trim();
  const serviceRoleKey = String(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "").trim();
  const token = bearer(request.headers.get("authorization") || "");
  if (!supabaseUrl || !serviceRoleKey) return json(500, { ok: false, code: "SERVER_CONFIGURATION_ERROR" }, origin);
  if (!token) return json(401, { ok: false, code: "UNAUTHORIZED" }, origin);

  let body: { lessonId?: string } = {};
  try { body = await request.json(); } catch { return json(400, { ok: false, code: "INVALID_REQUEST" }, origin); }
  const lessonId = String(body.lessonId || "").trim();
  if (!UUID_PATTERN.test(lessonId)) return json(400, { ok: false, code: "INVALID_LESSON" }, origin);

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const { data: actorData, error: actorError } = await admin.auth.getUser(token);
  const actorId = String(actorData?.user?.id || "").trim();
  if (actorError || !UUID_PATTERN.test(actorId)) return json(401, { ok: false, code: "UNAUTHORIZED" }, origin);

  const [{ data: profile }, { data: lesson }] = await Promise.all([
    admin.from("profiles").select("id,role,approved,courses_access_enabled").eq("id", actorId).maybeSingle(),
    admin.from("platform_course_lessons").select("id,course_id,module_id,video_url,video_provider,is_published,is_free_preview,platform_courses!inner(is_active,is_published),platform_course_modules!inner(is_published)").eq("id", lessonId).maybeSingle(),
  ]);
  if (!profile || !lesson) return json(404, { ok: false, code: "LESSON_UNAVAILABLE" }, origin);

  const role = String(profile.role || "").toLowerCase();
  const course = Array.isArray(lesson.platform_courses) ? lesson.platform_courses[0] : lesson.platform_courses;
  const module = Array.isArray(lesson.platform_course_modules) ? lesson.platform_course_modules[0] : lesson.platform_course_modules;
  let authorized = role === "admin";
  if (!authorized && role === "student" && profile.approved === true && profile.courses_access_enabled === true
    && lesson.is_published === true && course?.is_active === true && course?.is_published === true && module?.is_published === true) {
    if (lesson.is_free_preview === true) {
      authorized = true;
    } else {
      const [{ data: full }, { data: entitlement }] = await Promise.all([
        admin.from("platform_course_enrollments").select("course_id").eq("user_id", actorId).eq("course_id", lesson.course_id).eq("access_scope", "full").maybeSingle(),
        admin.from("platform_course_module_entitlements").select("module_id").eq("user_id", actorId).eq("module_id", lesson.module_id).maybeSingle(),
      ]);
      authorized = Boolean(full || entitlement);
    }
  }
  if (!authorized) return json(403, { ok: false, code: "LESSON_ACCESS_DENIED" }, origin);

  const source = parseStorageSource(String(lesson.video_url || ""));
  if (!source || String(lesson.video_provider || "") !== "supabase_storage") {
    return json(400, { ok: false, code: "VIDEO_SOURCE_UNAVAILABLE" }, origin);
  }
  const { data: signed, error: signedError } = await admin.storage.from(source.bucket).createSignedUrl(source.path, 3600);
  if (signedError || !signed?.signedUrl) return json(502, { ok: false, code: "VIDEO_URL_FAILED" }, origin);
  return json(200, { ok: true, signedUrl: signed.signedUrl, expiresInSeconds: 3600 }, origin);
});
