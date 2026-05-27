# Dedicated No-Database Page

## Overview

Today the "no database loaded" UI is a component (`packages/user-interface/src/components/no-database-loaded.tsx`) that is rendered inline inside the Gallery page and the Map page whenever `databasePath` is null. This means the user lands on `/gallery` on first run (because root `"/"` redirects unconditionally to `/gallery`), sees the no-DB welcome panel inside the Gallery page, and at the same time sees nav items (Search, Gallery, Map, Import) that don't do anything useful without a database. This plan promotes the welcome UI to a top-level page (`/no-database`), makes the root route choose between `/no-database` and `/gallery` based on whether a database is loaded, removes the inline rendering from Gallery and Map, removes the small local "no database" stub inside the Import page (it becomes unreachable once routing redirects away from `/import`), and hides the database-dependent nav items (Search, Gallery, Map) in the navbar and left sidebar while no database is loaded. Import is already gated and stays gated.

## Issues

<!-- Populated later by plan:check -->

## Steps

### 1. Create `packages/user-interface/src/pages/no-database/no-database-page.tsx`

Define a new top-level page component that owns the welcome UI currently in `components/no-database-loaded.tsx`.

- Export signature: `export function NoDatabasePage(): JSX.Element`.
- Implementation is the body of the current `NoDatabaseLoaded` component, lifted verbatim:
    - `usePlatform()` to access the platform API.
    - `useAssetDatabase()` to access `openDatabase`.
    - Local state `createModalOpen` and `openModalOpen` plus the `CreateDatabaseModal` and `OpenDatabaseModal` they control.
    - Local state `recentDatabases: IDatabaseEntry[]` populated from `platform.getRecentDatabases()` inside a `useEffect`.
    - Layout: a centered `<Box>` containing the "No database loaded" heading, the "Create a new database or open an existing one." body text, the two large buttons ("New database", "Open database"), and the conditional "Recent databases" section.
- Drop the `height: "calc(100vh - 60px)"` style on the outer `<Box>` — the page is rendered inside `#content` so it can size naturally. Use `minHeight: "calc(100vh - 60px)"` if vertical centering is still desired.
- Add a `data-id="no-database-page"` attribute on the outermost element so smoke tests can target it.
- Every exported symbol and every interface field needs a `//` comment block per project style.

### 2. Delete `packages/user-interface/src/components/no-database-loaded.tsx`

The component is now the page from step 1. The file is removed; no re-export shim is added (backwards compatibility is not required per `CLAUDE.md`).

### 3. Update `packages/user-interface/src/main.tsx`

- Add `import { NoDatabasePage } from "./pages/no-database/no-database-page";`.
- Replace `import { Route, Routes, Navigate, useNavigate } from "react-router-dom";` with the same plus `useLocation`.
- Inside `__Main`, after `const navigate = useNavigate();`, add `const location = useLocation();`.
- Inside `<Routes>`, add a new route immediately before the `"/"` route: `<Route path="/no-database" element={<NoDatabasePage />} />`.
- Replace the `"/"` route element so it picks the destination based on `databasePath`:
    - When `databasePath` is truthy: `<Navigate replace to="/gallery" />`.
    - When `databasePath` is falsy: `<Navigate replace to="/no-database" />`.
- Add a new `useEffect` in `__Main` that reacts to changes in `databasePath` and the current `location.pathname` and redirects when the two are out of sync:
    - Define a constant `DATABASE_REQUIRED_ROUTES = ["/gallery", "/map", "/import"]` at module scope (above `__Main`) — every field commented.
    - Effect body:
        - If `!databasePath` and `location.pathname` starts with any entry in `DATABASE_REQUIRED_ROUTES` (use `startsWith` to cover `/gallery/:assetId` and `/map/:assetId`), call `navigate("/no-database", { replace: true })`.
        - If `databasePath` is truthy and `location.pathname === "/no-database"`, call `navigate("/gallery", { replace: true })`.
    - Effect dependencies: `[databasePath, location.pathname, navigate]`.
- Leave the existing `autoOpenLastDatabase` effect alone; once it sets `databasePath`, the new effect above will redirect off `/no-database` to `/gallery`.

### 4. Update `packages/user-interface/src/pages/gallery/gallery.tsx`

- Remove the import `import { NoDatabaseLoaded } from "../../components/no-database-loaded";`.
- Remove the `{!databasePath && (<NoDatabaseLoaded />)}` block from the JSX (lines 35–37 in the current file).
- Leave the two remaining `{databasePath && ...}` guards in place; they still defend against the one-frame gap before the redirect effect fires.

### 5. Update `packages/user-interface/src/pages/map/map-page.tsx`

- Remove the import `import { NoDatabaseLoaded } from "../../components/no-database-loaded";`.
- Remove the `{!databasePath && (<NoDatabaseLoaded />)}` block from the JSX (lines 48–50 in the current file).
- Leave the remaining `{databasePath && ...}` guards.

