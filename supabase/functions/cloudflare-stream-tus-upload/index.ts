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
    "Access-Control-Allow-Headers": "Authorization, Content-Type, apikey, x-client-info, Tus-Resumable, Upload-Length, Upload-Metadata",
    "Access-Control-Expose-Headers": "Location, Tus-Resumable",
    "Tus-Resumable": "1.0.0",
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

// Admin layers (migration 20260930030000_admin_permission_areas): the areas
// this admin may change, and whether they are a super admin. This function
// runs with the service role, so the database's own admin-account guard does
// not apply here; these checks do the same job. Until that migration is
// applied the table does not exist and every admin keeps full access, as
// before.
type AdminAccess = { ok: boolean; isSuper: boolean; areas: string[] };

async function loadAdminAccess(client: ReturnType<typeof createClient>, actorId: string): Promise<AdminAccess> {
  const { data, error } = await client
    .from("admin_permissions")
    .select("is_super,areas")
    .eq("user_id", actorId)
    .maybeSingle();
  if (error) {
    const code = String((error as { code?: string }).code || "");
    const message = String(error.message || "");
    if (code === "42P01" || code === "PGRST205" || (/admin_permissions/i.test(message) && /does not exist|schema cache/i.test(message))) {
      return { ok: true, isSuper: true, areas: [] };
    }
    return { ok: false, isSuper: false, areas: [] };
  }
  return {
    ok: true,
    isSuper: Boolean(data?.is_super),
    areas: Array.isArray(data?.areas) ? data.areas.map((area: unknown) => String(area)) : [],
  };
}

function adminHasArea(access: AdminAccess, area: string): boolean {
  return access.isSuper || access.areas.includes(area);
}

async function anyTargetIsAdmin(client: ReturnType<typeof createClient>, ids: string[]): Promise<boolean | null> {
  if (!ids.length) return false;
  const { data, error } = await client.from("profiles").select("id").in("id", ids).eq("role", "admin").limit(1);
  if (error) return null;
  return Array.isArray(data) && data.length > 0;
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

  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse(500, { ok: false, error: "Server configuration is missing Supabase secrets." }, requestOrigin);
  }
  if (!cloudflareAccountId || !cloudflareApiToken) {
    return jsonResponse(500, { ok: false, error: "Cloudflare Stream is not configured yet." }, requestOrigin);
  }

  const accessToken = parseBearerToken(req.headers.get("authorization") || "");
  if (!accessToken) {
    return jsonResponse(401, { ok: false, error: "Missing bearer token." }, requestOrigin);
  }

  const uploadLength = String(req.headers.get("upload-length") || "").trim();
  const uploadMetadata = String(req.headers.get("upload-metadata") || "").trim();
  if (!uploadLength || !/^\d+$/.test(uploadLength)) {
    return jsonResponse(400, { ok: false, error: "Missing Upload-Length header." }, requestOrigin);
  }
  if (!uploadMetadata) {
    return jsonResponse(400, { ok: false, error: "Missing Upload-Metadata header." }, requestOrigin);
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
    .select("id,role")
    .eq("id", actorId)
    .maybeSingle();
  if (profileError) {
    return jsonResponse(500, { ok: false, error: "Could not verify actor profile role." }, requestOrigin);
  }
  if (String(actorProfile?.role || "").trim().toLowerCase() !== "admin") {
    return jsonResponse(403, { ok: false, error: "Only admins can upload course videos." }, requestOrigin);
  }

  const adminAccess = await loadAdminAccess(adminClient, actorId);
  if (!adminAccess.ok) {
    return jsonResponse(500, { ok: false, error: "Could not verify admin permissions." }, requestOrigin);
  }
  if (!adminHasArea(adminAccess, "video_courses")) {
    return jsonResponse(403, { ok: false, error: "Your admin account does not include the Video Courses area." }, requestOrigin);
  }

  const endpoint = `https://api.cloudflare.com/client/v4/accounts/${encodeURIComponent(cloudflareAccountId)}/stream?direct_user=true`;
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${cloudflareApiToken}`,
      "Tus-Resumable": "1.0.0",
      "Upload-Length": uploadLength,
      "Upload-Metadata": uploadMetadata,
    },
  });

  const destination = String(response.headers.get("location") || "").trim();
  if (!response.ok || !destination) {
    let details = "";
    try {
      const payload = await response.json();
      details = String(payload?.errors?.[0]?.message || payload?.message || "").trim();
    } catch {
      details = "";
    }
    return jsonResponse(response.ok ? 502 : response.status, {
      ok: false,
      error: details || "Cloudflare could not create the video upload.",
    }, requestOrigin);
  }

  return new Response(null, {
    status: 201,
    headers: {
      ...buildCorsHeaders(requestOrigin),
      Location: destination,
      "Cache-Control": "no-store",
    },
  });
});
