"use strict";

// Builds a minified copy of the served site, with every file under its
// original name, so index.html (and its CSP hashes), bootstrap.js script paths
// and the sw.js precache list need no changes. The committed sources stay the
// readable source of truth. Not wired into any workflow: run it by hand to
// inspect the output.
//
//   node build/deploy-build.js [outDir]   (default: _site)
//
// Scripts are transformed without a module format, so esbuild keeps every
// top-level name (main.js is a flat classic script whose globals are shared
// with the helper files). The build fails if a top-level function name is
// renamed or the output fails a syntax check.

const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");
const esbuild = require("esbuild");

const rootDir = path.resolve(__dirname, "..");
const outDir = path.resolve(rootDir, process.argv[2] || "_site");

const EXCLUDED_TOP_LEVEL = new Set([".git", ".github", "node_modules", "dist", path.basename(outDir)]);
const MINIFIED_SCRIPTS = [
  "main.js",
  "bootstrap.js",
  "video-courses-utils.js",
  "app-popups-utils.js",
  "universities-utils.js",
];
const MINIFIED_STYLES = ["styles.css"];

function copySite() {
  fs.rmSync(outDir, { recursive: true, force: true });
  fs.mkdirSync(outDir, { recursive: true });
  for (const entry of fs.readdirSync(rootDir)) {
    if (EXCLUDED_TOP_LEVEL.has(entry)) {
      continue;
    }
    fs.cpSync(path.join(rootDir, entry), path.join(outDir, entry), { recursive: true });
  }
}

function topLevelFunctionNames(source) {
  return [...source.matchAll(/^(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)\s*\(/gm)].map((match) => match[1]);
}

function assertTopLevelNamesKept(file, source, minified) {
  const missing = topLevelFunctionNames(source)
    .filter((name) => !minified.includes(`function ${name}(`) && !minified.includes(`function*${name}(`));
  if (missing.length) {
    throw new Error(`${file}: minification renamed top-level functions: ${missing.slice(0, 10).join(", ")}`);
  }
}

function minifyFile(file, loader) {
  const target = path.join(outDir, file);
  const source = fs.readFileSync(target, "utf8");
  const { code } = esbuild.transformSync(source, { loader, minify: true, legalComments: "none", charset: "utf8" });
  if (loader === "js") {
    assertTopLevelNamesKept(file, source, code);
  }
  fs.writeFileSync(target, code);
  if (loader === "js") {
    execFileSync(process.execPath, ["--check", target], { stdio: "inherit" });
  }
  console.log(`${file}: ${(source.length / 1024).toFixed(0)} KB -> ${(code.length / 1024).toFixed(0)} KB`);
}

copySite();
MINIFIED_SCRIPTS.forEach((file) => minifyFile(file, "js"));
MINIFIED_STYLES.forEach((file) => minifyFile(file, "css"));
console.log(`Minified site written to ${path.relative(rootDir, outDir)}`);