### 6. Update `packages/user-interface/src/pages/import/import-page.tsx`

- Remove the local `function NoDatabaseLoaded()` defined inside this file (lines ~16–24) — this is a small inline stub, unrelated to the moved component.
- Remove the early `if (!databasePath) { return <NoDatabaseLoaded />; }` block in `ImportPage` (lines ~274–276).
- The page now assumes a database is loaded because the route effect in `main.tsx` redirects `/import` to `/no-database` when none is.

### 7. Update `packages/user-interface/src/components/navbar.tsx`

Gate the database-dependent nav controls so they only render when `databasePath` is truthy. The `databasePath` value is already destructured from `useAssetDatabase()` on line 108.

- Wrap the Search button (current lines 134–145) in `{databasePath && (...)}`.
- Wrap the Gallery `<NavLink to="/gallery">` (current lines 147–155) in `{databasePath && (...)}`.
- Wrap the Map `<NavLink to="/map">` (current lines 157–165) in `{databasePath && (...)}`.
- Leave the existing Import `{databasePath && (...)}` guard alone (current lines 167–177).
- The `data-id="sidebar-toggle-button"`, the "Photosphere" title, the right-sidebar button, the update-available badge, and the loading/syncing spinners remain unconditional.

### 8. Update `packages/user-interface/src/components/left-sidebar.tsx`

Gate the database-dependent list items so they only render when `databasePath` is truthy. The `databasePath` value is already destructured from `useAssetDatabase()` on line 51.

- Wrap the Search `<ListItem>` (current lines 132–144) in `{databasePath && (...)}`.
- Wrap the Gallery `<NavLink to="/gallery">` list item (current lines 146–158) in `{databasePath && (...)}`.
- Wrap the Map `<NavLink to="/map">` list item (current lines 160–172) in `{databasePath && (...)}`.
- Leave the existing Import `{databasePath && (...)}` guard alone (current lines 115–129).
- The "New database", "Open database", recent databases section, "Manage Databases", "Manage Secrets", and "Configuration" entries remain unconditional.

### 9. Rename and rewrite the stories file for the page

- Delete `packages/user-interface/src/stories/components/no-database-loaded.stories.tsx`.
- Create `packages/user-interface/src/stories/pages/no-database.stories.tsx` with one story:
    - `id: "no-database-page/default"`
    - `name: "No Database"`
    - `category: "Pages"`
    - `render: () => (<MockProviders><NoDatabasePage /></MockProviders>)`
- Import the page from `"../../pages/no-database/no-database-page"`.
- Every exported symbol gets a `//` comment block.

### 10. Update `packages/user-interface/src/stories/index.ts`

- Remove the line `import { stories as noDatabaseLoadedStories } from "./components/no-database-loaded.stories";` and its spread `...noDatabaseLoadedStories` from the components block.
- Add a new import `import { stories as noDatabasePageStories } from "./pages/no-database.stories";` in alphabetical-by-file order in the pages block (between `mapPageStories` and `newsPageStories`).
- Add `...noDatabasePageStories` to the pages spread block in the same position.

### 11. Add "no database" variants to Navbar and Left Sidebar stories

The default stories use `mockAssetDatabase()` which sets `databasePath: "/mock/database"`. Add a second story per file demonstrating the trimmed nav when `databasePath` is null.

In `packages/user-interface/src/stories/components/navbar.stories.tsx`:

- Add a second story:
    - `id: "navbar/no-database"`
    - `name: "Navbar (no database)"`
    - `category: "Components"`
    - `render`: wraps `<Navbar ... />` in `<MockProviders assetDatabase={mockAssetDatabase([])}>` with `databasePath` overridden to `null` (override via the prop the mock helpers expose, or by importing `mockAssetDatabase` and spreading: `{ ...mockAssetDatabase([]), databasePath: null }`).
- Add an import for `mockAssetDatabase` from `../mocks`.

In `packages/user-interface/src/stories/components/left-sidebar.stories.tsx`:

- Add the equivalent second story with `id: "left-sidebar/no-database"`, `name: "Left Sidebar (no database)"`.

### 12. Update the create-database and open-database modals' completion side-effects (verify only)

The existing `CreateDatabaseModal` and `OpenDatabaseModal` already call `openDatabase(...)` which updates `databasePath`. No code change is required here — once `databasePath` flips to non-null, the new route effect in `main.tsx` will redirect from `/no-database` to `/gallery` automatically. This step exists only to confirm the assumption during implementation by reading both modal files (`packages/user-interface/src/components/create-database-modal.tsx` and `packages/user-interface/src/components/open-database-modal.tsx`) and verifying that on success they call `openDatabase` (or otherwise cause `databasePath` to change). If not, raise it as an issue.

## Unit Tests

