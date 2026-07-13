# Forcing a theme with PHOTOSPHERE_THEME

`PHOTOSPHERE_THEME` forces the color theme the app starts in. Set it to `light`, `dark`, or `system` in the environment when you build or run a frontend.

- It **overrides the saved theme on startup** but is **never written to the config file**, so your saved theme is untouched.
- You can still change the theme in the app afterwards (that change saves, as normal).
- With the variable unset, the app starts from the saved theme (`system` by default).

It works the same on every platform because the value is baked into the frontend at build time (via each frontend's Vite `define`) and read by `packages/user-interface/src/lib/env-theme.ts`. Since `bun run` passes the environment through to the Vite build, prefixing the command is all that is needed. There is no theme query parameter.

## Running the app in a theme

Web (dev server):

```
PHOTOSPHERE_THEME=dark bun run dev:web
```

Electron desktop:

```
PHOTOSPHERE_THEME=dark bun run dev
```

Mobile (Capacitor builds and runs the frontend, so the same variable applies):

```
# Android
PHOTOSPHERE_THEME=dark bun run --filter=android-frontend launch
# iOS
PHOTOSPHERE_THEME=dark bun run --filter=ios-frontend launch
```

Because the theme is baked in at build time, changing `PHOTOSPHERE_THEME` requires a rebuild (re-run the command).

## Running a smoke test in a theme

The same variable works for the smoke tests:

```
PHOTOSPHERE_THEME=dark bun run test:electron
PHOTOSPHERE_THEME=light bun run test:android
PHOTOSPHERE_THEME=dark bun run stories
```

The story player (`bun run stories`) switches theme at runtime and captures every story in both light and dark, so it needs no theme override; see `packages/user-interface/src/stories/README.md`.
