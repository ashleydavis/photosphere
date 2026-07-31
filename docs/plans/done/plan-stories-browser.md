# Stories Browser for user-interface

## Overview

Add a minimal, Storybook-like stories browser to the `user-interface` package so every page, modal, dialog, and UI component can be viewed in isolation with mock data and mock interactions wired in. Each story is a self-contained React render function. Stories are registered manually in a central index. The browser is mounted at a hidden `/stories` route in each consuming frontend app, deliberately positioned **outside the normal provider stack** so each story owns and controls the providers it needs (real or mocked). Discovery requires deliberate action and there is no keyboard shortcut: the web frontend is reached by typing `#/stories` in the address bar, and the Electron desktop app is reached via the existing **Developer** menu (a new **Stories** item alongside Reload / Toggle Developer Tools). No sidebar link, no toolbar button, no in-app affordance for end users. A comprehensive registry test mounts every registered story under jsdom so any render-time error fails the build, and a separate shell smoke test cycles the live Electron app through every story dwelling at each one. Every page, modal, dialog, and component listed under `packages/user-interface/src/pages/` and `packages/user-interface/src/components/` must have at least one story.

## Issues

<!-- Populated later by plan:check -->

## Steps

### 1. Create `packages/user-interface/src/stories/types.ts`

Define the `IStory` interface. Fields:

- `id`: globally unique kebab-case slug used as URL query value and React list key. Convention: `<component-name>/<variant>` (example: `"spinner/visible"`, `"gallery-page/empty"`).
- `name`: short human-readable label shown in the list.
- `category`: group label shown as a header in the list. Must be one of: `"Pages"`, `"Modals"`, `"Dialogs"`, `"Components"`.
- `render`: function returning `React.ReactNode` for the story body. The function is responsible for wrapping its content in any context providers it needs and for supplying mock data and event handlers.

Every interface field and the interface itself must have a `//` comment block, per project style.

### 2. Create `packages/user-interface/src/stories/mocks/index.tsx`

Reusable mock helpers consumed by story files. Implementations are minimal stubs whose only job is to let the wrapped component mount and respond to user interaction without crashing.

Export:

- `MockProviders` component: wraps `children` in a `MemoryRouter` (from `react-router-dom`) plus mock instances of every context provider exported by `user-interface` (`UuidGeneratorProvider`, mock `PlatformProvider`, `AppContextProvider`, `ToastContextProvider`, mock `AssetDatabaseProvider`, `ImportContextProvider`, `GalleryContextProvider`, `DeleteConfirmationContextProvider`, `SearchContextProvider`, `GalleryLayoutContextProvider`, plus `CssVarsProvider` from `@mui/joy/styles`). Accepts optional override props for individual context values so a story can swap in custom mocks while keeping the rest of the stack.
- `mockPlatform()`: returns a fake platform implementation whose every method is a no-op or returns a resolved promise. Subscriber methods (`onShowNotification`, `onMenuAction`, `onNavigate`, `onThemeChanged`) return an unsubscribe function.
- `mockAsset(overrides)`: returns a fake `IAsset` record with sensible defaults and accepts a partial override.
- `mockGalleryItem(overrides)`: returns a fake `IGalleryItem` with sensible defaults and accepts a partial override.
- `mockAssets(count)`: returns an array of `count` fake assets with deterministic ids.
- `noOp` and `noOpAsync`: shared empty handlers (`() => {}` and `async () => {}`) to use for callback props.

The full real `AssetDatabaseProvider` is too tightly coupled to real storage to use here; the mock version exposes the same `useAssetDatabase` hook shape but returns canned in-memory data and resolved-promise method stubs.

Every exported symbol must have a `//` comment block.

### 3. Create `packages/user-interface/src/stories/index.ts`

Export `const stories: IStory[]` containing every story in the registry, in the order they should appear within each category. Each story file exports its own `stories: IStory[]`; this index imports each module under an aliased name and spreads them into the flat exported array. No bundler-specific glob; registration is one import + one spread per story file. The file initially imports nothing other than the type; the per-component imports are added incrementally as each story file is created in steps 11 to 14.