The `user-interface` package's existing unit-test surface is for context and lib code, not component rendering — there are no RTL-style component tests today. Coverage for this change therefore comes primarily through the stories registry and smoke tests (see below). The only new unit-test-style assertion to add is:

- Add a test file `packages/user-interface/src/test/lib/database-required-routes.test.ts` (or extend an existing lib test if a more natural home appears during implementation) that asserts the `DATABASE_REQUIRED_ROUTES` list defined in `main.tsx` matches the routes registered in the same file. This requires exporting `DATABASE_REQUIRED_ROUTES` as a named const from `main.tsx`. The test imports the array and asserts membership of `/gallery`, `/map`, and `/import`, and asserts that `/no-database`, `/databases`, `/secrets`, `/about`, `/news` are NOT in the list. Use `test(...)` not `it(...)` per project style.

## Smoke Tests

Update existing CLI/Electron smoke tests where the no-DB landing matters, and add one new smoke test for the dedicated page.

- **`apps/desktop/smoke-tests/1-load-fixture/test.sh`** (and any test that launches the app with a clean `tmp/` and no pre-seeded `databases.toml`): assert that after the renderer settles, the URL ends with `#/no-database` (use the existing renderer URL helpers / `wait_for_log` for the page mount log message) and that a DOM element with `data-id="no-database-page"` is present.
- **New smoke test** `apps/desktop/smoke-tests/23-no-database-page/test.sh`:
    1. Launch the Electron app with an empty `tmp/` and no `databases.toml`.
    2. Assert URL is `#/no-database`.
    3. Assert the navbar does NOT contain a Search, Gallery, Map, or Import control (query by visible label or by class).
    4. Assert the navbar DOES contain the "Photosphere" title and the right-sidebar button.
    5. Click "New database", complete the create flow (reuse the helpers from `2-create-database/test.sh`), assert URL transitions to `#/gallery`, and assert the Search/Gallery/Map/Import nav items now appear.
- **`apps/desktop/smoke-tests/3-open-database/test.sh`**: after the test seeds `databases.toml` and the app starts and auto-opens the last database, assert the URL is `#/gallery` (i.e. confirm we did NOT linger on `/no-database`).
- **`apps/desktop/smoke-tests/cycle-stories-smoke-test.sh`** (long-running stories cycler invoked via `bun run test:stories`): this picks up the renamed/added stories automatically through the central `stories/index.ts`; no change required, but re-run the screenshot diff baseline.
- Smoke tests are invoked via `bun run test:electron`, with the long-running stories cycler via `bun run test:stories`, per `CLAUDE.md`.

## Verify

After implementation the AI agent must run these in order from the repo root and confirm all pass:

1. `bun run compile` — TypeScript must compile across the whole monorepo.
2. `bun run test` — unit tests including the new `database-required-routes.test.ts`.
3. `bun run test:cli` — CLI smoke tests (sanity, not directly exercised by this change).
4. `bun run test:electron` — Electron smoke tests including the new `23-no-database-page` test and the updated `1-load-fixture` and `3-open-database` assertions.
5. `bun run test:stories` — long-running stories cycler; confirm the new and renamed stories render without errors.
6. `grep -rn "no-database-loaded" packages apps --include="*.ts" --include="*.tsx"` returns no matches (dead references to the deleted file).
7. `grep -rn "NoDatabaseLoaded" packages apps --include="*.ts" --include="*.tsx"` returns no matches.

## Human Verification

Per `CLAUDE.md` the plan should not require manual testing, and all of the above is automated. This section is intentionally left empty.

## Notes

- HashRouter is in use (`apps/desktop-frontend/src/app.tsx:55`). `useLocation().pathname` returns the path after the `#`, so route matching with `startsWith("/gallery")` etc. works without special handling.
- `autoOpenLastDatabase` in `main.tsx:236-256` runs on mount with a null `databasePath`. The new root route immediately renders `<Navigate to="/no-database" />`, then if `autoOpenLastDatabase` succeeds, `databasePath` becomes non-null and the new redirect effect navigates to `/gallery`. The user may briefly see the No Database page during the first frame on cold start with a slow `getRecentDatabases` — this is acceptable.
- The `EmptyDatabase` component is unaffected and still rendered inline by Gallery and Map when a database is loaded but contains no assets.
- The Import page has its own local `NoDatabaseLoaded` function (not the moved component); step 6 removes it. Confirm during implementation that no other file imports it (a grep for `from "./import-page"` shows only the page itself is imported).
- Backwards compatibility is not required (`CLAUDE.md`), so no compat shim, no deprecation comment, no aliases.
- The dev-frontend app (`apps/dev-frontend/src/app.tsx`) shares the same `Main` component and will get the new routing behavior automatically; no per-app change needed.
- `data-id="no-database-page"` is added so smoke tests can target the page deterministically; this matches the convention used elsewhere (e.g. `data-id="sidebar-toggle-button"`, `data-id="import-drop-zone"`).
