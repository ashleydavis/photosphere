# Fix: "Region is missing" when opening S3 database in Electron

## Overview
The `notify-database-opened` IPC handler calls `createStorage(databasePath)` without S3 credentials, so the AWS SDK has no region and fails immediately with "Region is missing" when the database path points to an S3-compatible store (e.g. Digital Ocean Spaces). The fix is to look up the S3 credentials from the vault before constructing storage, mirroring the pattern already used by `check-database-exists`.

## Steps
1. In `apps/desktop/src/main.ts`, inside the `notify-database-opened` handler (line 368), add vault credential lookup before `createStorage()`:
   - Get the vault: `const vault = getVault(getDefaultVaultType());`
   - Load the database list: `const databases = await getDatabases();`
   - Find the matching entry: `const dbEntry = databases.find(entry => entry.path === databasePath);`
   - If `dbEntry?.s3Key` exists, call `vault.get(dbEntry.s3Key)`, parse the JSON value, and build an `s3Credentials` object with `{ region, accessKeyId, secretAccessKey, endpoint }`.
2. Pass `s3Credentials` as the second argument to `createStorage(databasePath, s3Credentials)`.

## Unit Tests
No new unit tests required — this is a wiring change in the Electron main process IPC layer, which is not unit-tested. Existing tests are unaffected.

## Smoke Tests
- Launch Electron (`bun run dev`), open the "ash-and-ant-digital-ocean" (or any S3-backed) database, confirm it loads without error.

## Verify
1. Run `bun run dev` to start the Electron desktop app.
2. Open the "ash-and-ant-digital-ocean" database from the recent-databases list.
3. Confirm no "Region is missing" / "Failed to check if file exists" error in the console.
4. Confirm the database opens and the gallery displays normally.

## Notes
- The same credential-lookup pattern exists in `check-database-exists` (line 282) and `get-database-secrets` (line 321) — follow those exactly.
- `IS3Credentials` is imported from `packages/storage/src/lib/cloud-storage.ts` and already available in scope via the existing `import` for `CloudStorage`.
- If `dbEntry` is not yet in the database list (first-ever open), `s3Credentials` will remain `undefined` and `createStorage` will fall back to unauthenticated access (acceptable for local-FS paths; S3 paths would still fail, but that's a pre-existing limitation for brand-new databases).
