// Runs supabase/tests/rls_signed_in.sql against the hosted project through
// the Management API. The SQL acts as real users inside a transaction that
// always rolls back, so nothing is changed. Needs SUPABASE_ACCESS_TOKEN;
// skipped (exit 0) without it. Run: npm run check:rls
import { readFile } from "node:fs/promises";

const PROJECT_REF = "fzjzjzdamehxbgikiskt";
const token = process.env.SUPABASE_ACCESS_TOKEN;
if (!token) {
  console.log("Signed-in RLS check skipped (no SUPABASE_ACCESS_TOKEN).");
  process.exit(0);
}

const query = await readFile(new URL("../supabase/tests/rls_signed_in.sql", import.meta.url), "utf8");
const response = await fetch(`https://api.supabase.com/v1/projects/${PROJECT_REF}/database/query`, {
  method: "POST",
  headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
  body: JSON.stringify({ query }),
});
const text = await response.text();
if (!response.ok) {
  console.error(`Signed-in RLS check failed (HTTP ${response.status}):\n${text}`);
  process.exit(1);
}
console.log("Signed-in RLS check passed (student, unapproved student, admin).");
