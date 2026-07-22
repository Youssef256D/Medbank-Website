import { GoogleAuth } from "npm:google-auth-library@9.15.1";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const YEAR_AUDIENCE_PATTERN = /^year([1-5])::/i;
const NOTIFICATION_DESTINATION_ROUTES = new Set([
  "app-launcher",
  "dashboard",
  "create-test",
  "analytics",
  "video-courses",
  "profile",
]);
const FCM_CONCURRENCY = 30;
const QUERY_BATCH_SIZE = 150;
const ACTIVE_TOKEN_MAX_AGE_MS = 1000 * 60 * 60 * 24 * 120;

type PushTokenRow = {
  id: string;
  user_id: string;
  token: string;
  platform: "android" | "ios";
};

type DeliveryResult = {
  token: PushTokenRow;
  ok: boolean;
  stale: boolean;
  providerMessageId: string;
  error: string;
};

type AdminClient = ReturnType<typeof createClient<any>>;

function isUuid(value: unknown): boolean {
  return UUID_PATTERN.test(String(value || "").trim());
}

function normalizeNotificationDestinationRoute(value: unknown): string {
  const route = String(value || "").trim().toLowerCase();
  return NOTIFICATION_DESTINATION_ROUTES.has(route) ? route : "notifications";
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
  return {
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Allow-Headers": "Authorization, Content-Type, apikey, x-client-info",
    "Access-Control-Allow-Origin": requestOrigin && configured.includes(requestOrigin)
      ? requestOrigin
      : configured[0],
    "Vary": "Origin",
  };
}

function jsonResponse(status: number, payload: unknown, requestOrigin = ""): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
      ...buildCorsHeaders(requestOrigin),
    },
  });
}

function parseBearerToken(authHeader: string): string {
  const value = String(authHeader || "").trim();
  return value.toLowerCase().startsWith("bearer ")
    ? value.slice("bearer ".length).trim()
    : "";
}

function splitIntoBatches<T>(values: T[], size: number): T[][] {
  const batches: T[][] = [];
  for (let index = 0; index < values.length; index += size) {
    batches.push(values.slice(index, index + size));
  }
  return batches;
}

async function mapWithConcurrency<T, R>(
  values: T[],
  concurrency: number,
  mapper: (value: T) => Promise<R>,
): Promise<R[]> {
  const results = new Array<R>(values.length);
  let nextIndex = 0;
  const worker = async () => {
    while (nextIndex < values.length) {
      const index = nextIndex++;
      results[index] = await mapper(values[index]);
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(concurrency, values.length) }, () => worker()),
  );
  return results;
}

async function loadAudienceTokens(
  adminClient: AdminClient,
  notification: Record<string, unknown>,
): Promise<PushTokenRow[]> {
  const activeSince = new Date(Date.now() - ACTIVE_TOKEN_MAX_AGE_MS).toISOString();
  const recipientUserId = String(notification.recipient_user_id || "").trim();
  if (isUuid(recipientUserId)) {
    const { data, error } = await adminClient
      .from("push_device_tokens")
      .select("id,user_id,token,platform")
      .eq("user_id", recipientUserId)
      .gte("updated_at", activeSince);
    if (error) throw error;
    return (data || []) as PushTokenRow[];
  }

  const externalId = String(notification.external_id || "").trim();
  const yearMatch = externalId.match(YEAR_AUDIENCE_PATTERN);
  if (!yearMatch) {
    const { data, error } = await adminClient
      .from("push_device_tokens")
      .select("id,user_id,token,platform")
      .gte("updated_at", activeSince);
    if (error) throw error;
    return (data || []) as PushTokenRow[];
  }

  const targetYear = Number(yearMatch[1]);
  const { data: profiles, error: profileError } = await adminClient
    .from("profiles")
    .select("id")
    .eq("role", "student")
    .eq("approved", true)
    .eq("academic_year", targetYear);
  if (profileError) throw profileError;

  const profileIds = (profiles || [])
    .map((row) => String(row.id || ""))
    .filter(isUuid);
  const tokens: PushTokenRow[] = [];
  for (const idBatch of splitIntoBatches(profileIds, QUERY_BATCH_SIZE)) {
    const { data, error } = await adminClient
      .from("push_device_tokens")
      .select("id,user_id,token,platform")
      .in("user_id", idBatch)
      .gte("updated_at", activeSince);
    if (error) throw error;
    tokens.push(...((data || []) as PushTokenRow[]));
  }
  return tokens;
}

