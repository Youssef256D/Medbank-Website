// Checks, against the hosted project, that a signed-out caller holding only
// the public key from supabase.config.js cannot read paid content or user
// data. Read-only (GET requests, `select` limited to ids/keys). Exits 1 on
// any leak. Run: npm run check:anon
import { readFile } from "node:fs/promises";

const configSource = await readFile(new URL("../supabase.config.js", import.meta.url), "utf8");
const url = configSource.match(/url:\s*"([^"]+)"/)?.[1];
const anonKey = configSource.match(/anonKey:\s*"([^"]+)"/)?.[1];
if (!url || !anonKey) {
  console.error("Could not read url/anonKey from supabase.config.js.");
  process.exit(1);
}

// Keys a signed-out visitor may read (shown before sign-in).
const ANON_READABLE_APP_STATE_KEYS = new Set(["g:mcq_site_maintenance", "g:support_whatsapp"]);

// Tables that must return no rows to a signed-out caller.
const PROTECTED_TABLES = [
  ["questions", "id"],
  ["question_choices", "id"],
  ["profiles", "id"],
  ["courses", "id"],
  ["course_topics", "id"],
  ["user_course_enrollments", "user_id"],
  ["test_blocks", "id"],
  ["test_history_entries", "id"],
  ["platform_course_lessons", "id"],
];

async function get(path) {
  const response = await fetch(`${url}/rest/v1/${path}`, {
    headers: { apikey: anonKey, Accept: "application/json" },
  });
  const body = await response.json().catch(() => null);
  return { status: response.status, body };
}

const failures = [];

const appState = await get("app_state?select=storage_key");
if (appState.status === 200 && Array.isArray(appState.body)) {
  const leaked = appState.body
    .map((row) => row.storage_key)
    .filter((key) => !ANON_READABLE_APP_STATE_KEYS.has(key));
  if (leaked.length) {
    failures.push(`app_state: signed-out caller can read ${leaked.length} key(s): ${leaked.join(", ")}`);
  }
} else if (appState.status >= 500 || appState.status === 0) {
  failures.push(`app_state: unexpected status ${appState.status}`);
}

for (const [table, column] of PROTECTED_TABLES) {
  const result = await get(`${table}?select=${column}&limit=1`);
  if (result.status === 200 && Array.isArray(result.body) && result.body.length) {
    failures.push(`${table}: signed-out caller can read rows`);
  } else if (result.status >= 500) {
    failures.push(`${table}: unexpected status ${result.status}`);
  }
}

if (failures.length) {
  console.error("Signed-out access check FAILED:");
  failures.forEach((line) => console.error(`  - ${line}`));
  process.exit(1);
}
console.log(`Signed-out access check passed (app_state + ${PROTECTED_TABLES.length} tables).`);
