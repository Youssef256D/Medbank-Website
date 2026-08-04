import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

function isUuid(value: string): boolean {
  return UUID_PATTERN.test(String(value || "").trim());
}

function parseAllowedOrigins(): string[] {
  const configured = String(Deno.env.get("ALLOWED_ORIGIN") || "https://youssef256d.github.io")
    .split(",")
    .map((entry) => entry.trim())
    .filter((entry) => entry && entry !== "*");
  return configured.length ? configured : ["https://youssef256d.github.io"];
}

function buildCorsHeaders(requestOrigin: string): HeadersInit {
  const configured = parseAllowedOrigins();
  const base: Record<string, string> = {
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, apikey, x-client-info",
  };
  // CORS never returns "*": parseAllowedOrigins() strips "*" and guarantees a non-empty allowlist.
  if (requestOrigin && configured.includes(requestOrigin)) {
    return { ...base, "Access-Control-Allow-Origin": requestOrigin, "Vary": "Origin" };
  }
  return { ...base, "Access-Control-Allow-Origin": configured[0], "Vary": "Origin" };
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

function parseBearerToken(authHeader: string): string {
  const value = String(authHeader || "").trim();
  if (!value.toLowerCase().startsWith("bearer ")) return "";
  return value.slice("bearer ".length).trim();
}

function parseCloudflareStreamUid(value: string): string {
  const raw = String(value || "").trim();
  if (/^cloudflare-stream:\/\//i.test(raw)) {
    try {
      const parsed = new URL(raw);
      return String(parsed.hostname || parsed.pathname.replace(/^\/+/, "") || "").trim();
    } catch {
      return "";
    }
  }
  const match = raw.match(/(?:cloudflarestream\.com|videodelivery\.net)\/([a-zA-Z0-9_-]{16,})/);
  return String(match?.[1] || "").trim();
}

Deno.serve(async (req) => {
  const requestOrigin = String(req.headers.get("origin") || "").trim();

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: buildCorsHeaders(requestOrigin) });
  }

  if (req.method !== "POST") {
    return jsonResponse(405, { ok: false, error: "Method not allowed." }, requestOrigin);
  }

  const supabaseUrl = String(Deno.env.get("SUPABASE_URL") || "").trim().replace(/\/+$/, "");
  const serviceRoleKey = String(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "").trim();
  const cloudflareAccountId = String(Deno.env.get("CLOUDFLARE_ACCOUNT_ID") || "").trim();
  const cloudflareApiToken = String(Deno.env.get("CLOUDFLARE_STREAM_API_TOKEN") || Deno.env.get("CLOUDFLARE_API_TOKEN") || "").trim();
  const customerCode = String(Deno.env.get("CLOUDFLARE_STREAM_CUSTOMER_CODE") || "").trim();

  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse(500, { ok: false, error: "Server configuration is missing Supabase secrets." }, requestOrigin);
  }
  if (!cloudflareAccountId || !cloudflareApiToken || !customerCode) {
    return jsonResponse(500, { ok: false, error: "Cloudflare Stream playback is not configured yet." }, requestOrigin);
  }

  const accessToken = parseBearerToken(req.headers.get("authorization") || "");
  if (!accessToken) {
    return jsonResponse(401, { ok: false, error: "Missing bearer token." }, requestOrigin);
  }

  let body: { lessonId?: string } = {};
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { ok: false, error: "Invalid JSON payload." }, requestOrigin);
  }

  const lessonId = String(body?.lessonId || "").trim();
  if (!isUuid(lessonId)) {
    return jsonResponse(400, { ok: false, error: "lessonId must be a valid UUID." }, requestOrigin);
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: actorData, error: actorError } = await adminClient.auth.getUser(accessToken);
  const actorId = String(actorData?.user?.id || "").trim();
  if (actorError || !isUuid(actorId)) {
    return jsonResponse(401, { ok: false, error: "Unauthorized. Log in again and retry." }, requestOrigin);
  }

  const { data: actorProfile, error: profileError } = await adminClient
    .from("profiles")
    .select("id,role,approved,academic_year,academic_semester")
    .eq("id", actorId)
    .maybeSingle();
  if (profileError || !actorProfile) {
    return jsonResponse(403, { ok: false, error: "Could not verify account access." }, requestOrigin);
  }

  const { data: lesson, error: lessonError } = await adminClient
    .from("platform_course_lessons")
    .select("id,course_id,module_id,title,video_url,is_published,is_free_preview")
    .eq("id", lessonId)
    .maybeSingle();
  if (lessonError || !lesson) {
    return jsonResponse(404, { ok: false, error: "Lesson video was not found." }, requestOrigin);
  }

  const videoUid = parseCloudflareStreamUid(String(lesson.video_url || ""));
  if (!videoUid) {
    return jsonResponse(400, { ok: false, error: "This lesson is not linked to a Cloudflare Stream video." }, requestOrigin);
  }

  const role = String(actorProfile.role || "").trim().toLowerCase();
  let allowed = role === "admin";
  if (!allowed && role === "student" && actorProfile.approved === true && lesson.is_published === true) {
    const { data: course } = await adminClient
      .from("platform_courses")
      .select("id,is_active,is_published")
      .eq("id", lesson.course_id)
      .maybeSingle();
    if (course?.is_active === true && course?.is_published === true) {
      if (lesson.is_free_preview === true) {
        allowed = true;
      } else {
        const [{ data: enrollment }, { data: entitlement }] = await Promise.all([
          adminClient
            .from("platform_course_enrollments")
            .select("course_id")
            .eq("course_id", lesson.course_id)
            .eq("user_id", actorId)
            .eq("access_scope", "full")
            .maybeSingle(),
          adminClient
            .from("platform_course_module_entitlements")
            .select("module_id")
            .eq("module_id", lesson.module_id)
            .eq("user_id", actorId)
            .maybeSingle(),
        ]);
        allowed = Boolean(enrollment || entitlement);
      }
    }
  }

  if (!allowed) {
    return jsonResponse(403, { ok: false, error: "You do not have access to this lesson video." }, requestOrigin);
  }

  const tokenResponse = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(cloudflareAccountId)}/stream/${encodeURIComponent(videoUid)}/token`,
    {
      method: "POST",
      headers: { Authorization: `Bearer ${cloudflareApiToken}` },
    },
  );
  const tokenPayload = await tokenResponse.json().catch(() => null);
  const token = String(tokenPayload?.result?.token || "").trim();
  if (!tokenResponse.ok || !token) {
    const details = String(tokenPayload?.errors?.[0]?.message || tokenPayload?.message || "").trim();
    return jsonResponse(tokenResponse.ok ? 502 : tokenResponse.status, {
      ok: false,
      error: details || "Could not create secure video token.",
    }, requestOrigin);
  }

  return jsonResponse(200, {
    ok: true,
    videoUid,
    token,
    iframeUrl: `https://customer-${customerCode}.cloudflarestream.com/${token}/iframe`,
    expiresInSeconds: 3600,
  }, requestOrigin);
});
