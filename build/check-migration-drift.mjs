// Compares supabase/migrations/ with the hosted project's migration ledger and
// fails when a migration was applied without being committed (or committed
// and never applied). Versions owned by the Flutter repo, and ones kept
// unapplied on purpose, are listed in supabase/migration-drift-allowlist.json.
//
// Ledger source, in order:
//   --ledger <file>          file of versions (one per line, or JSON array)
//   SUPABASE_ACCESS_TOKEN    personal access token; reads the Management API
// With neither, the check is skipped (exit 0) so forks and local runs pass.
// Run: npm run check:migrations
import { readFile, readdir } from "node:fs/promises";

const PROJECT_REF = "fzjzjzdamehxbgikiskt";
const root = new URL("../", import.meta.url);

const allowlist = JSON.parse(
  await readFile(new URL("supabase/migration-drift-allowlist.json", root), "utf8"),
);
const appliedElsewhere = new Set(Object.keys(allowlist.appliedFromOtherRepos || {}));
const unappliedOnPurpose = new Set(Object.keys(allowlist.unappliedOnPurpose || {}));

const repoVersions = new Set(
  (await readdir(new URL("supabase/migrations/", root)))
    .filter((name) => name.endsWith(".sql"))
    .map((name) => name.split("_")[0]),
);

async function loadLedger() {
  const flagIndex = process.argv.indexOf("--ledger");
  if (flagIndex !== -1) {
    const text = await readFile(process.argv[flagIndex + 1], "utf8");
    const parsed = text.trim().startsWith("[") ? JSON.parse(text) : text.split(/\s+/);
    return parsed.map((entry) => String(entry.version ?? entry).trim()).filter(Boolean);
  }
  const token = process.env.SUPABASE_ACCESS_TOKEN;
  if (!token) return null;
  const response = await fetch(
    `https://api.supabase.com/v1/projects/${PROJECT_REF}/database/migrations`,
    { headers: { Authorization: `Bearer ${token}`, Accept: "application/json" } },
  );
  if (!response.ok) {
    console.error(`Could not read the migration ledger: HTTP ${response.status}`);
    process.exit(1);
  }
  const body = await response.json();
  return body.map((row) => String(row.version));
}

const ledger = await loadLedger();
if (!ledger) {
  console.log("Migration drift check skipped (no SUPABASE_ACCESS_TOKEN or --ledger).");
  process.exit(0);
}
const hosted = new Set(ledger);

const failures = [];
for (const version of [...hosted].sort()) {
  if (!repoVersions.has(version) && !appliedElsewhere.has(version)) {
    failures.push(`${version}: applied to the hosted project but not in supabase/migrations/`);
  }
}
for (const version of [...repoVersions].sort()) {
  if (!hosted.has(version) && !unappliedOnPurpose.has(version)) {
    failures.push(`${version}: in supabase/migrations/ but not applied to the hosted project`);
  }
}
for (const version of appliedElsewhere) {
  if (!hosted.has(version)) failures.push(`${version}: allow-listed as applied elsewhere but not in the ledger`);
}

if (failures.length) {
  console.error("Migration drift found:\n- " + failures.join("\n- "));
  console.error("Commit the missing migration, apply it, or update supabase/migration-drift-allowlist.json.");
  process.exit(1);
}
console.log(`Migration drift check passed (${hosted.size} applied, ${repoVersions.size} in repo).`);