### 4. Create `packages/user-interface/src/stories/stories-page.tsx`

Export the `StoriesPage` component. Structure:

- Wrap nothing implicitly. The page must function with no parent providers other than React Router (which it relies on for `useSearchParams` and `useNavigate`). Every provider a story needs is supplied by that story's `render` function (often via `MockProviders` from step 2).
- Two-pane layout. Left pane is a fixed-width sidebar (~280px) containing a text search input at the top, a "Back to app" link below it that navigates to `/`, and the filtered, category-grouped story list below that. Right pane fills remaining width and renders the selected story.
- Selected story id is read from and written to the URL query (`?id=<story-id>`) using `useSearchParams`. This makes individual stories linkable.
- Search input filters the visible list by case-insensitive substring match on `id`, `name`, and `category`. The currently selected story remains visually highlighted even when filtered out of the list.
- List items are grouped under `<h3>` headers per `category`, with categories rendered in the order: `Pages`, `Modals`, `Dialogs`, `Components`.
- Clicking an item updates the URL query and marks that row as active. Active row has a distinct background/text colour using existing Tailwind utility classes.
- When no `?id=` is present, the right pane shows a placeholder `"Select a story"` message.
- When `?id=` is set but matches no registered story, the right pane shows a message including the offending id, for example `"Unknown story: <id>"`.
- The right-pane container has `key={selectedStory.id}` so React fully unmounts the previous story when switching, preventing state bleed between stories.
- Styling uses existing Tailwind utility classes and the MUI Joy theme variables used elsewhere in the codebase. No new CSS file. `StoriesPage` wraps its own root in `CssVarsProvider` from `@mui/joy/styles/CssVarsProvider` so MUI components work without depending on the app-level provider.

The component and any helper functions must each have a `//` comment block.

### 5. Export `StoriesPage` from `packages/user-interface/src/index.tsx`

Add `export { StoriesPage } from "./stories/stories-page";` so the consuming frontend apps can import it. Also remove any prior reference to a `/stories` route inside `main.tsx`; the route now lives at the top level of each consuming app, not inside the `__Main` shell.

### 6. Update `apps/dev-frontend/src/app.tsx` to mount `/stories` outside the provider stack

Restructure the JSX returned by `App` so the top-level layout is:

```
HashRouter
  Routes
    Route path="/stories" element={<StoriesPage />}
    Route path="*" element={
        UuidGeneratorProvider
          PlatformProviderWeb
            AppContextProvider
              ToastContextProvider
                AssetDatabaseProvider
                  ImportContextProvider
                    GalleryContextProvider
                      DeleteConfirmationContextProvider
                        SearchContextProvider
                          GalleryLayoutContextProvider
                            Main isMobile={false} initialTheme={initialTheme}
    }
```

Import `StoriesPage` from `user-interface`. The provider stack is unchanged inside the `*` route. Order matters: the `/stories` route must come before the catch-all so it matches first.

### 7. Update `apps/desktop-frontend/src/app.tsx` to mount `/stories` outside the provider stack

Apply the same top-level restructuring as step 6, using the desktop-frontend's existing `PlatformProviderElectron` and `ElectronRendererQueueBackend` in the `*` route. Import `StoriesPage` from `user-interface`. The `mobile` and `frontend` directories under `apps/` are build-output only and require no changes.

### 8. Add a "Stories" entry to the Electron Developer menu

In `apps/desktop/src/main.ts`, locate the `developerSubmenu` array (currently around line 1512, alongside Reload / Force Reload / Toggle Developer Tools). Append a new menu item:

- Label: `Stories`
- Click handler: `mainWindow.webContents.send('menu-action', 'open-stories')`

This piggybacks on the existing menu-action IPC channel already used for other menu items (`new-database`, `open-database`, `import-assets`, `open-configuration`). The Developer menu is the right home because it groups developer-facing actions; ordinary users rarely open it. There is no keyboard accelerator, no toolbar button, and no in-app link, so it cannot be triggered accidentally.

