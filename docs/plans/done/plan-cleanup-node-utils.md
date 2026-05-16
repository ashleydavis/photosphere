# Move Config Modules from node-utils to api

## Overview
`databases-config.ts` and `desktop-config.ts` currently live in `packages/node-utils` but belong in `packages/api` because they are tightly coupled to application-level concerns (database registry, desktop preferences) rather than generic Node.js utilities. Moving them into `api` keeps utility primitives in `node-utils` and application-domain config in `api`, and places the code alongside `resolve-storage-credentials.ts` which already consumes `getDatabases`.

## Issues
<!-- populated by plan:check -->

## Steps

1. **Add `electron-defs` dependency to `packages/api/package.json`**
   Add `"electron-defs": "workspace:*"` to the `dependencies` map. The `databases-config.ts` file imports `IDatabaseEntry` from `electron-defs`.

2. **Create `packages/api/src/lib/databases-config.ts`**
   Copy from `packages/node-utils/src/lib/databases-config.ts`. Change the import of `readJson`, `writeJson`, `pathExists` from `"./fs"` to `"node-utils"`. The `IDatabaseEntry` import from `"electron-defs"` stays unchanged.

3. **Create `packages/api/src/lib/desktop-config.ts`**
   Copy from `packages/node-utils/src/lib/desktop-config.ts`. Change the import of `readJson`, `writeJson`, `pathExists` from `"./fs"` to `"node-utils"`.

4. **Update `packages/api/src/index.ts`**
   Add `export * from "./lib/databases-config";` and `export * from "./lib/desktop-config";`.

5. **Update `packages/api/src/lib/resolve-storage-credentials.ts`**
   Change `import { getDatabases } from "node-utils"` to `import { getDatabases } from "./databases-config"`.

6. **Update `packages/api/src/test/lib/resolve-storage-credentials.test.ts`**
   Change `jest.mock('node-utils', ...)` (the mock providing `getDatabases`) to `jest.mock('./databases-config', ...)` (or the module path that resolves correctly). Update the import `import { getDatabases } from 'node-utils'` to `import { getDatabases } from './databases-config'` (or via the api package root if needed).
   Wait - we need to check carefully. The test currently uses `jest.mock('node-utils', ...)`. After the move, `getDatabases` lives in `api`, not `node-utils`. The mock target must change to the module that `resolve-storage-credentials.ts` imports from, which will be `"./databases-config"`.

7. **Update `apps/desktop/src/main.ts`**
   Change `import { ..., loadDesktopConfig, saveDesktopConfig, updateLastFolder, getTheme, setTheme, updateLastDownloadFolder, getDatabases, addDatabaseEntry, updateDatabaseEntry, removeDatabaseEntry, getRecentDatabases, markDatabaseOpenedByPath } from 'node-utils'` — split or merge so those config symbols come from `'api'` instead.

8. **Update `apps/dev-server/src/index.ts`**
   Change `import { loadDesktopConfig, saveDesktopConfig, getDatabases, addDatabaseEntry, removeDatabaseEntry, updateLastFolder, markDatabaseOpenedByPath } from "node-utils"` to `from "api"`.

9. **Update `apps/cli/src/cmd/dbs.ts`**
   Change `import { getDatabases, addDatabaseEntry, updateDatabaseEntry, removeDatabaseEntry } from 'node-utils'` to `from 'api'`.

10. **Update `apps/cli/src/lib/init-cmd.ts`**
    Change `getDatabases` import from `"node-utils"` to `"api"`. Keep remaining node-utils imports (`exit`, `TestUuidGenerator`, etc.) from `"node-utils"`.

11. **Update `apps/cli/src/test/cmd/dbs.test.ts`**
    Change `import { getDatabases, exit, addDatabaseEntry } from 'node-utils'` — move the config-function imports to `'api'`, keep `exit` from `'node-utils'`. Update `jest.mock('node-utils', ...)` to separate mocks: one for `'node-utils'` (covering `exit` and other node-utils symbols still used) and one for `'api'` (covering `getDatabases`, `addDatabaseEntry`, etc.).

