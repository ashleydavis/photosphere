# Decouple `lan-share` from Photosphere-specific packages

## Overview

`lan-share` is a generic LAN transport package but currently has dependencies on `api` and `node-api`, both of which are Photosphere-specific. The goal is to make `lan-share` a fully generic package with no Photosphere-specific dependencies, while also breaking the unrelated dependency from `user-interface` to `lan-share`. The domain types currently defined in `lan-share` are moved (also) into `api` under a `lan-share` subdirectory so that external consumers can import them from `api` instead of `lan-share` directly.

## Steps

1. Create `packages/api/src/lan-share/index.ts` containing the domain types moved from `lan-share-types.ts`: `IShareS3Credentials`, `IShareEncryptionKey`, `IShareGeocodingKey`, `IDatabaseSharePayload`, `ISecretSharePayload`, `IConflictResolution`, `ConflictResolver`.

2. Create `packages/api/src/lan-share/README.md` explaining the purpose of this directory.

3. Move `packages/lan-share/src/lib/lan-share-resolve.ts` to `packages/api/src/lan-share/lan-share-resolve.ts` and move its test to `packages/api/src/test/`. Update its imports to use the domain types from `./index` and replace the `IDatabaseEntry` import from `node-api` with a locally-defined interface.

4. Move `packages/lan-share/src/lib/lan-share-import.ts` to `packages/api/src/lan-share/lan-share-import.ts` and move its test to `packages/api/src/test/`. Update its imports to use the domain types from `./index` and replace the `IDatabaseEntry` import from `node-api` with a locally-defined interface.

5. Add `vault` and `storage` as dependencies to `packages/api/package.json` if not already present.

6. Re-export the domain types and functions from `lan-share-resolve` and `lan-share-import` from `packages/api/src/index.ts`.

7. Remove the moved types from `packages/lan-share/src/lib/lan-share-types.ts`. Remove `api` and `node-api` from `packages/lan-share/package.json`.

8. Update all external consumers (`apps/desktop/src/main.ts`, `apps/desktop-frontend/src/lib/platform-provider-electron.tsx`, `apps/cli/src/cmd/dbs.ts`, `apps/cli/src/cmd/secrets.ts`, `packages/user-interface/src/components/share-database-dialog.tsx`, `packages/user-interface/src/context/platform-context.tsx`, `packages/user-interface/src/components/receive-database-dialog.tsx`) to import domain types and resolve/import functions from `api` instead of `lan-share`.

9. Remove `lan-share` from `packages/user-interface/package.json`.

## Unit Tests

- Existing tests in `packages/lan-share/src/test/` should continue to pass without modification (except `lan-share-resolve` and `lan-share-import` tests which move to `packages/api/src/test/`).
- Existing tests in `packages/user-interface/src/test/` should continue to pass without modification.

## Smoke Tests

- Run `bun run test:cli` to verify CLI commands that use lan-share still work.
- Run `bun run test:electron` to verify Electron desktop app lan-share functionality still works.

## Verify

- `bun run compile` passes with no TypeScript errors.
- `bun run test` passes with no test failures.
- `packages/lan-share/package.json` no longer lists `api` or `node-api` as dependencies.
- `packages/user-interface/package.json` no longer lists `lan-share` as a dependency.
- All domain type imports in `user-interface`, `desktop`, `desktop-frontend`, and `cli` reference `api`, not `lan-share`.

## Notes

- `IPairingCodeHashResponse` and `IReceiverEndpoint` are transport-protocol types and remain in `lan-share-types.ts` only -- they are not moved to `api`.
- Both `lan-share-resolve.ts` and `lan-share-import.ts` move to `api` since they depend on `vault` and `storage`, and the domain types they operate on are defined in `api`.
- The local interface replacing `IDatabaseEntry` should be named to reflect its role rather than mirroring the Photosphere-specific name.