### 9. Handle the `open-stories` menu action in `packages/user-interface/src/main.tsx`

Extend the existing `switch (action)` block inside the `onMenuAction` effect in `__Main` (around line 180) to add a new case:

- `case 'open-stories':` calls `navigate('/stories')` and `break;`.

Even though `__Main` is mounted inside the provider stack and `/stories` is mounted outside it, calling `navigate('/stories')` works correctly: React Router updates the URL, the top-level `<Routes>` switch in `app.tsx` re-matches, the provider-wrapped subtree unmounts, and the bare `StoriesPage` renders in its place. No additional plumbing is needed.

### 10. Create `packages/user-interface/src/stories/README.md`

Plain markdown document covering:

- What the stories browser is and why it exists.
- Entry points (the only two routes in):
  - **Web (dev-frontend):** type `#/stories` in the address bar. Full URL example: `http://localhost:3000/#/stories`. To open a specific story directly, append `?id=<story-id>` after the hash route.
  - **Electron desktop app:** open the **Developer → Stories** menu item. The Developer menu is intentionally not exposed elsewhere; there is no keyboard shortcut, toolbar button, or in-app link, so end users cannot reach the stories browser by accident.
- The "Back to app" link inside the stories page navigates back to `/`.
- The route is mounted **outside** the provider stack, so each story is responsible for wrapping its content in whatever providers it needs. Use `MockProviders` from `./mocks` as the default wrapper.
- How to add a new story: create a `<name>.stories.tsx` file under `src/stories/`, export `const stories: IStory[]`, then add one import + spread to `src/stories/index.ts`. Story `id` values must be globally unique across all story files.
- Every page, modal, dialog, and component shipped from `user-interface` must have at least one story; the `registry.test.ts` test fails if any registered story crashes on mount.

### 11. Create story files for every Page

One `<page-name>.stories.tsx` file per page under `packages/user-interface/src/stories/pages/`. Each file exports `const stories: IStory[]`. Every entry uses `category: "Pages"` and wraps its rendered page in `<MockProviders>` with whatever mock context overrides are needed for the page to render meaningfully.

Files to create, with at least the listed stories (more variants may be added when an obvious empty/loading/loaded state exists):

- `about.stories.tsx` — `about-page/default` renders `<AboutPage />`.
- `configuration.stories.tsx` — `configuration-page/default` renders `<ConfigurationPage />`.
- `databases.stories.tsx` — `databases-page/empty` (no databases in mock list), `databases-page/with-databases` (mock list of three databases).
- `database-summary.stories.tsx` — `database-summary-page/default` renders `<DatabaseSummaryPage />` with a mock asset database containing a fixed summary.
- `gallery.stories.tsx` — `gallery-page/empty` (mock gallery with zero items), `gallery-page/with-assets` (mock gallery with 24 items from `mockAssets(24)`), `gallery-page/loading` (mock gallery in a loading state).
- `import.stories.tsx` — `import-page/idle` (no import in progress), `import-page/in-progress` (mock import context with several items in `pending`/`success`/`failed` states).
- `map.stories.tsx` — `map-page/default` renders `<MapPage />` with a mock gallery of geo-tagged assets.
- `news.stories.tsx` — `news-page/default` renders `<NewsPage />`.
- `secrets.stories.tsx` — `secrets-page/empty`, `secrets-page/with-secrets`.

### 12. Create story files for every Modal

One `<modal-name>.stories.tsx` file per modal under `packages/user-interface/src/stories/modals/`. Every entry uses `category: "Modals"`, sets `open={true}` and provides no-op `onClose` handlers. Wrap each in `<MockProviders>` where the modal consumes context.

Files to create, at minimum one story each:

- `add-database-modal.stories.tsx` — `add-database-modal/open`.
- `configure-secrets-modal.stories.tsx` — `configure-secrets-modal/open`.
- `create-database-modal.stories.tsx` — `create-database-modal/open`.
- `edit-database-modal.stories.tsx` — `edit-database-modal/open` (mock current database record).
- `open-database-modal.stories.tsx` — `open-database-modal/open`.
- `s3-browser-modal.stories.tsx` — `s3-browser-modal/open` (mock S3 listing).
- `select-secret-modal.stories.tsx` — `select-secret-modal/open` (mock secret list).
- `cluster-modal.stories.tsx` — `cluster-modal/open` (mock cluster of three assets), wrapping `ClusterModal` from `pages/map/cluster-modal`.

### 13. Create story files for every Dialog

One `<dialog-name>.stories.tsx` file per dialog under `packages/user-interface/src/stories/dialogs/`. Every entry uses `category: "Dialogs"`, sets `open={true}`, provides no-op handlers, and wraps in `<MockProviders>` where needed.

Files to create, at minimum one story each unless multiple states are noted:

- `configuration-dialog.stories.tsx` — `configuration-dialog/open`.
- `create-secret-dialog.stories.tsx` — `create-secret-dialog/open`.
- `delete-confirmation-dialog.stories.tsx` — `delete-confirmation-dialog/single-item` (`numItems={1}`), `delete-confirmation-dialog/many-items` (`numItems={42}`).
- `receive-database-dialog.stories.tsx` — `receive-database-dialog/open`.
- `receive-secret-dialog.stories.tsx` — `receive-secret-dialog/open`.
- `remove-database-dialog.stories.tsx` — `remove-database-dialog/open`.
- `replicate-database-dialog.stories.tsx` — `replicate-database-dialog/open`.
- `set-location-dialog.stories.tsx` — `set-location-dialog/empty`, `set-location-dialog/with-existing-location`.
- `set-photo-date-dialog.stories.tsx` — `set-photo-date-dialog/empty`, `set-photo-date-dialog/with-existing-date`.
- `share-database-dialog.stories.tsx` — `share-database-dialog/open`.
- `share-secret-dialog.stories.tsx` — `share-secret-dialog/open`.
- `view-database-dialog.stories.tsx` — `view-database-dialog/open` (mock database record).
- `view-secret-dialog.stories.tsx` — `view-secret-dialog/open` (mock secret record).

### 14. Create story files for every Component

One `<component-name>.stories.tsx` file per component under `packages/user-interface/src/stories/components/`. Every entry uses `category: "Components"`. Components that consume context get wrapped in `<MockProviders>` with overrides as needed; pure presentational components (`Spinner`, `Fps`) need no wrapper.

Files to create, at minimum the listed stories:

- `asset-view.stories.tsx` — `asset-view/image`, `asset-view/video`.
- `carousel.stories.tsx` — `carousel/single-image`, `carousel/multiple-files`.
- `collapsible-section.stories.tsx` — `collapsible-section/collapsed`, `collapsible-section/expanded`.
- `empty-database.stories.tsx` — `empty-database/default`.
- `film-strip.stories.tsx` — `film-strip/default` (mock gallery items).
- `fps.stories.tsx` — `fps/default`.
- `full-image.stories.tsx` — `full-image/default`.
- `full-screen-spinner.stories.tsx` — `full-screen-spinner/visible`.
- `gallery.stories.tsx` — `gallery-component/empty`, `gallery-component/populated`.
- `gallery-image.stories.tsx` — `gallery-image/default`, `gallery-image/selected`.
- `gallery-layout.stories.tsx` — `gallery-layout/default`.
- `gallery-preview.stories.tsx` — `gallery-preview/default`.
- `gallery-scrollbar.stories.tsx` — `gallery-scrollbar/default`.
- `left-sidebar.stories.tsx` — `left-sidebar/open`.
- `navbar.stories.tsx` — `navbar/default`.
- `no-database-loaded.stories.tsx` — `no-database-loaded/default`.
- `right-sidebar.stories.tsx` — `right-sidebar/open` (mock selected asset).
- `spinner.stories.tsx` — `spinner/visible` (`show={true}`), `spinner/hidden` (`show={false}`).
- `toast-container.stories.tsx` — `toast-container/empty`, `toast-container/with-toasts` (seed mock toast context with one success, one error, one info toast).
- `video.stories.tsx` — `video/default`.
- `asset-info.stories.tsx` — `asset-info/default` (wraps `pages/gallery/components/asset-info`).
- `map-view.stories.tsx` — `map-view/default` (wraps `pages/map/map-view` with mock items).

