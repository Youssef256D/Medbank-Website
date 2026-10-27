#!/usr/bin/env node
// MedBank design-token generator. No dependencies: it runs on the Node that
// ships with GitHub's ubuntu runners, in both the website and the app repo.
//
//   node design-tokens/generate.mjs --css styles.css
//   node design-tokens/generate.mjs --dart lib/core/theme/app_tokens.g.dart
//   add --check to fail (exit 1) instead of writing when an output is stale.
//
// The CSS output replaces the marked regions inside the existing :root,
// body.theme-dark and body.theme-comfort blocks of styles.css, so every token
// keeps its place in the cascade. The Dart output is a whole file.
//
// This file and tokens.json are copied byte for byte into the app repo; the
// website copy is the source. Edit there, run with both targets, commit both.

import { readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const TOKENS_PATH = join(HERE, "tokens.json");
const EDIT_HINT = "edit design-tokens/tokens.json, then run design-tokens/generate.mjs";

function parseArgs(argv) {
  const args = { check: false, css: null, dart: null };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--check") args.check = true;
    else if (arg === "--css") args.css = argv[++i];
    else if (arg === "--dart") args.dart = argv[++i];
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!args.css && !args.dart) throw new Error("Pass --css <file> and/or --dart <file>.");
  return args;
}

// ── Token access ─────────────────────────────────────────────────────────

function valueOf(entry) {
  return entry && typeof entry === "object" && "value" in entry ? entry.value : entry;
}

function noteOf(entry) {
  return entry && typeof entry === "object" && "note" in entry ? entry.note : null;
}

function resolve(tokens, value, seen = []) {
  const match = typeof value === "string" && value.match(/^\{([^}]+)\}$/);
  if (!match) return value;
  const path = match[1];
  if (seen.includes(path)) throw new Error(`Token reference cycle: ${[...seen, path].join(" -> ")}`);
  const target = path.split(".").reduce((node, key) => (node == null ? undefined : node[key]), tokens);
  if (target === undefined) throw new Error(`Unknown token reference {${path}}`);
  return resolve(tokens, valueOf(target), [...seen, path]);
}

function entries(group) {
  return Object.entries(group).filter(([key]) => !key.startsWith("$"));
}

function kebab(name) {
  return name.replace(/([a-z0-9])([A-Z])/g, "$1-$2").toLowerCase();
}

function capitalize(name) {
  return name.charAt(0).toUpperCase() + name.slice(1);
}

// ── CSS ──────────────────────────────────────────────────────────────────

function cssNote(note, indent) {
  // Wrapped like the hand-written comments in styles.css.
  const words = note.split(/\s+/);
  const lines = [];
  let line = "";
  for (const word of words) {
    if (line && (line + " " + word).length > 74) {
      lines.push(line);
      line = word;
    } else {
      line = line ? `${line} ${word}` : word;
    }
  }
  if (line) lines.push(line);
  return lines
    .map((text, index) => {
      const open = index === 0 ? "/* " : "   ";
      const close = index === lines.length - 1 ? " */" : "";
      return `${indent}${open}${text}${close}`;
    })
    .join("\n");
}

function cssColorLines(tokens, theme, indent) {
  return entries(tokens.color[theme]).flatMap(([name, entry]) => {
    const note = noteOf(entry);
    const line = `${indent}--${name}: ${resolve(tokens, valueOf(entry))};`;
    return note ? [cssNote(note, indent), line] : [line];
  });
}

