# design-sync notes — MedBank

This is a **tokens/styles-only** design system: MedBank is a vanilla-JS SPA with
**no React components**, so the sync ships only the stylesheet closure
(`_ds_bundle.css` = a verbatim copy of the repo's `styles.css`) + `styles.css`
(which `@import`s it) + `guidelines/`. `components/`, `tokens/`, and previews are
always empty. `shape: package`, entry is the stub `.design-sync/ds-entry.js`
(`export {}`), `--node-modules .ds-sync/node_modules` (React lives there for the
vendor step; the repo root has no `node_modules`).

## Re-sync = one command
- Source of truth is the repo `styles.css` (`cfg.cssEntry`). When it changes, the
  bundle changes; otherwise the build is a deterministic no-op.
- Build: `node .ds-sync/package-build.mjs --config .design-sync/config.json --node-modules .ds-sync/node_modules --entry .design-sync/ds-entry.js --out ./ds-bundle`
- Then validate with `--no-render-check` (nothing to render — 0 components).

## Known render/validate warns (recorded — not new)
- `[RENDER_SKIPPED]`: expected — tokens-only DS has no previews to render.
- (No `[TOKENS_MISSING]` / `[FONT_MISSING]` as of 2026-07-05 — see History.)

## History
- 2026-07-05: Corrected `runtimeFontPrefixes` to `["Source Sans 3", "Inter"]`
  (the fonts `index.html` actually serves at runtime via Google Fonts). Dropped
  the stale `"Bricolage Grotesque"` (removed from the app long ago) which had been
  silently emitting `[FONT_MISSING]` for `"Source Sans 3"`. Removed the prior
  run's dead `.design-sync/missing-tokens.css` + `cfg.tokensGlob`: `copyTokens`
  ignores `tokensGlob` unless `cfg.tokensPkg` is also set, so it never reached the
  closure — and its invented hexes didn't match the real palette.
- 2026-07-05: The `[TOKENS_MISSING] 7` warning (`--text, --border, --brand-dark,
  --accent-strong, --shadow-tiny, --radius-xs, --shadow-medium`) was an app-source
  bug, not a sync artifact — those names were used in `styles.css` but only
  differently-named canonical tokens were ever defined (`--ink`, `--line`,
  `--brand-strong`, `--accent`, `--shadow-soft`, `--radius-sm`, `--shadow`). Fixed
  at the source: added the 7 as `:root`-level aliases in `styles.css` (e.g.
  `--text: var(--ink);`). Since the canonical tokens are redefined per theme
  (`body.theme-dark`, `body.theme-comfort`), the single `:root` alias resolves
  correctly in every theme with no per-theme duplication. See AGENTS.md refactor
  log entry "2026-07-05 — CSS custom-property alias fix" for full detail.
  `app-version` bumped to `2026-07-05.01`.

## Re-sync risks (watch-list for the next run)
- **Font drift**: if the app swaps fonts again (it has before —
  Manrope/Sora → Bricolage → Geist mentions → Source Sans 3), re-check
  `index.html` `family=` links and keep `runtimeFontPrefixes` in sync, or
  `[FONT_MISSING]` returns.
- **New orphan tokens**: if `[TOKENS_MISSING]` fires again on a future sync with
  *different* names than the 7 fixed above, that's a new app-source bug worth the
  same investigation (grep for the referenced name, find the intended canonical
  token, add a `:root` alias) — not something to paper over with invented values.
- **No durable token-injection lever**: there is no config-only way to ship a
  standalone token file into the `styles.css` closure (needs `tokensPkg` → a real
  node_modules package). Any future gap belongs in the app source, not a
  synthetic tokens file.
