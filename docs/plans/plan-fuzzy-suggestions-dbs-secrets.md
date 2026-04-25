# Fuzzy Name Suggestions for `dbs`, `secrets`, and Key Parameters

## Overview

The latest commit added `levenshteinDistance` and `findSimilarDatabaseNames` to `init-cmd.ts` and
wired them into the "No database found" error emitted during database load. This plan generalises
the fuzzy-match logic into a new `packages/fuzzy-match` package that exposes a generator-based
API, migrates the existing database-name matching to use it, adds parallel secret-name and
encryption-key-name matchers, and wires "Did you mean: …" suggestions into:

- `dbs` sub-commands (view/edit/remove/send) when a `--name` lookup fails,
- `secrets` sub-commands (view/edit/remove/send) when a `--name` lookup fails,
- any CLI command using `--key`, `--dest-key`, or `--source-key` when the named encryption key is
  not found in the vault,
- `dbs add/edit --yes` when `--encryption-key`, `--s3-cred`, or `--geocoding-key` refers to a
  vault secret that does not exist.

The plan also renames three verbose options in `dbs add` and `dbs edit`:
`--s3-cred-id` → `--s3-cred`, `--encryption-key-id` → `--encryption-key`,
`--geocoding-key-id` → `--geocoding-key`.

## Issues

<!-- populated by plan:check -->

## Steps

1. **Create `packages/fuzzy-match/`** — new package
   - `package.json`: `"name": "fuzzy-match"`, `"main": "src/index.ts"`, `"type": "module"`.
   - `tsconfig.json`: extend the root config (same pattern as other packages).
   - `src/index.ts`: re-export everything from `src/lib/fuzzy-match.ts`.
   - `src/lib/fuzzy-match.ts`:
     - Export `function levenshteinDistance(a: string, b: string): number` — pure DP
       implementation (move from `init-cmd.ts`).
     - Export `async function* fuzzyMatch(query: string, candidates: AsyncGenerator<string>): AsyncGenerator<string>` — for each yielded string, computes `levenshteinDistance` between the lowercased query and the lowercased candidate; yields the candidate if `distance > 0 && distance <= max(3, floor(query.length / 4))`.

2. **`apps/cli/package.json`** — add `"fuzzy-match": "*"` to dependencies.

3. **`apps/cli/src/lib/init-cmd.ts`** — migrate existing helpers and add typed secret matcher
   - Remove the `levenshteinDistance` implementation.
   - Import `fuzzyMatch` from `'fuzzy-match'`.
   - Keep `findSimilarDatabaseNames` but rewrite its body to use `fuzzyMatch`, passing an async
     generator that yields `dbEntry.name` for each entry from `getDatabases()`. Collect all yielded
     strings into an array and return it.
   - Add `findSimilarSecretNames(secretName: string, type?: string): Promise<string[]>` — passes a
     generator that yields `secret.name` for each entry from `vault.list()`, pre-filtered to
     `secret.type === type` when `type` is provided. Used directly for `secrets` command errors
     (no type filter) and for typed lookups (`'s3-credentials'`, `'api-key'`).
   - Add `findSimilarKeyNames(keyName: string): Promise<string[]>` — thin wrapper that calls
     `findSimilarSecretNames(keyName, 'encryption-key')`. Used at all `--key` /
     `--encryption-key` error sites.
   - At the "lazy-fetch key not found" error (~line 880): call `findSimilarKeyNames` with the
     key name and append "Did you mean:" hint lines before `exit(1)`.
   - At the "interactive-select key not found" error (~line 903): same pattern.

4. **`apps/cli/src/cmd/sync.ts`** — fuzzy suggestion for `--dest-key` not found (~line 91)
   - Import `findSimilarKeyNames` from `'../lib/init-cmd'`.
   - After the `log.error` for the key-not-found case, call `findSimilarKeyNames(options.destKey)`
     and append "Did you mean:" hint lines before `exit(1)`.

5. **`apps/cli/src/cmd/replicate.ts`** — fuzzy suggestions for `--dest-key` not found
   - Import `findSimilarKeyNames` from `'../lib/init-cmd'`.
   - At line 154 (`resolveKeyPemsWithPrompt` returns empty on initial check): append hint lines.
   - At line 203 (second `resolveKeyPemsWithPrompt` returns empty): append hint lines.
   - Same pattern as step 4.

