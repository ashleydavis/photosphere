# Stories Browser

A minimal, Storybook-like browser that mounts every page, modal, dialog, and component shipped from `user-interface` in isolation, with mock data and mock interactions wired in.

## Why it exists

The stories browser lets developers view, exercise, and visually compare each UI surface without launching the full application or seeding a real database. A jsdom registry test mounts every registered story to catch render-time crashes on every unit-test run, and a separate Electron-based shell smoke test cycles the live app through every story dwelling at each one.

## Entry points

The browser is deliberately not exposed to end users. There are exactly two ways in:

- **Web (dev-frontend):** type `#/stories` directly into the address bar. Default dev URL: `http://localhost:3000/#/stories`. To open a specific story, append `?id=<story-id>` after the hash route, e.g. `http://localhost:3000/#/stories?id=spinner/visible`.
- **Electron desktop app:** open the **Developer** menu and click **Stories**. The Developer menu already groups developer-facing actions (Reload / Force Reload / Toggle Developer Tools); ordinary users rarely open it. There is no keyboard shortcut, no sidebar link, and no toolbar button.

A **Back to app** link in the sidebar navigates back to `/`.

## Play on automatic

The sidebar has a **▶ Play on automatic** button that walks every story in order, dwelling briefly on each, and reports how many passed or failed at the end. By default it shows each story in **light and then dark**; when `PHOTOSPHERE_THEME` forces a single theme (the screenshot passes) it walks only that theme. During playback the only control is **Cancel**; the completion screen has a **Back to browser** button. Under the hood this just sets the `?cycle=1` query param the cycle reads, so it works identically in the web and Electron builds.

## Theming

The browser has a **light/dark toggle button** (top-right, left of the dev-tools button) to switch theme while viewing stories; it uses MUI Joy's `setMode` and writes localStorage only, never the config file.

The initial color mode is controlled by the `PHOTOSPHERE_THEME` build-time env var (`light`, `dark`, or `system`), the same mechanism used app-wide (see `docs/theme-override.md`). When set, it is applied on startup over the saved theme and is never written to the config file; when unset the stories page uses the system theme. There is no theme query param.

## Light and dark screenshots

The screenshot smoke test captures every story in both themes by rebuilding the frontend once per theme (with `PHOTOSPHERE_THEME` set) and cycling each:

- `bun run test:stories -- --screenshots <dir>` runs two passes (light then dark) and writes them to `<dir>/light/...` and `<dir>/dark/...`. Screenshots are on by default, so `bun run test:stories` alone also captures both into `apps/desktop/stories-screenshots/`.
- `bun run test:stories -- --theme light` (or `--theme dark`) captures a single theme.
- `--duration <ms>` sets the dwell per story; `--open` opens the generated index when done.

When both themes are captured, an `index.html` is generated at the root of the screenshots directory showing each story's light and dark shots **side by side**, with a search box that filters by story id. Open it in a browser to review every story in both themes at once.

## Outside the provider stack

The `/stories` route is mounted at the top level of each consuming frontend, sibling to (not child of) the normal context provider stack. Each story's `render` function is responsible for wrapping its content in whatever providers it needs. The shared `MockProviders` wrapper in `./mocks` is the default; stories that want to vary mocks pass overrides to `MockProviders` or use the underlying real provider with a custom value.

Without this isolation, stories would inherit the live `AssetDatabaseProvider` and other production contexts and would render against real (or partially-mocked) application state, which defeats the purpose of the browser.

## Adding a new story

1. Create `<name>.stories.tsx` under the appropriate subdirectory (`pages/`, `modals/`, `dialogs/`, or `components/`).
2. Export `const stories: IStory[]`. Each entry needs `id`, `name`, `category`, and `render`.
3. Add one import + one spread to `src/stories/index.ts`.

Story `id` values must be globally unique. The convention is `<component-file-name>/<variant>`, lowercased and kebab-cased.

## Comprehensive coverage

Every page, modal, dialog, and component shipped from `user-interface` must have at least one story. The `registry.test.ts` test reads the source directory at test time and fails when a new component or page is added without a matching story prefix. The same test mounts every registered story to catch render-time crashes.
