# Plan: Lazy S3 credential lookup

## Problem

Every CLI command that opens a database unconditionally calls `getS3Config()` before
calling `createStorage`, even when the database path is a local filesystem path and S3
credentials are never used. `getS3Config()` reads from the OS vault (keychain on Linux
via `secret-tool`), so this causes failures on machines where the keychain daemon or
`secret-tool` is not available — including CI runners.

The affected call sites are:

```
apps/cli/src/cmd/add.ts
apps/cli/src/cmd/check.ts
apps/cli/src/cmd/decrypt.ts
apps/cli/src/cmd/encrypt.ts
apps/cli/src/cmd/fix-config.ts
apps/cli/src/cmd/hash.ts
apps/cli/src/cmd/replicate.ts
apps/cli/src/cmd/sync.ts
apps/cli/src/cmd/upgrade.ts
apps/cli/src/cmd/verify.ts
apps/cli/src/lib/init-cmd.ts  (two call sites)
```

`createStorage` in `packages/storage/src/lib/storage-factory.ts` already only uses
`s3Config` when the root path begins with `s3:`, so the vault lookup is wasted work for
all local paths.

## Fix

Introduce a thin helper `createStorageForPath` in the CLI (`apps/cli/src/lib/`) that
accepts a path and storage options, resolves credentials only for the prefix that
requires them, then delegates to `createStorage`.

A private `fetchCredentials` function maps each remote prefix to its credential fetcher.
Adding a new storage type only requires a new branch there; all call sites stay
untouched.

```ts
// apps/cli/src/lib/storage-helper.ts

//
// Returns credentials for remote storage prefixes, or undefined for local paths.
// Add a new branch here when a new remote storage type is introduced.
//
async function fetchCredentials(rootPath: string): Promise<IS3Credentials | undefined> {
    if (rootPath.startsWith('s3:')) {
        return getS3Config();
    }
    return undefined;
}

//
// Creates storage for the given path, fetching credentials from the vault only
// when the path prefix requires them (e.g. s3:). Local paths never touch the vault.
//
export async function createStorageForPath(
    rootPath: string,
    options?: IStorageOptions
): Promise<ICreateStorageResult> {
    const credentials = await fetchCredentials(rootPath);
    return createStorage(rootPath, credentials, options);
}
```

Replace every `getS3Config` + `createStorage` pair in the affected command files with a
single call to `createStorageForPath`.

The two call sites in `init-cmd.ts` need individual attention:

- Line 686 — straightforward replacement.
- Line 522 — already has a `resolvedSecrets?.s3Config` fallback for the interactive
  setup flow; keep that fallback but wrap the `await getS3Config()` fallback with the
  same prefix guard (i.e. call `fetchCredentials` instead of `getS3Config` directly).

## Steps

1. Create `apps/cli/src/lib/storage-helper.ts` with `fetchCredentials` and `createStorageForPath` as above.
2. In each of the ten command files (`add`, `check`, `decrypt`, `encrypt`, `fix-config`,
   `hash`, `replicate`, `sync`, `upgrade`, `verify`): remove the `getS3Config()` call
   and replace the `createStorage(dbDir, s3Config, ...)` call with
   `createStorageForPath(dbDir, ...)`.
3. Update the two call sites in `init-cmd.ts`.
4. Delete the `getS3Config` import from any file that no longer uses it directly.
5. Compile the whole monorepo (`bun run compile`) and confirm no type errors.
6. Run the smoke tests without `PHOTOSPHERE_VAULT_TYPE` set to confirm the vault is no
   longer touched for local paths.

## Out of scope

The `PHOTOSPHERE_VAULT_TYPE=plaintext` lines added to `sync-smoke-test.sh` and
`write-lock-smoke-test.sh` can be removed once this fix lands, as they will no longer be
needed. The lines in the other smoke test scripts should be kept — those scripts
explicitly test vault behaviour and want plaintext for repeatability.
