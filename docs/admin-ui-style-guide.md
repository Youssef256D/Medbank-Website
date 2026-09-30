# Admin UI style guide and open work

Written 2026-09-30 during the admin redesign on branch `claude/admin-grouped-sidebar`, so the work can continue in another session. The history of what was built is in AGENTS.md (refactor log, 2026-09-29 and 2026-09-30 entries) and CHANGELOG.md.

## Open task: flatten nested boxes on every admin page

The owner said the pages look like "boxes inside boxes inside boxes". Not started (three delegated runs were stopped before finishing; nothing from them was kept). Measured box depth inside `.admin-main` (1 = the page card): Course Builder 5, Bulk Import 3, Site Access 3; MCQ Subjects 2 with 14 boxed cards; Catalog 7 boxes; Activity 6; Dashboard 5. Target: depth <= 2 everywhere and no lists of boxed items. Approved target for MCQ Subjects: filters as one toolbar row, subjects as a divided list ("Name CODE", muted "4 topics · 8 questions", amber "no questions yet", chevron instead of OPEN). Suggested split: (A) Dashboard, MCQ Subjects, Questions, Bulk Import; (B) Users, Universities, Notifications, Pop-ups, Site Access, Hermes, Activity, Logs; (C) all Video Courses sections. The owner wants execution delegated (Codex preferred).

