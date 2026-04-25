# Plan: Fuzzy Database Name Suggestions on "No Database Found"

## Overview
When `--db` is given a value that doesn't match any registered database name or path,
the CLI currently shows a bare "No database found at: <value>" error with no further
guidance. This plan adds fuzzy-match suggestions ("Did you mean: ash-and-ant-digital-ocean?")
to the error output, making near-miss typos immediately actionable.

## Steps

1. In `apps/cli/src/lib/init-cmd.ts`, after `resolveDatabaseEntry` (~line 511), add two
   new exported functions:
   - `levenshteinDistance(a: string, b: string): number` — standard DP Levenshtein
     implementation, pure string utility.
   - `findSimilarDatabaseNames(dbValue: string): Promise<string[]>` — loads registered
     databases via `getDatabases()`, returns names whose case-insensitive Levenshtein
     distance from `dbValue` is ≤ `Math.max(3, Math.floor(dbValue.length / 4))`.

2. In `loadDatabase()` in the same file, at the "No database found" error block
   (~line 794), check `if (!matchedEntry)` (meaning the value was never resolved to
   a known database), call `findSimilarDatabaseNames(dbDir)`, and if any results are
   returned append them to the error string:
   ```
   \n\nDid you mean:\n  • <name>
   ```

## Unit Tests

Add to `apps/cli/src/test/lib/init-cmd.test.ts`:

- Export `levenshteinDistance` and `findSimilarDatabaseNames` from `init-cmd.ts` and add
  them to the import line.
- `describe('levenshteinDistance', ...)`:
  - identical strings → 0
  - one substitution → 1
  - one insertion → 1
  - multi-character swap (e.g. `ant-and-ash` vs `ash-and-ant`) → 4
- `describe('findSimilarDatabaseNames', ...)` — mock `getDatabases` (from `node-utils`):
  - close name returned when distance within threshold
  - exact match excluded (distance 0)
  - unrelated name not returned when distance exceeds threshold
  - empty list returned when no databases registered

## Smoke Tests

No new smoke tests needed; existing CLI smoke tests cover `list` command invocation.
Manual verification is sufficient (see Verify below).

## Verify

```sh
# Should show "Did you mean: ash-and-ant-digital-ocean" in the error
bun run start -- list --db ant-and-ash-digital-ocean

# Unit tests should pass
cd apps/cli && bun run test -- src/test/lib/init-cmd.test.ts
```

Expected error output shape:
```
✗ No database found at: ant-and-ash-digital-ocean
  The database directory must contain a ".db" folder with files.dat or tree.dat.

To create a new database at this directory, use:
  psi init --db ant-and-ash-digital-ocean

Did you mean:
  • ash-and-ant-digital-ocean
```

## Notes

- `matchedEntry === undefined` is used as the guard so suggestions are only shown when
  the value never resolved to a known database — not when a known path simply has
  missing files.
- Threshold formula `Math.max(3, Math.floor(length / 4))` gives distance 6 for a
  24-character name, comfortably catching the 4-edit distance between
  `ant-and-ash-digital-ocean` and `ash-and-ant-digital-ocean`.
- No external fuzzy-match library is needed; the Levenshtein DP is ~20 lines.
