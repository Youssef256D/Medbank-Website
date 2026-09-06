// Dev-only: keep the fast first paint identical to the classic-script renderer.
// GitHub Pages still serves the committed index.html directly, without a build.
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const root = path.resolve(__dirname, "..");
const rendererNames = [
  "landingStudyPreviewHtml", "landingHeroHtml", "landingMcqBankSectionHtml",
  "landingCoursesSectionHtml", "landingMobileAppsSectionHtml", "landingGettingStartedHtml",
  "landingContactBodyHtml", "landingContactSectionHtml", "renderLanding", "marketingFooterHtml",
];

function renderLandingShell() {
  const source = fs.readFileSync(path.join(root, "main.js"), "utf8");
  const functions = rendererNames.map((name) => {
    const match = source.match(new RegExp(`^function ${name}\\([^\\n]*\\) \\{[\\s\\S]*?^\\}`, "m"));
    if (!match) throw new Error(`Missing pure landing renderer: ${name}`);
    return match[0];
  });
  const storeUrl = source.match(/^const GOOGLE_PLAY_APP_URL = "[^"\n]+";$/m);
  if (!storeUrl) throw new Error("Missing Google Play URL constant");
  return vm.runInNewContext(
    `${storeUrl[0]}\n${functions.join("\n")}\nrenderLanding() + marketingFooterHtml()`,
    {}, { timeout: 1000 },
  ).replace(/[ \t]+$/gm, "");
}

if (require.main === module) {
  const file = path.join(root, "index.html");
  const html = fs.readFileSync(file, "utf8");
  const marker = /(<main id="app"[^>]*>)[\s\S]*?(<\/main>)/;
  if (!marker.test(html)) throw new Error("Missing app shell in index.html");
  fs.writeFileSync(file, html.replace(marker, (_match, open, close) => `${open}\n${renderLandingShell()}\n  ${close}`));
  console.log("Synced index.html landing shell.");
}

module.exports = { renderLandingShell };