### 15. Update `packages/user-interface/src/stories/index.ts` to register every story

Add one import + one spread per story file from steps 11 to 14, using aliased names of the form `<file-name>Stories` (for example `import { stories as galleryPageStories } from "./pages/gallery.stories"`). Spread them into the exported `stories` array in this order: all Pages, all Modals, all Dialogs, all Components. Within each category, follow alphabetical order by file name.

### 16. Add cycle mode to `StoriesPage`

Extend `packages/user-interface/src/stories/stories-page.tsx` to support an automated cycle mode used by the shell smoke test (step 17). When the URL query contains `cycle=1`:

- Read optional `duration=<ms>` query param. Default `1000`.
- Render a dedicated `<StoriesCycle stories={stories} durationMs={duration} />` component instead of the normal two-pane layout. The component is defined in the same file (small enough not to need its own file).
- `StoriesCycle` walks `stories` array sequentially. For each story:
  - Mounts the story inside a React class component error boundary (`StoryErrorBoundary`, defined in the same file) that captures `componentDidCatch` errors.
  - Registers `window.addEventListener('error', ...)` and `window.addEventListener('unhandledrejection', ...)` for the duration of each story to catch async errors that the error boundary cannot see. Listeners are removed before advancing.
  - Waits `durationMs` via `setTimeout` to give async render work (images, MUI Joy transitions, network-style hooks) time to settle.
  - Emits one of two log lines via `log.event` from `utils`: `STORIES CYCLE OK: <id>` on success, `STORIES CYCLE FAILED: <id>: <error message>` on failure.
- Before the first story: `STORIES CYCLE START: <count> stories, <duration>ms each`.
- After the last story: `STORIES CYCLE COMPLETE: <pass> passed, <fail> failed`.

Use the existing `log` import from `utils` so messages flow into the renderer log that the desktop smoke-test harness already watches. The `StoryErrorBoundary` class and the `StoriesCycle` function component both need `//` comment blocks.

### 17. Add `apps/desktop/cycle-stories-smoke-test.sh`

A new standalone shell smoke test, separate from the regular suite under `apps/desktop/smoke-tests/`. Lives at `apps/desktop/cycle-stories-smoke-test.sh`. It is intentionally not registered in the numbered smoke-test sweep because the cycle is expected to be long-running (50 stories x ~1 s + Electron startup ~= 1 minute or more).

Behaviour:

- Sources `apps/desktop/smoke-tests/lib/common.sh` for shared helpers.
- Accepts an optional `--duration <ms>` arg (default `1000`).
- Calls `start_app "$APP_PORT" "$TMP_DIR"` and `wait_for_ready` to bring up Electron.
- Sends a navigate command targeting the hash route `stories?cycle=1&duration=<ms>`. If the existing `navigate` command handler does not preserve the query portion of the page argument, adjust the handler in `apps/desktop-frontend/src/lib/platform-provider-electron.ts` (or wherever `onNavigate` is invoked) to pass the full string through to `useNavigate`.
- Calls `wait_for_log "$TMP_DIR" "STORIES CYCLE COMPLETE"` with a generous timeout (e.g. 600 seconds) to wait for the cycle to finish.
- After completion, greps the renderer log for any `STORIES CYCLE FAILED:` lines. If any are present, prints them to stderr and exits non-zero. Otherwise prints the `STORIES CYCLE COMPLETE` line and exits zero.
- Honours a `cleanup() { stop_app ...; }` trap on `EXIT` so the Electron process is always torn down.

### 18. Register the smoke script in root `package.json`

