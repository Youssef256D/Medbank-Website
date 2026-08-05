import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ACCOUNT_DEACTIVATION_BAN_DURATION = "876000h";

function isUuid(value: string): boolean {
  return UUID_PATTERN.test(String(value || "").trim());
}

function normalizeRole(value: unknown): "student" | "creator" | "admin" {
  const role = String(value || "").trim().toLowerCase();
  return role === "admin" || role === "creator" ? role : "student";
}

function normalizeOptionalAcademicNumber(value: unknown): number | null {
  const number = Number(value);
  if (!Number.isFinite(number)) {
    return null;
  }
  const integer = Math.trunc(number);
  return integer > 0 ? integer : null;
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

  if (requestOrigin && configured.includes(requestOrigin)) {
    return {
      ...base,
      "Access-Control-Allow-Origin": requestOrigin,
      "Vary": "Origin",
    };
  }

  return {
    ...base,
    "Access-Control-Allow-Origin": configured[0],
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

function parseBearerToken(authHeader: string): string {
  const value = String(authHeader || "").trim();
  if (!value.toLowerCase().startsWith("bearer ")) {
    return "";
  }
  return value.slice("bearer ".length).trim();
}

Deno.serve(async (req) => {
  const requestOrigin = String(req.headers.get("origin") || "").trim();

  if (req.method === "OPTIONS") {
    return new Response(null, {
      status: 204,
      headers: buildCorsHeaders(requestOrigin),
    });
  }

  if (req.method !== "POST") {
    return jsonResponse(405, { ok: false, error: "Method not allowed." }, requestOrigin);
  }

  const supabaseUrl = String(Deno.env.get("SUPABASE_URL") || "").trim().replace(/\/+$/, "");
  const serviceRoleKey = String(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "").trim();
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse(
      500,
      { ok: false, error: "Server configuration is missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY." },
      requestOrigin,
    );
  }

  const accessToken = parseBearerToken(req.headers.get("authorization") || "");
  if (!accessToken) {
    return jsonResponse(401, { ok: false, error: "Missing bearer token." }, requestOrigin);
  }

  let body: {
    email?: string;
    password?: string;
    fullName?: string;
    role?: string;
    approved?: boolean;
    phone?: string | null;
    academicYear?: number | string | null;
    academicSemester?: number | string | null;
  } = {};
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { ok: false, error: "Invalid JSON payload." }, requestOrigin);
  }

  const email = String(body?.email || "").trim().toLowerCase();
  const password = typeof body?.password === "string" ? body.password : "";
  const fullName = String(body?.fullName || "").trim();
  const role = normalizeRole(body?.role);
  const approved = role === "student" ? body?.approved === true : true;
  const phone = String(body?.phone || "").trim() || null;
  const academicYear = role === "student" ? normalizeOptionalAcademicNumber(body?.academicYear) : null;
  const academicSemester = role === "student" ? normalizeOptionalAcademicNumber(body?.academicSemester) : null;

  if (!email || !email.includes("@")) {
    return jsonResponse(400, { ok: false, error: "email must be a valid email address." }, requestOrigin);
  }
  if (!password || password.length < 6) {
    return jsonResponse(400, { ok: false, error: "password must be at least 6 characters." }, requestOrigin);
  }
  if (password.length > 128) {
    return jsonResponse(400, { ok: false, error: "password is too long (maximum 128 characters)." }, requestOrigin);
  }
  if (!fullName) {
    return jsonResponse(400, { ok: false, error: "fullName is required." }, requestOrigin);
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });

  const { data: actorData, error: actorError } = await adminClient.auth.getUser(accessToken);
  const actorId = String(actorData?.user?.id || "").trim();
  if (actorError || !isUuid(actorId)) {
    return jsonResponse(401, { ok: false, error: "Unauthorized. Log in again and retry." }, requestOrigin);
  }

  const { data: actorProfile, error: profileError } = await adminClient
    .from("profiles")
    .select("id,role")
    .eq("id", actorId)
    .maybeSingle();
  if (profileError) {
    return jsonResponse(500, { ok: false, error: "Could not verify actor profile role." }, requestOrigin);
  }
  if (String(actorProfile?.role || "").trim().toLowerCase() !== "admin") {
    return jsonResponse(403, { ok: false, error: "Only admin users can create accounts." }, requestOrigin);
  }

  const { data: authData, error: createError } = await adminClient.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
    user_metadata: {
      full_name: fullName,
      phone_number: phone,
      academic_year: academicYear,
      academic_semester: academicSemester,
    },
  });
  const createdUserId = String(authData?.user?.id || "").trim();
  if (createError || !isUuid(createdUserId)) {
    const details = String(createError?.message || "").trim();
    const status = /already|registered|exists|duplicate/i.test(details) ? 409 : 500;
    return jsonResponse(status, { ok: false, error: details || "User account could not be created." }, requestOrigin);
  }

  const profileRow = {
    id: createdUserId,
    full_name: fullName,
    email,
    role,
    approved,
    phone,
    academic_year: academicYear,
    academic_semester: academicSemester,
    auth_provider: "email",
    mcq_access_enabled: true,
    courses_access_enabled: true,
  };

  const { data: profile, error: upsertError } = await adminClient
    .from("profiles")
    .upsert(profileRow, { onConflict: "id", defaultToNull: false })
    .select("id,full_name,email,role,approved,phone,academic_year,academic_semester,mcq_access_enabled,courses_access_enabled,auth_provider,created_at,updated_at")
    .single();
  if (upsertError) {
    await adminClient.auth.admin.deleteUser(createdUserId).catch(() => {});
    return jsonResponse(500, { ok: false, error: upsertError.message || "Profile could not be created." }, requestOrigin);
  }

  if (!approved) {
    const { error: banError } = await adminClient.auth.admin.updateUserById(createdUserId, {
      ban_duration: ACCOUNT_DEACTIVATION_BAN_DURATION,
    });
    if (banError) {
      return jsonResponse(500, { ok: false, error: banError.message || "Account was created but access could not be disabled." }, requestOrigin);
    }
  }

  return jsonResponse(200, {
    ok: true,
    user: {
      id: createdUserId,
      email,
      email_confirmed_at: authData?.user?.email_confirmed_at || authData?.user?.confirmed_at || null,
    },
    profile,
  }, requestOrigin);
});