12. **Update `apps/cli/src/test/lib/init-cmd.test.ts`**
    Change `import { getDatabases } from 'node-utils'` to `from 'api'`. Update `jest.mock('node-utils', ...)` to also mock `'api'` for `getDatabases`.

13. **Remove `packages/node-utils/src/lib/databases-config.ts`** (delete file).

14. **Remove `packages/node-utils/src/lib/desktop-config.ts`** (delete file).

15. **Update `packages/node-utils/src/index.ts`**
    Remove `export * from "./lib/desktop-config";` and `export * from "./lib/databases-config";`.

## Unit Tests

- **`packages/api/src/test/lib/databases-config.test.ts`** — new file covering:
  - `loadDatabasesConfig`: returns default when file absent; returns config from disk when present; coerces missing arrays to `[]`
  - `saveDatabasesConfig`: writes JSON with 2-space indent; coerces missing arrays before writing
  - `getDatabases`: delegates to `loadDatabasesConfig` and returns the `databases` array
  - `addDatabaseEntry`: appends entry and saves
  - `updateDatabaseEntry`: replaces matched entry by path and saves
  - `removeDatabaseEntry`: filters out entry by path and saves
  - `getRecentDatabases`: resolves paths to full entries, skips unknown paths
  - `markDatabaseOpenedByPath`: moves path to front, caps at 5, skips unknown paths

- **`packages/api/src/test/lib/desktop-config.test.ts`** — new file covering:
  - `loadDesktopConfig`: returns `{}` when file absent; returns config from disk
  - `saveDesktopConfig`: writes config JSON
  - `getConfigPath`: returns the expected file path string
  - `updateLastFolder`: sets `lastFolder` and saves
  - `getTheme`: returns `'system'` when unset; returns stored value
  - `setTheme`: sets `theme` and saves
  - `updateLastDownloadFolder`: sets `lastDownloadFolder` and saves
  - `getRecentSearches`: returns `[]` when unset; returns stored list
  - `addRecentSearch`: deduplicates and prepends; caps at 10
  - `removeRecentSearch`: filters out given search

## Smoke Tests

- Run `bun run compile` from the repo root — zero TypeScript errors.
- Run `bun run test` from the repo root — all tests pass.
- Start the dev server (`bun run dev:web`) and confirm it connects to the desktop config and database list without errors in the console.

## Verify

- `cd packages/api && bun run compile` — compiles without errors.
- `cd packages/node-utils && bun run compile` — compiles without errors (removed exports must not break internal references).
- `cd packages/api && bun run test` — new `databases-config.test.ts` and `desktop-config.test.ts` pass, `resolve-storage-credentials.test.ts` still passes.
- `cd apps/cli && bun run test` — `dbs.test.ts` and `init-cmd.test.ts` still pass.
- `bun run test` (repo root) — full test suite green.

## Notes

- `resolve-storage-credentials.ts` already lives in `api` and only used `getDatabases` from `node-utils`; moving the source closer eliminates the cross-package import for that function.
- `desktop-config.ts` uses `PHOTOSPHERE_CONFIG_DIR` env var in `databases-config.ts` but not in itself — keep both paths consistent (both use the same `~/.config/photosphere` dir convention).
- `dev-server` does not list `node-utils` or `api` in its `package.json` dependencies but resolves them via Bun workspace resolution. No `package.json` change is needed for `dev-server`.
- The `apps/cli` package already lists both `api` and `node-utils` as explicit dependencies — no `package.json` change needed.
- `apps/desktop` already lists `api` as an explicit dependency — no `package.json` change needed.
- There are no existing test files for `databases-config` or `desktop-config` in `node-utils`; the tests listed above must be created from scratch.