6. **`apps/cli/src/cmd/dbs.ts`** — option renames, database-name suggestions, secret validation
   - Rename CLI options and their camelCase interface fields throughout:
     - `--s3-cred-id` / `s3CredId` → `--s3-cred` / `s3Cred`
     - `--encryption-key-id` / `encryptionKeyId` → `--encryption-key` / `encryptionKey`
     - `--geocoding-key-id` / `geocodingKeyId` → `--geocoding-key` / `geocodingKey`
   - Apply to both `IDbsAddOptions`, `IDbsEditOptions`, the `.option(...)` registrations, and all
     call sites that reference those fields (`dbsAdd`, `dbsEdit`).
   - Add `import { findSimilarDatabaseNames, findSimilarKeyNames, findSimilarSecretNames } from '../lib/init-cmd';`.
   - In `dbsView` (`!entry` error block, ~line 550): when `cmdOptions.name` is set, call
     `findSimilarDatabaseNames(cmdOptions.name)` and append "Did you mean:" hint lines.
   - In `dbsEdit` (`!entry` error block, ~line 629): always has `cmdOptions.name`; same pattern.
   - In `dbsRemove` (`!entry` error block, ~line 766): when `cmdOptions.name` is set, same pattern.
   - In `dbsSend` (`!entry` error block, ~line 859): when `cmdOptions.name` is set, same pattern.
   - In `dbsAdd --yes` path (~line 468): validate each provided secret option against the vault
     before saving; if missing, log the red error with suggestions and `exit(1)`:
     - `cmdOptions.encryptionKey` → `findSimilarKeyNames`
     - `cmdOptions.s3Cred` → `findSimilarSecretNames(name, 's3-credentials')`
     - `cmdOptions.geocodingKey` → `findSimilarSecretNames(name, 'api-key')`
   - In `dbsEdit --yes` path (~line 634): same three validations.
   - Error format: `log.error(pc.red('✗ …'))` stays red-only; follow with `log.info` lines for
     the hint and `  • ${pc.cyan(name)}` suggestions (matching the style in `init-cmd.ts`).

7. **`apps/cli/src/cmd/secrets.ts`** — fuzzy suggestions for secret name not found
   - Add `import { findSimilarSecretNames } from '../lib/init-cmd';` at the top.
   - In `secretsView` (`!secret` block, ~line 354): call `findSimilarSecretNames(secretName)` and
     append hint lines after `log.error`.
   - In `secretsEdit` (`!secret` block, ~line 431): same pattern.
   - In `secretsRemove` (`!secret` block, ~line 563): same pattern.
   - In `secretsSend` (`!secret` block, ~line 714, name-supplied branch): same pattern.

## Unit Tests

- **`packages/fuzzy-match/src/test/lib/fuzzy-match.test.ts`** — new test file:
  - `levenshteinDistance`: identical strings, distance 0, substitution, insertion, deletion,
    transposition, empty strings.
  - `fuzzyMatch`: yields nothing when candidates generator is empty; yields similar string within
    threshold; skips exact match (distance 0); skips strings beyond threshold; case-insensitive;
    yields multiple matches when several candidates qualify.

- **`apps/cli/src/test/lib/init-cmd.test.ts`** — update existing tests:
  - Remove `levenshteinDistance` import and its `describe` block (moved to `fuzzy-match` package).
  - Keep `findSimilarDatabaseNames` tests; mock `fuzzy-match` module instead of relying on the
    internal `levenshteinDistance`.
  - Add `describe('findSimilarSecretNames', ...)`: mock vault `list()`; test with no type filter
    (returns all secret types); test with `'encryption-key'` filter (returns only matching type);
    standard threshold/case variants.
  - Add `describe('findSimilarKeyNames', ...)`: mock vault `list()` with a mix of secret types;
    assert only `encryption-key` entries are candidates.

- **`apps/cli/src/test/cmd/dbs.test.ts`** — new test file:
  - Mock `node-utils`, `../lib/init-cmd` (spy on `findSimilarDatabaseNames`,
    `findSimilarKeyNames`, `findSimilarSecretNames`), `picocolors`, etc.
  - For each of `dbsView`, `dbsEdit`, `dbsRemove`, `dbsSend`: assert that when the lookup returns
    undefined and `findSimilarDatabaseNames` resolves to `['my-db']`, `log.info` is called with a
    line containing "Did you mean" and `my-db`.
  - For `dbsAdd --yes` and `dbsEdit --yes` with unknown `--encryption-key`, `--s3-cred`, and
    `--geocoding-key` values: assert error is logged and appropriate suggestion function is called.

