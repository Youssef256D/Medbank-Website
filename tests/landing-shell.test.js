const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { renderLandingShell } = require("../build/sync-landing-shell.js");
const root = path.resolve(__dirname, "..");
const html = fs.readFileSync(path.join(root, "index.html"), "utf8");

test("first-paint homepage matches the SPA renderer", () => {
  const initial = html.match(/<main id="app"[^>]*>([\s\S]*?)<\/main>/)[1];
  assert.equal(initial.trim(), renderLandingShell().trim(), "Run npm run sync:landing after editing public renderers");
});

test("homepage anchors are unique and all local preview assets exist", () => {
  const shell = renderLandingShell();
  const ids = [...shell.matchAll(/\bid="([^"]+)"/g)].map((m) => m[1]);
  assert.equal(new Set(ids).size, ids.length);
  for (const [, target] of shell.matchAll(/data-scroll-to="([^"]+)"/g)) assert.ok(ids.includes(target));
  for (const [, asset] of shell.matchAll(/\bsrc="([^"?#]+)"/g)) {
    if (!/^https?:/.test(asset)) assert.ok(fs.existsSync(path.join(root, asset)), asset);
  }
});

test("inline bootstrap scripts remain authorized by the static CSP", () => {
  const csp = html.match(/http-equiv="Content-Security-Policy" content="([\s\S]*?)"/)[1];
  for (const [, attributes, content] of html.replace(/<!--[\s\S]*?-->/g, "").matchAll(/<script([^>]*)>([\s\S]*?)<\/script>/g)) {
    if (/\bsrc=|application\/ld\+json/.test(attributes)) continue;
    const hash = crypto.createHash("sha256").update(content).digest("base64");
    assert.ok(csp.includes(`'sha256-${hash}'`), "Inline script changed without updating CSP");
  }
});