function cssSharedLines(tokens, indent) {
  const lines = [];
  for (const [name, px] of entries(tokens.radius)) lines.push(`${indent}--radius-${name}: ${px}px;`);
  for (const [name, px] of entries(tokens.space)) lines.push(`${indent}--space-${name}: ${px}px;`);
  const stack = [`"${tokens.font.family}"`, ...tokens.font.webFallback].join(", ");
  lines.push(`${indent}--font-heading: ${stack};`);
  lines.push(`${indent}--font-body: ${stack};`);
  for (const [role, style] of entries(tokens.type)) {
    const prefix = `${indent}--type-${kebab(role)}`;
    lines.push(`${prefix}-size: ${style.size}px;`);
    lines.push(`${prefix}-weight: ${style.weight};`);
    if (style.height != null) lines.push(`${prefix}-line-height: ${style.height};`);
    if (style.tracking != null) lines.push(`${prefix}-tracking: ${style.tracking}px;`);
  }
  return lines;
}

const CSS_REGIONS = {
  light: (tokens, indent) => [...cssColorLines(tokens, "light", indent), ...cssSharedLines(tokens, indent)],
  dark: (tokens, indent) => cssColorLines(tokens, "dark", indent),
  comfort: (tokens, indent) => cssColorLines(tokens, "comfort", indent),
};

function renderCss(tokens, source) {
  let output = source;
  for (const [region, build] of Object.entries(CSS_REGIONS)) {
    const pattern = new RegExp(
      `([ \\t]*)/\\* design-tokens:${region} start[^*]*\\*/\\n[\\s\\S]*?[ \\t]*/\\* design-tokens:${region} end \\*/`,
    );
    const match = output.match(pattern);
    if (!match) throw new Error(`styles.css has no design-tokens:${region} start/end markers.`);
    const indent = match[1];
    const block = [
      `${indent}/* design-tokens:${region} start (generated: ${EDIT_HINT}) */`,
      ...build(tokens, indent),
      `${indent}/* design-tokens:${region} end */`,
    ].join("\n");
    output = output.replace(pattern, () => block);
  }
  return output;
}

// ── Dart ─────────────────────────────────────────────────────────────────