- **`apps/cli/src/test/cmd/secrets.test.ts`** — new test file:
  - Mock `vault`, `../lib/init-cmd` (spy on `findSimilarSecretNames`), etc.
  - Same pattern for `secretsView`, `secretsEdit`, `secretsRemove`, `secretsSend`.

- **`apps/cli/src/test/cmd/sync.test.ts`** — new test file:
  - Mock `../lib/init-cmd` (spy on `findSimilarKeyNames`), `node-utils`, etc.
  - Assert that when `resolveKeyPemsWithPrompt` returns empty for `--dest-key` and
    `findSimilarKeyNames` resolves to `['my-key']`, the hint lines are printed.

- **`apps/cli/src/test/cmd/replicate.test.ts`** — new test file:
  - Same structure as `sync.test.ts`; cover both key-not-found error paths (lines 154 and 203).

## Smoke Tests

- Run `psi dbs view --name mydb-typo --yes` where no database named `mydb-typo` exists but
  `mydb` does → output contains "Did you mean:" with `mydb` highlighted in cyan.
- Run `psi dbs edit --name mydb-typo --yes` → same.
- Run `psi dbs remove --name mydb-typo --yes` → same.
- Run `psi secrets view --name my-secrt --yes` where `my-secret` exists → suggestions appear.
- Run `psi secrets edit --name my-secrt --yes` → same.
- Run `psi secrets remove --name my-secrt --yes` → same.
- Run `psi list --db mydb --key my-kye --yes` where `my-key` is in the vault → "Did you mean:"
  suggestion for the key name appears in the error output.
- Run `psi dbs add --yes --name mydb --path /some/path --encryption-key my-kye` where `my-key`
  is in the vault → key validation error with suggestion appears.
- Run `psi dbs add --yes --name mydb --path /some/path --s3-cred my-s3-cred-typo` where the
  correct name exists in the vault → S3 cred validation error with suggestion appears.

## Verify

- `bun run compile` from repo root — all packages compile with no TypeScript errors.
- `cd packages/fuzzy-match && bun run test` — all new unit tests pass.
- `cd apps/cli && bun run test` — all tests pass, including updated `init-cmd` tests and new
  `dbs`, `secrets`, `sync`, and `replicate` command tests.

## Notes

- `levenshteinDistance` is moved out of `init-cmd.ts` entirely; `init-cmd.ts` imports `fuzzyMatch`
  from `'fuzzy-match'` and no longer owns the DP logic.
- The threshold formula (`max(3, floor(len/4))`) is unchanged — keeping suggestion behaviour
  consistent across the CLI.
- Fuzzy suggestions for database names are only shown when the user supplies `--name`; path-based
  lookups are exact and do not benefit from edit-distance matching.
- `findSimilarSecretNames(name, type?)` covers all three secret-lookup cases with one function:
  no filter for `secrets` command errors, `'encryption-key'` for key errors (via
  `findSimilarKeyNames`), `'s3-credentials'` for S3 cred errors, `'api-key'` for geocoding errors.
- The "lazy-fetch" key error (~line 880) and the "interactive-select" key error (~line 903) both
  live inside `initCmd` — centralising key-lookup fuzzy suggestions there means all commands that
  go through `initCmd` get the benefit automatically.
- `compare.ts` routes `--dest-key` through `initCmd` (via `destOptions = { ...options, key: options.destKey }`) — already covered. `repair.ts` does the same with `--source-key`.
- `sync.ts` and `replicate.ts` have standalone dest-key error paths outside `initCmd`, so they are
  patched separately. `replicate.ts` has two such paths (lines 154 and 203).
- `--encryption-key`, `--s3-cred`, and `--geocoding-key` in `dbs add/edit --yes` are validated at
  save time (the IDs are stored as references, not resolved immediately); the vault checks added in
  step 6 make the validation explicit and surface typos before a broken entry is written.
- The option renames (`--s3-cred-id` → `--s3-cred`, etc.) are a breaking change to the CLI
  interface. This is acceptable since backward compatibility is not required.
