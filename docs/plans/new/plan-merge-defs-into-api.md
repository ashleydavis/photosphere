# Merge `defs` Package into `api`

## Overview
The `packages/defs` package contains only four TypeScript interface files (no runtime code) shared between the backend and frontend: `asset.ts`, `op.ts`, `database-op.ts`, and `database-op-record.ts`. Every consumer of `defs` (`packages/api`, `packages/user-interface`, `packages/rest-api`, and `apps/cli`) already depends on `packages/api`, so `defs` can be dissolved by moving its files into `api` and updating all import sites. This removes an unnecessary package and keeps shared types co-located with the code that owns them.

## Issues

## Steps

1. **Move source files** — copy the four files from `packages/defs/src/lib/` into `packages/api/src/lib/`:
   - `packages/defs/src/lib/asset.ts` → `packages/api/src/lib/asset.ts`
   - `packages/defs/src/lib/op.ts` → `packages/api/src/lib/op.ts`
   - `packages/defs/src/lib/database-op.ts` → `packages/api/src/lib/database-op.ts`
   - `packages/defs/src/lib/database-op-record.ts` → `packages/api/src/lib/database-op-record.ts`

2. **Re-export from `api` index** — add the following exports to `packages/api/src/index.ts`:
   ```ts
   export * from "./lib/asset";
   export * from "./lib/op";
   export * from "./lib/database-op";
   export * from "./lib/database-op-record";
   ```

3. **Update imports inside `packages/api`** — change `from "defs"` to relative paths in these 11 files (the moved files are now siblings in `src/lib/`):
   - `src/lib/sync-database.worker.ts`
   - `src/lib/sync-database.types.ts`
   - `src/lib/apply-database-ops.ts`
   - `src/lib/media-file-database.ts`
   - `src/lib/import-assets.worker.ts`
   - `src/lib/upload-asset.worker.ts`
   - `src/lib/repair.ts`
   - `src/lib/load-assets.types.ts`
   - `src/lib/sync.ts`
   - `src/lib/verify.ts`
   - `src/test/lib/apply-database-ops.test.ts`

4. **Update imports in `packages/user-interface`** — in `src/context/asset-database-source.tsx`, change `from "defs"` to `from "api"`.

5. **Update imports in `packages/rest-api`** — in `src/lib/asset-server.ts`, change `from "defs"` to `from "api"`.

6. **Update imports in `apps/cli`** — change `from "defs"` to `from "api"` in:
   - `src/cmd/upgrade.ts`
   - `src/cmd/list.ts`
   - `src/lib/init-cmd.ts`
   - `src/cmd/info.ts`

7. **Remove `defs` from `package.json` dependencies** in:
   - `packages/api/package.json`
   - `packages/user-interface/package.json`
   - `apps/cli/package.json`

8. **Delete the `packages/defs` directory** entirely.

## Unit Tests
- No new unit tests are required. The moved interfaces contain no logic. Existing tests in `packages/api/src/test/lib/apply-database-ops.test.ts` will exercise the relocated types.

## Smoke Tests
- Start the dev server (`bun run dev:web`) and confirm the frontend loads without errors.
- Run `bun run start -- list <db-path>` from `apps/cli/` to confirm the CLI resolves `IAsset` correctly.

## Verify
- `bun run compile` from the repo root passes with no TypeScript errors.
- `bun run test` from the repo root passes all tests.
- `grep -r "from \"defs\"" packages/ apps/` returns no results.
- `packages/defs` directory no longer exists.

## Notes
- `packages/rest-api` already depended on `api` but was using `defs` types via a transitive dependency (not listed in its own `package.json`). After this change it will use `api` directly and correctly.
- The root `package.json` uses glob workspaces (`packages/*`) so no root-level config change is needed after deleting the directory.
- No version bump or changelog entry is needed; backward compatibility is not a requirement for this project.
