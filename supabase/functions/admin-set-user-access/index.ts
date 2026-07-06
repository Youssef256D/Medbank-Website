import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
const ACCOUNT_DEACTIVATION_BAN_DURATION = "876000h";
const ACCESS_UPDATE_CONCURRENCY = 12;
const PROFILE_APPROVAL_UPDATE_BATCH_SIZE = 100;

function isUuid(value: string): boolean {
  return UUID_PATTERN.test(String(value || "").trim());
}

function uniqueUuidList(values: unknown): string[] {
  const entries = Array.isArray(values) ? values : [values];
  return [...new Set(
    entries
      .map((entry) => String(entry || "").trim())
      .filter((entry) => isUuid(entry)),
  )];
}

function splitIntoBatches<T>(values: T[], batchSize: number): T[][] {
  const entries = Array.isArray(values) ? values : [];
  const size = Math.max(1, Number(batchSize) || 1);
  const batches: T[][] = [];
  for (let index = 0; index < entries.length; index += size) {
    batches.push(entries.slice(index, index + size));
  }
  return batches;
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

async function applyAuthAccessUpdatesInParallel(
  adminClient: ReturnType<typeof createClient>,
  targetAuthIds: string[],
  approved: boolean,
): Promise<{
  updatedIds: string[];
  notFoundIds: string[];
  failedIds: string[];
  firstFailureMessage: string;
}> {
  const updatedIds: string[] = [];
  const notFoundIds: string[] = [];
  const failedIds: string[] = [];
  let firstFailureMessage = "";
  let nextIndex = 0;

  const worker = async () => {
    while (nextIndex < targetAuthIds.length) {
      const currentIndex = nextIndex;
      nextIndex += 1;
      const targetAuthId = targetAuthIds[currentIndex];
      // One retry with a short backoff: a transient Auth API failure must not
      // leave profiles.approved and the auth ban state inconsistent.
      let resolved = false;
      for (let attempt = 0; attempt < 2 && !resolved; attempt += 1) {
        if (attempt > 0) {
          await new Promise((resolve) => setTimeout(resolve, 400));
        }
        try {
          const { error: updateError } = await adminClient.auth.admin.updateUserById(targetAuthId, {
            ban_duration: approved ? "none" : ACCOUNT_DEACTIVATION_BAN_DURATION,
          });
          if (!updateError) {
            updatedIds.push(targetAuthId);
            resolved = true;
            break;
          }
          const details = String(updateError.message || "").trim();
          if (/not found|user not found/i.test(details)) {
            notFoundIds.push(targetAuthId);
            resolved = true;
            break;
          }
          if (attempt === 1) {
            failedIds.push(targetAuthId);
            if (!firstFailureMessage) {
              firstFailureMessage = details || "Supabase admin access update failed.";
            }
          }
        } catch (error) {
          if (attempt === 1) {
            failedIds.push(targetAuthId);
            if (!firstFailureMessage) {
              firstFailureMessage = String(error instanceof Error ? error.message : error || "").trim()
                || "Unexpected error while updating user access.";
            }
          }
        }
      }
    }
  };

  const workerCount = Math.min(ACCESS_UPDATE_CONCURRENCY, targetAuthIds.length);
  await Promise.all(Array.from({ length: workerCount }, () => worker()));

  return {
    updatedIds,
    notFoundIds,
    failedIds,
    firstFailureMessage,
  };
}

async function updateProfileApproval(
  adminClient: ReturnType<typeof createClient>,
  targetProfileIds: string[],
  approved: boolean,
): Promise<{
  updatedIds: string[];
  missingIds: string[];
  failedIds: string[];
  firstFailureMessage: string;
}> {
  const targetIds = uniqueUuidList(targetProfileIds);
  const updatedIds: string[] = [];
  const missingIds: string[] = [];
  const failedIds: string[] = [];
  let firstFailureMessage = "";

  const applyBatch = async (idBatch: string[]): Promise<void> => {
    if (!idBatch.length) {
      return;
    }

    const { data, error } = await adminClient
      .from("profiles")
      .update({ approved: Boolean(approved) })
      .in("id", idBatch)
      .select("id,approved");

    if (error) {
      if (idBatch.length > 1) {
        const midpoint = Math.ceil(idBatch.length / 2);
        await applyBatch(idBatch.slice(0, midpoint));
        await applyBatch(idBatch.slice(midpoint));
        return;
      }
      failedIds.push(idBatch[0]);
      if (!firstFailureMessage) {
        firstFailureMessage = String(error.message || "").trim() || "Could not update profile approval.";
      }
      return;
    }

    const returnedIds = new Set<string>();
    (Array.isArray(data) ? data : []).forEach((row) => {
      const id = String(row?.id || "").trim();
      if (!isUuid(id)) {
        return;
      }
      returnedIds.add(id);
      if (Boolean(row?.approved) === Boolean(approved)) {
        updatedIds.push(id);
        return;
      }
      failedIds.push(id);
      if (!firstFailureMessage) {
        firstFailureMessage = "Profile approval verification failed.";
      }
    });

    idBatch.forEach((id) => {
      if (!returnedIds.has(id)) {
        missingIds.push(id);
      }
    });
  };

  for (const batch of splitIntoBatches(targetIds, PROFILE_APPROVAL_UPDATE_BATCH_SIZE)) {
    await applyBatch(batch);
  }

  return {
    updatedIds: uniqueUuidList(updatedIds),
    missingIds: uniqueUuidList(missingIds),
    failedIds: uniqueUuidList(failedIds),
    firstFailureMessage,
  };
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

  let body: { targetAuthId?: string; targetAuthIds?: string[]; approved?: boolean } = {};
  try {
    body = await req.json();
  } catch {
    return jsonResponse(400, { ok: false, error: "Invalid JSON payload." }, requestOrigin);
  }

  const targetAuthIds = [...new Set(
    (Array.isArray(body?.targetAuthIds) ? body.targetAuthIds : [body?.targetAuthId])
      .map((entry) => String(entry || "").trim())
      .filter((entry) => isUuid(entry)),
  )];
  const approved = body?.approved;
  if (!targetAuthIds.length) {
    return jsonResponse(400, { ok: false, error: "targetAuthIds must include at least one valid UUID." }, requestOrigin);
  }
  if (typeof approved !== "boolean") {
    return jsonResponse(400, { ok: false, error: "approved must be a boolean." }, requestOrigin);
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
    return jsonResponse(403, { ok: false, error: "Only admin users can update account access." }, requestOrigin);
  }

  const profileUpdate = await updateProfileApproval(adminClient, targetAuthIds, approved);
  const profileUpdatedIdSet = new Set(profileUpdate.updatedIds || []);
  const profileMissingIdSet = new Set(profileUpdate.missingIds || []);
  const blockedProfileIdSet = new Set([
    ...(profileUpdate.failedIds || []),
    ...(approved ? (profileUpdate.missingIds || []) : []),
  ]);
  const authTargetIds = targetAuthIds.filter((id) => !blockedProfileIdSet.has(id));
  const {
    updatedIds: authUpdatedIds,
    notFoundIds: authNotFoundIds,
    failedIds: authFailedIds,
    firstFailureMessage,
  } = authTargetIds.length
    ? await applyAuthAccessUpdatesInParallel(adminClient, authTargetIds, approved)
    : { updatedIds: [], notFoundIds: [], failedIds: [], firstFailureMessage: "" };

  const profileSucceededForAccess = (id: string): boolean => (
    profileUpdatedIdSet.has(id) || (!approved && profileMissingIdSet.has(id))
  );
  // Consistent-deny: approving a profile whose auth ban could not be lifted
  // would leave the account "approved" but unable to log in. Revert those
  // profiles back to unapproved and report them so the admin can retry.
  const revertedProfileIds: string[] = [];
  if (approved && authFailedIds.length) {
    const revertTargets = authFailedIds.filter((id) => profileUpdatedIdSet.has(id));
    if (revertTargets.length) {
      const { data: revertedRows, error: revertError } = await adminClient
        .from("profiles")
        .update({ approved: false })
        .in("id", revertTargets)
        .select("id");
      if (!revertError) {
        (Array.isArray(revertedRows) ? revertedRows : []).forEach((row) => {
          const id = String(row?.id || "").trim();
          if (isUuid(id)) {
            revertedProfileIds.push(id);
            profileUpdatedIdSet.delete(id);
          }
        });
      }
    }
  }

  const updatedIds = authUpdatedIds.filter((id) => profileSucceededForAccess(id));
  const notFoundIds = authNotFoundIds.filter((id) => profileSucceededForAccess(id));
  const failedIds = [...new Set([
    ...(profileUpdate.failedIds || []),
    ...(approved ? (profileUpdate.missingIds || []) : []),
    ...authFailedIds,
  ])];

  const effectiveProfileUpdatedIds = (profileUpdate.updatedIds || []).filter((id) => profileUpdatedIdSet.has(id));

  if (!failedIds.length) {
    return jsonResponse(200, {
      ok: true,
      updatedIds,
      notFoundIds,
      failedIds: [],
      profileUpdatedIds: effectiveProfileUpdatedIds,
      profileMissingIds: profileUpdate.missingIds || [],
      revertedProfileIds,
    }, requestOrigin);
  }

  return jsonResponse(
    updatedIds.length || notFoundIds.length ? 200 : 500,
    {
      ok: false,
      updatedIds,
      notFoundIds,
      failedIds,
      profileUpdatedIds: effectiveProfileUpdatedIds,
      profileMissingIds: profileUpdate.missingIds || [],
      revertedProfileIds,
      error: profileUpdate.firstFailureMessage || firstFailureMessage || `${failedIds.length} account(s) could not be updated.`,
    },
    requestOrigin,
  );
});