Add a script `"test:stories"` (and short alias `"tst"`) to the root `package.json` that runs `./apps/desktop/cycle-stories-smoke-test.sh`. Do **not** add it to `test:all`; the user explicitly flagged this as potentially long-running and wants it as a separate, manually-invoked smoke. Add a one-line entry under `## Commands` in `CLAUDE.md` describing the new script.

## Unit Tests

All test files go under `packages/user-interface/src/test/stories/`. Use Jest with the existing `jest-environment-jsdom` config and `test(` (not `it(`), per project rules.

### `registry.test.ts`

The cross-cutting smoke test the user asked for. Imports `stories` from `../../stories`. Tests:

- `every story has non-empty id, name, category, and a render function`: iterates the array and asserts each required field is present and non-empty; `render` must be a function.
- `all story ids are unique`: collects ids into a `Set` and asserts size equals array length; on failure includes the duplicated id in the assertion message.
- `every story has a recognised category`: asserts each story's category is one of `Pages`, `Modals`, `Dialogs`, `Components`.
- `every story renders without throwing`: for each story, mounts the result of `render()` using `@testing-library/react` `render` wrapped in a `MemoryRouter`, asserts no exception is thrown and that the rendered container has at least one child node. Cleanup between iterations with `cleanup()`. This test fails the build whenever any registered story crashes, satisfying the requirement that smoke tests cycle through every story.
- `every page, modal, dialog, and component in user-interface has at least one story`: globs `packages/user-interface/src/components/*.tsx` and `packages/user-interface/src/pages/**/*.tsx` (using `fs.readdirSync`, no dynamic imports) to build the list of source files, derives the expected story-id prefix from each file name, and asserts that at least one entry in `stories` matches each expected prefix. This makes the test fail when a new component or page is added without a matching story.

### `stories-page.test.tsx`

Use `@testing-library/react` and `MemoryRouter` with an `initialEntries` array to drive URL state.

- `renders all stories grouped by category`: mounts `StoriesPage`, asserts every category header is present and every story name appears at least once.
- `typing in the search input filters the visible list`: types a query that matches one story; asserts other stories disappear from the list.
- `clicking a story updates the URL and renders its output`: clicks the `spinner/visible` row; asserts the URL search becomes `?id=spinner/visible` and the right pane contains an element with `role="status"` from `Spinner`.
- `unknown story id shows an unknown-story message`: mounts with initial entry `/stories?id=does-not-exist`; asserts an `"Unknown story"` message including the offending id is rendered.
- `back to app link navigates to /`: clicks the back link; asserts the resulting location is `/`.

### `main-menu-action.test.tsx`

- `open-stories menu action navigates to /stories`: mounts `Main` inside a `MemoryRouter` with a mock platform whose `onMenuAction` exposes a way for the test to fire the registered callback. Fires `'open-stories'` and asserts the resulting location pathname is `/stories`. Confirms the new `case 'open-stories'` added in step 9 wires correctly.

## Smoke Tests

Two layers:

1. **Fast jsdom layer.** The `every story renders without throwing` assertion in `registry.test.ts` mounts every story under jsdom on every unit-test run, catching render-time crashes immediately and automatically picking up new stories.

2. **Live-app cycle layer.** The new standalone shell smoke test `apps/desktop/cycle-stories-smoke-test.sh` (step 17) launches the real Electron app, drives it to `/#/stories?cycle=1&duration=<ms>`, and the `StoriesCycle` component (step 16) walks every registered story, mounting each inside a React error boundary plus window-level error listeners, dwelling at each for `duration` ms (default 1000), and logging per-story pass/fail lines. The shell script waits for `STORIES CYCLE COMPLETE`, greps the renderer log for `STORIES CYCLE FAILED`, and exits non-zero if any failures occurred. This is the requested "cycle through every story spending some time at each" smoke. It is run via `bun run test:stories` and is deliberately excluded from `bun run test:all` because of its long duration.

## Verify