function dartColor(css) {
  const value = String(css).trim().toLowerCase();
  let hex = value.match(/^#([0-9a-f]{6})$/);
  if (hex) return `Color(0xFF${hex[1].toUpperCase()})`;
  hex = value.match(/^#([0-9a-f]{6})([0-9a-f]{2})$/);
  if (hex) return `Color(0x${(hex[2] + hex[1]).toUpperCase()})`;
  const rgba = value.match(/^rgba?\(\s*(\d+)\s*,\s*(\d+)\s*,\s*(\d+)\s*(?:,\s*([\d.]+)\s*)?\)$/);
  if (rgba) {
    const alpha = Math.round((rgba[4] == null ? 1 : Number(rgba[4])) * 255);
    const hexPart = [alpha, rgba[1], rgba[2], rgba[3]]
      .map((n) => Number(n).toString(16).padStart(2, "0"))
      .join("");
    return `Color(0x${hexPart.toUpperCase()})`;
  }
  throw new Error(`Cannot convert colour to Dart: ${css}`);
}


function dartDoc(note, indent) {
  const words = note.split(/\s+/);
  const lines = [];
  let line = "";
  const width = 80 - indent.length - 4;
  for (const word of words) {
    if (line && (line + " " + word).length > width) {
      lines.push(line);
      line = word;
    } else {
      line = line ? `${line} ${word}` : word;
    }
  }
  if (line) lines.push(line);
  return lines.map((text) => `${indent}/// ${text}`);
}

function dartColorClass(tokens, className, doc, group) {
  const lines = [`/// ${doc}`, `abstract final class ${className} {`];
  for (const [index, [name, entry]] of entries(group).entries()) {
    const note = noteOf(entry);
    // dart format puts a blank line before a doc comment inside a class.
    if (note && index > 0) lines.push("");
    if (note) lines.push(...dartDoc(note, "  "));
    lines.push(`  static const ${name} = ${dartColor(resolve(tokens, valueOf(entry)))};`);
  }
  lines.push("}");
  return lines.join("\n");
}

function renderDart(tokens) {
  const font = tokens.font;
  const fallback = font.appFallback.map((name) => `'${name}'`).join(", ");
  const shared = [
    "/// Shared scales: font, radii, spacing and type.",
    "abstract final class AppTokens {",
    `  static const fontFamily = '${font.family}';`,
    `  static const fontFamilyFallback = [${fallback}];`,
    "",
    ...entries(tokens.radius).map(([name, px]) => `  static const double radius${capitalize(name)} = ${px};`),
    "",
    ...entries(tokens.space).map(([name, px]) => `  static const double space${capitalize(name)} = ${px};`),
    "",
    ...entries(tokens.type).flatMap(([role, style]) => {
      const args = [`size: ${String(style.size)}`, `weight: FontWeight.w${style.weight}`];
      if (style.height != null) args.push(`height: ${String(style.height)}`);
      if (style.tracking != null) args.push(`tracking: ${String(style.tracking)}`);
      const oneLine = `  static const ${role} = AppTypeToken(${args.join(", ")});`;
      if (oneLine.length <= 80) return [oneLine];
      return [`  static const ${role} = AppTypeToken(`, ...args.map((arg) => `    ${arg},`), "  );"];
    }),
    "}",
  ].join("\n");

  const typeClass = [
    "/// One step of the type scale. Sizes and tracking are logical pixels.",
    "@immutable",
    "class AppTypeToken {",
    "  const AppTypeToken({",
    "    required this.size,",
    "    required this.weight,",
    "    this.height,",
    "    this.tracking,",
    "  });",
    "",
    "  final double size;",
    "  final FontWeight weight;",
    "  final double? height;",
    "  final double? tracking;",
    "}",
  ].join("\n");

  const app = tokens.app;
  return [
    "// GENERATED FILE. Do not edit by hand: edit design-tokens/tokens.json in",
    "// the website repo (it owns the tokens), copy it and generate.mjs here,",
    "// then run node design-tokens/generate.mjs --dart <this file>.",
    "",
    "import 'package:flutter/widgets.dart';",
    "",
    shared,
    "",
    typeClass,
    "",
    dartColorClass(tokens, "AppLightScheme", "Light ColorScheme roles.", app.light.scheme),
    "",
    dartColorClass(tokens, "AppDarkScheme", "Dark ColorScheme roles.", app.dark.scheme),
    "",
    dartColorClass(tokens, "AppLightSemantic", "Light success/warning colours.", app.light.semantic),
    "",
    dartColorClass(tokens, "AppDarkSemantic", "Dark success/warning colours.", app.dark.semantic),
    "",
  ].join("\n");
}

// ── Main ─────────────────────────────────────────────────────────────────

function main() {
  const args = parseArgs(process.argv.slice(2));
  const tokens = JSON.parse(readFileSync(TOKENS_PATH, "utf8"));
  const outputs = [];
  if (args.css) {
    const current = readFileSync(args.css, "utf8");
    outputs.push({ path: args.css, current, next: renderCss(tokens, current) });
  }
  if (args.dart) {
    const current = existsSync(args.dart) ? readFileSync(args.dart, "utf8") : null;
    outputs.push({ path: args.dart, current, next: renderDart(tokens) });
  }

  const stale = outputs.filter((output) => output.current !== output.next);
  if (args.check) {
    if (stale.length) {
      for (const output of stale) {
        console.error(`Stale design-token output: ${relative(process.cwd(), output.path)}`);
      }
      console.error(`Run: node design-tokens/generate.mjs${args.css ? ` --css ${args.css}` : ""}${args.dart ? ` --dart ${args.dart}` : ""}`);
      process.exit(1);
    }
    console.log("Design-token outputs are up to date.");
    return;
  }
  for (const output of stale) {
    writeFileSync(output.path, output.next);
    console.log(`Wrote ${relative(process.cwd(), output.path)}`);
  }
  if (!stale.length) console.log("Design-token outputs already up to date.");
}

main();
