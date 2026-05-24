# Stories Browser

A minimal, Storybook-like browser that mounts every page, modal, dialog, and component shipped from `user-interface` in isolation, with mock data and mock interactions wired in.

## Why it exists

The stories browser lets developers view, exercise, and visually compare each UI surface without launching the full application or seeding a real database. A jsdom registry test mounts every registered story to catch render-time crashes on every unit-test run, and a separate Electron-based shell smoke test cycles the live app through every story dwelling at each one.

## Entry points

The browser is deliberately not exposed to end users. There are exactly two ways in:

- **Web (dev-frontend):** type `#/stories` directly into the address bar. Default dev URL: `http://localhost:3000/#/stories`. To open a specific story, append `?id=<story-id>` after the hash route, e.g. `http://localhost:3000/#/stories?id=spinner/visible`.
- **Electron desktop app:** open the **Developer** menu and click **Stories**. The Developer menu already groups developer-facing actions (Reload / Force Reload / Toggle Developer Tools); ordinary users rarely open it. There is no keyboard shortcut, no sidebar link, and no toolbar button.

A **Back to app** link in the sidebar navigates back to `/`.

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