- Run `bun run test` from `packages/user-interface/` and confirm every test passes, including the new tests in `src/test/stories/`. The `every page, modal, dialog, and component has at least one story` assertion verifies completeness, and `every story renders without throwing` verifies no story crashes on mount.
- Run `bun run compile` from `packages/user-interface/` and confirm there are no TypeScript errors.
- Run `bun run compile` from `apps/dev-frontend/` and `apps/desktop-frontend/` and confirm there are no TypeScript errors introduced by the restructured `app.tsx` files.
- Run `bun run compile` from the repo root and confirm there are no TypeScript errors anywhere in the monorepo.
- Run `bun run test` from the repo root and confirm the full unit suite passes.
- Run `bun run test:stories` from the repo root and confirm the cycle smoke test exits zero with no `STORIES CYCLE FAILED` lines.

## Notes

- **Discovery / how a user reaches the stories page.** Two entry points, both documented in `stories/README.md`, both requiring deliberate action so end users cannot trigger the browser by accident:
  1. **Web (dev-frontend):** type `#/stories` in the browser address bar. Full URL for the default dev server: `http://localhost:3000/#/stories`.
  2. **Electron desktop app:** open the **Developer → Stories** menu item. The Developer menu already exists in `apps/desktop/src/main.ts` (Reload / Force Reload / Toggle Developer Tools) and is the conventional home for developer-only actions; a regular user rarely opens it. The click handler sends an `'open-stories'` menu-action over the existing IPC channel; `__Main` handles the action in its `onMenuAction` switch and calls `navigate('/stories')`.
  No keyboard shortcut, no sidebar link, no toolbar button, no onboarding hint. The `StoriesPage` itself includes a "Back to app" link that navigates to `/`.

- **Outside the provider stack.** The `/stories` route is mounted at the top level of each consuming frontend, sibling to (not child of) the provider stack. This means the stories browser starts with only `HashRouter` around it, and each story's `render` function explicitly wraps its content in whatever providers it needs. The shared `MockProviders` wrapper in `stories/mocks/index.tsx` is the default; stories that need to vary mock data pass overrides to `MockProviders` or use the underlying real provider with a custom value. Without this isolation, stories would inherit the live `AssetDatabaseProvider` and other production contexts and would render against real (or partially-mocked) application state, which defeats the purpose of the browser.

- **Comprehensive coverage enforced by test.** The `every page, modal, dialog, and component has at least one story` assertion in `registry.test.ts` reads the source directory at test time and asserts a matching story prefix exists. Adding a new component or page without registering at least one story for it fails the test.

- **Two-layer smoke coverage.** The jsdom `every story renders without throwing` test gives a fast in-process check that runs with every `bun run test`. The standalone `apps/desktop/cycle-stories-smoke-test.sh` runs against the live Electron app and dwells at each story for a configurable duration, catching errors that jsdom misses (real layout, real MUI Joy styling, real image loading, async errors after mount). It is kept as a separate `bun run test:stories` script and out of `test:all` because the duration is proportional to the story count and is expected to grow into the multi-minute range.

- **Mocks are deliberately thin.** `mockPlatform`, mock `AssetDatabaseProvider`, and other helpers exist to make components mount, not to faithfully simulate the backend. Stories that want richer interactions can compose their own mocks on top of `MockProviders` overrides.

- **Manual registration in `index.ts`** (no `import.meta.glob`) keeps the loader bundler-agnostic so the registry can be tested under Jest without a Vite environment.

- **`id` field uniqueness** is a hard requirement enforced by `registry.test.ts`. The convention is `<component-file-name>/<variant>`, lowercased and kebab-cased.

- **Re-keying the right pane on `selectedStory.id`** is deliberate. Without it, switching between two stories that share a component type would reuse React state from the previous story and produce confusing behaviour.

- **Only `dev-frontend` and `desktop-frontend` are updated.** `apps/frontend/` and `apps/mobile/frontend/` contain only build output (no source) and need no edits.

- **The `StoriesPage` is exported from `user-interface/src/index.tsx`** so consuming apps can import it; no further internals of the stories folder are exported.
