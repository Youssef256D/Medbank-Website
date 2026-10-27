# Design tokens

`tokens.json` is the one source for MedBank's colours (light, dark and the
website-only comfort theme), radii, spacing, type scale and font, for both the
website and the Flutter app (`Youssef256D/Medbank-App`).

`generate.mjs` (Node, no dependencies) writes:

- **Website:** the marked `design-tokens:light|dark|comfort` regions inside the
  `:root`, `body.theme-dark` and `body.theme-comfort` blocks of `styles.css`.
  Everything outside the markers (shadows, aliases, other variables) is
  hand-written as before.
- **App:** `lib/core/theme/app_tokens.g.dart` (`AppTokens`, `AppTypeToken`,
  `AppLightScheme`/`AppDarkScheme`, `AppLightSemantic`/`AppDarkSemantic`).

## Changing a token

1. Edit `tokens.json` here (the website repo owns it).
2. `npm run tokens` — rewrites the `styles.css` regions; bump `app-version`.
3. Copy `tokens.json` and `generate.mjs` to the app repo's `design-tokens/`,
   then there run
   `node design-tokens/generate.mjs --dart lib/core/theme/app_tokens.g.dart`.
4. Merge the website change first: the app's CI compares its copies with the
   website's `main`.

## CI

- Website (`validate-changes.yml`): `npm run tokens:check` fails if
  `styles.css` differs from what `tokens.json` generates.
- App (`ci.yml`): fails if `app_tokens.g.dart` is stale, or if its
  `tokens.json` / `generate.mjs` differ from the website's `main`.

The `app` section holds the Flutter ColorScheme roles. Where a role is the
same colour as a website variable it is a `{color.<theme>.<name>}` reference;
the app's dark theme keeps a teal brand where the website's goes grey, so its
values are its own.