```text
=== MEDBANK ADMIN UI STYLE GUIDE (applies to this task) ===

REPO FACTS
- Static SPA served as-is (GitHub Pages). `main.js` (~57k lines) is ONE plain classic <script>, flat global scope, one mutable `state`, one `render()`. Admin page HTML is built in `renderAdmin()` (a big `if (activeAdminPage === "...")` chain setting `pageContent`), handlers are bound in `wireAdmin()` after each render via `appEl.querySelectorAll(...)`.
- Escape EVERY dynamic string that goes into HTML with `escapeHtml()`. `escapeHtml(0)` returns "" — convert numbers with `String(n)` first.
- Themes: light / body.theme-comfort / body.theme-dark. Use only CSS tokens: --ink, --muted, --line, --surface, --surface-strong, --brand, --brand-strong, --brand-soft, --danger, --radius-sm, --radius-md. Never add `font-weight` with !important (a global rule forces 400). A global rule forces `.btn.ghost { background: transparent !important }`.
- Do NOT touch Supabase queries/RLS/migrations, sw.js, bootstrap.js, supabase.config.js, index.html, AGENTS.md, CLAUDE.md, CHANGELOG.md, docs/. Do NOT commit, stage or branch.
- `tests/app-popups-utils.test.js` evaluates the main.js text BETWEEN the marker line "// Mobile pop-up administration." and "function renderAdminSidebarNav". Do not add calls to helpers defined outside that region inside it, and do not add code between those markers unless the tests still pass.

SHARED HELPERS — ALREADY EXIST, REUSE THEM (grep for them; do not create duplicates or rename them)
- `renderAdminPageHeader({ id, title, count = null, actions = "", notes = [] })` → page header: title + muted "· count", icon actions on the right, and an ⓘ button that toggles a collapsible "How this page works" note (notes = array of TRUSTED html strings; open state remembered per page id). Example use: `renderAdminUniversitiesSection()`, and the Users page header in renderAdmin.
- `renderAdminIconButton({ icon, label, attrs = "", variant = "", busy = false })` → round icon button (aria-label + title = label). icons: plus, refresh, info, more, filter, download, settings, search, x. `variant: "primary"` = filled brand circle (use for the single main "add" action only). `busy` spins the refresh icon. If you truly need another icon, add ONE entry to the `icons` object inside this function.
- `renderAdminRowMenu({ id, label, items })` → "⋯" button + popup menu. items = [{ label, attrs, danger, disabled }]. `attrs` carries the EXISTING data-action/data-* attributes so the EXISTING click handlers keep working unchanged (handlers bound with `appEl.querySelectorAll("[data-action='x']")` also bind to menu items, and `button.closest("tr[...]")` still works because the menu lives inside the row). Danger items are placed last after a divider. Example: universities rows, users rows.
- `renderAdminDialog({ id, title, subtitle = "", body = "", actions = "", closeAction = "" })` → centered dialog; backdrop and × both carry `data-action=closeAction`. RULE: dialogs MUST be rendered into the `adminGlobalOverlay` variable in renderAdmin (outside the admin shell) — NEVER inside page content (a hovered card gets a CSS transform and the panel has backdrop-filter; both trap position:fixed dialogs). Open state lives in `state`, so a re-render keeps it open. Any handler that looks up the dialog/form must use `appEl.querySelector`, NOT a section element (the dialog is outside the section). Examples: Users dialogs (`usersFiltersDialogHtml`, `adminUsersDialogSpecs` in wireAdmin) and Universities (`renderAdminUniversityDialog`, `wireAdminUniversities`).

DESIGN RULES (the look the owner approved on Users and Universities)
1. One header per page via renderAdminPageHeader: short title, a count where meaningful, icon actions (refresh, + add as primary). No long subtitle paragraphs.
2. All explanatory/help sentences go into the header `notes` (short bullets, plain language). Keep only field-level hints next to the fields they explain.
3. Tables/lists are read-only and calm. Replace rows of per-row buttons with ONE ⋯ menu (renderAdminRowMenu). At most one small inline action when it is the obvious next step (e.g. "Approve" on a pending item).
4. Colour carries meaning only: one primary action per view; red only for destructive actions (inside ⋯ menus or confirm dialogs), never a wall of red buttons; statuses as a small coloured dot + text rather than big filled badges.
5. Create/edit forms that are not the page's main content open in a dialog (renderAdminDialog via adminGlobalOverlay), opened by the + icon or a ⋯ "Edit" item. Keep the SAME form ids/field names/submit handlers so existing logic works; only fix lookups to use appEl.
6. Speed: never render unbounded lists — show the newest ~50–100 with a "Show more (N)" button (count in state, reset on page change). No per-row expensive work.
7. Phones (<=640px): no horizontal page overflow at 375px, 44px tap targets.
8. Behaviour must not change: same data-actions, same confirms, same writes. This is a UI reorganisation.

CSS: put ALL new rules in ONE block appended at the very END of styles.css, starting with the comment given in your task (e.g. `/* Admin MCQ Bank pages */`). Other jobs append their own blocks in parallel.

GATES (repo root, all must pass): node --check main.js ; npm run lint ; npm test

REPORT CONTRACT: for each page: what changed, which handlers you had to touch and why, anything you could NOT do or deliberately left alone, and the gate output tails. Say explicitly if any numbered task item was skipped.

=== NEW RULE FOR THIS TASK: "ONE BOX LEVEL" (flatten nested boxes) ===
The owner's feedback: pages look like "boxes inside boxes inside boxes". Differentiate with SPACING, ALIGNMENT and TYPE instead of borders.
Measured today (box depth inside `.admin-main`, where 1 = the page card itself): Course Builder 5, Bulk Import 3, Site Access 3; MCQ Subjects 2 but 14 separately boxed cards; Catalog 7 boxes; Activity 6; Dashboard 5. TARGET: depth <= 2 on every page (the page card + at most one inner surface such as the ⓘ help note or a single highlighted panel), and NO lists of individually boxed items.
Concretely:
F1. Inside the page card, containers that only GROUP content get no border, no background, no shadow. Separate groups with a small section title (reuse `.admin-settings-section-title` style: 0.72rem uppercase muted, letter-spacing) + vertical space + at most a single hairline `border-top: 1px solid var(--line)` between groups.
F2. Collections (subjects, courses, cards of stats, lists of items) render as ROWS separated by hairline dividers (`border-bottom: 1px solid var(--line)`), not as a grid of bordered cards. Whole row clickable where it opens something, with a chevron (›) on the right instead of an "OPEN" label; hover = subtle background (var(--brand-soft)).
F3. Metadata/counts as plain muted text joined with " · " (e.g. "4 topics · 8 questions"), not pill/badge chips. Keep coloured status only as dot + text. Highlight a problem in text colour (e.g. amber/warn for "no questions yet") — use an existing themed token such as --approval-gap-fg or define one token for light/comfort/dark, never a filled pill.
F4. Filters as ONE toolbar row (compact selects + search, like the Users toolbar `.admin-users-toolbar-search`) directly under the header, with no wrapping card and no visible field labels (keep aria-label on each control).
F5. Inputs, buttons, tables, dialogs, menus, the header and the help note keep their own styling — this rule is about decorative/grouping boxes. Tables use row dividers only, no outer box inside the page card.
F6. Existing `.card` elements nested inside the page card are the usual culprit: remove the class or add a modifier that drops border/background/shadow/padding — do not add a global CSS rule that changes `.card` everywhere.
Keep all ids, data-actions, handlers and behaviour exactly as they are.
```