async function getAlreadySentTokenIds(
  adminClient: AdminClient,
  notificationId: string,
  tokenIds: string[],
): Promise<Set<string>> {
  const sentIds = new Set<string>();
  for (const idBatch of splitIntoBatches(tokenIds, QUERY_BATCH_SIZE)) {
    const { data, error } = await adminClient
      .from("push_notification_deliveries")
      .select("push_token_id")
      .eq("notification_id", notificationId)
      .eq("status", "sent")
      .in("push_token_id", idBatch);
    if (error) throw error;
    (data || []).forEach((row) => sentIds.add(String(row.push_token_id || "")));
  }
  return sentIds;
}

async function sendToFcm(
  accessToken: string,
  projectId: string,
  notification: Record<string, unknown>,
  token: PushTokenRow,
): Promise<DeliveryResult> {
  const destinationRoute = normalizeNotificationDestinationRoute(notification.target_route);
  const response = await fetch(
    `https://fcm.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/messages:send`,
    {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${accessToken}`,
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify({
        message: {
          token: token.token,
          notification: {
            title: String(notification.title || "MedBank"),
            body: String(notification.message || ""),
          },
          data: {
            notification_id: String(notification.id || ""),
            route: `/${destinationRoute}`,
            mcq_subject: String(notification.target_mcq_subject || ""),
            mcq_topic: String(notification.target_mcq_topic || ""),
            video_course_id: String(notification.target_video_course_id || ""),
          },
          android: {
            priority: "high",
            notification: {
              channel_id: "medbank_notifications",
              sound: "default",
            },
          },
          apns: {
            headers: { "apns-priority": "10" },
            payload: { aps: { sound: "default", badge: 1 } },
          },
        },
      }),
    },
  );

  const responseBody = await response.json().catch(() => ({}));
  if (response.ok) {
    return {
      token,
      ok: true,
      stale: false,
      providerMessageId: String(responseBody?.name || ""),
      error: "",
    };
  }

  const errorCode = String(responseBody?.error?.details?.[0]?.errorCode || "");
  const errorMessage = String(responseBody?.error?.message || `FCM returned HTTP ${response.status}.`);
  return {
    token,
    ok: false,
    stale: errorCode === "UNREGISTERED" || errorCode === "INVALID_ARGUMENT",
    providerMessageId: "",
    error: `${errorCode ? `${errorCode}: ` : ""}${errorMessage}`.slice(0, 1000),
  };
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
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse(500, {
      ok: false,
      error: "Push delivery is missing its Supabase server configuration.",
    }, requestOrigin);
  }

  const callerToken = parseBearerToken(req.headers.get("authorization") || "");
  if (!callerToken) {
    return jsonResponse(401, { ok: false, error: "Missing bearer token." }, requestOrigin);
  }

  let body: { notificationId?: string } = {};
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { ok: false, error: "Invalid JSON payload." }, requestOrigin);
  }
  const notificationId = String(body.notificationId || "").trim();
  if (!isUuid(notificationId)) {
    return jsonResponse(400, { ok: false, error: "notificationId must be a UUID." }, requestOrigin);
  }

  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: actorData, error: actorError } = await adminClient.auth.getUser(callerToken);
  const actorId = String(actorData?.user?.id || "").trim();
  if (actorError || !isUuid(actorId)) {
    return jsonResponse(401, { ok: false, error: "Unauthorized. Log in again and retry." }, requestOrigin);
  }
  const { data: actorProfile, error: actorProfileError } = await adminClient
    .from("profiles")
    .select("role")
    .eq("id", actorId)
    .maybeSingle();
  if (actorProfileError) {
    return jsonResponse(500, { ok: false, error: "Could not verify the admin role." }, requestOrigin);
  }
  if (String(actorProfile?.role || "").toLowerCase() !== "admin") {
    return jsonResponse(403, { ok: false, error: "Only admins can send push notifications." }, requestOrigin);
  }

  const serviceAccountJson = String(Deno.env.get("FIREBASE_SERVICE_ACCOUNT_JSON") || "").trim();
  if (!serviceAccountJson) {
    return jsonResponse(500, {
      ok: false,
      error: "Push delivery is missing its Firebase server configuration.",
    }, requestOrigin);
  }

  const { data: notification, error: notificationError } = await adminClient
    .from("notifications")
    .select("id,external_id,recipient_user_id,title,message,target_route,target_mcq_subject,target_mcq_topic,target_video_course_id,is_active")
    .eq("id", notificationId)
    .eq("is_active", true)
    .maybeSingle();
  if (notificationError || !notification) {
    return jsonResponse(404, { ok: false, error: "Active notification not found." }, requestOrigin);
  }

  let credentials: Record<string, string>;
  try {
    credentials = JSON.parse(serviceAccountJson);
  } catch {
    return jsonResponse(500, { ok: false, error: "Firebase service account JSON is invalid." }, requestOrigin);
  }
  const projectId = String(credentials.project_id || "").trim();
  if (!projectId) {
    return jsonResponse(500, { ok: false, error: "Firebase service account has no project_id." }, requestOrigin);
  }

  try {
    const audienceTokens = await loadAudienceTokens(adminClient, notification);
    if (!audienceTokens.length) {
      return jsonResponse(200, {
        ok: false,
        error: "No registered devices match this notification audience yet.",
        eligibleTokenCount: 0,
        sentCount: 0,
      }, requestOrigin);
    }

    const alreadySentIds = await getAlreadySentTokenIds(
      adminClient,
      notificationId,
      audienceTokens.map((token) => token.id),
    );
    const pendingTokens = audienceTokens.filter((token) => !alreadySentIds.has(token.id));
    if (!pendingTokens.length) {
      return jsonResponse(200, {
        ok: true,
        eligibleTokenCount: audienceTokens.length,
        sentCount: 0,
        alreadySentCount: alreadySentIds.size,
        failedCount: 0,
      }, requestOrigin);
    }

    const googleAuth = new GoogleAuth({
      credentials,
      scopes: ["https://www.googleapis.com/auth/firebase.messaging"],
    });
    const googleClient = await googleAuth.getClient();
    const accessTokenResult = await googleClient.getAccessToken();
    const accessToken = String(accessTokenResult?.token || "").trim();
    if (!accessToken) throw new Error("Could not obtain a Firebase OAuth access token.");

    const results = await mapWithConcurrency(
      pendingTokens,
      FCM_CONCURRENCY,
      (pushToken) => sendToFcm(accessToken, projectId, notification, pushToken),
    );
    const deliveryRows = results.map((result) => ({
      notification_id: notificationId,
      push_token_id: result.token.id,
      status: result.ok ? "sent" : "failed",
      provider_message_id: result.providerMessageId || null,
      last_error: result.error || null,
      last_attempt_at: new Date().toISOString(),
    }));
    const { error: deliveryError } = await adminClient
      .from("push_notification_deliveries")
      .upsert(deliveryRows, { onConflict: "notification_id,push_token_id" });
    if (deliveryError) throw deliveryError;

    const staleTokenIds = results
      .filter((result) => result.stale)
      .map((result) => result.token.id);
    if (staleTokenIds.length) {
      await adminClient.from("push_device_tokens").delete().in("id", staleTokenIds);
    }

    const sentCount = results.filter((result) => result.ok).length;
    const failedResults = results.filter((result) => !result.ok && !result.stale);
    return jsonResponse(200, {
      ok: failedResults.length === 0,
      error: failedResults.length ? failedResults[0].error : undefined,
      eligibleTokenCount: audienceTokens.length,
      sentCount,
      alreadySentCount: alreadySentIds.size,
      staleTokenCount: staleTokenIds.length,
      failedCount: failedResults.length,
    }, requestOrigin);
  } catch (error) {
    console.error("Push notification delivery failed", error);
    return jsonResponse(500, {
      ok: false,
      error: error instanceof Error ? error.message : "Push notification delivery failed.",
    }, requestOrigin);
  }
});
