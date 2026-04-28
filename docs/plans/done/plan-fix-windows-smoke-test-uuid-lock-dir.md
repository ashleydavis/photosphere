# Fix Windows Smoke Test Failures: UUID Lock File ENOENT

## Problem

All smoke tests that exercise the CLI database commands fail on Windows CI with:

```
Error: ENOENT: no such file or directory, open 'test\tmp\<test-name>\photosphere-test-uuid-counter.lock'
    at acquireLock (packages\node-utils\src\lib\test-uuid-generator.ts:57:35)
    at generate (packages\node-utils\src\lib\test-uuid-generator.ts:26:14)
```

## Cause

`acquireLock()` in `TestUuidGenerator` calls `fs.openSync` with `O_CREAT|O_EXCL` to create the
lock file, but `openSync` does not create missing parent directories. On Windows CI the per-test
tmp directory (e.g. `test\tmp\01-create-database`) does not exist when the first UUID is
generated, so `openSync` throws ENOENT. The exception is caught by the spin loop, and after the
5-second stale-lock timeout the same `openSync` is retried at line 57 without a parent-directory
guard, so it throws again — this time uncaught, crashing the process.

The current `generate()` method has an `existsSync` + `mkdirSync` guard (lines 22-25) added as
a partial fix, but placing it in `generate()` is fragile: the stale-lock retry branch in
`acquireLock()` is not protected. The cleaner fix is to move directory creation into
`acquireLock()` itself, unconditionally, so every `openSync` call (including the retry) is
guaranteed to have its parent directory.

## Fix (brief)

Replace the `existsSync` + `mkdirSync` block in `generate()` with an unconditional
`fs.mkdirSync(path.dirname(this.lockFilePath), { recursive: true })` at the top of
`acquireLock()`. Because `mkdirSync` with `recursive: true` is idempotent (no-op when the
directory already exists), this is safe under concurrent processes.

## Issues

<!-- populated by plan:check -->

## Steps

1. **`packages/node-utils/src/lib/test-uuid-generator.ts` — `acquireLock()`**
   Add `fs.mkdirSync(path.dirname(this.lockFilePath), { recursive: true });` as the very first
   statement of `acquireLock()`, before the spin loop.

2. **`packages/node-utils/src/lib/test-uuid-generator.ts` — `generate()`**
   Remove the now-redundant `existsSync` + `mkdirSync` block (lines 22-25) and its comment.

## Unit Tests

- `packages/node-utils/src/test/test-uuid-generator.test.ts`
  - Add a test that calls `generate()` when the `TEST_TMP_DIR` directory does not yet exist and
    verifies that the call succeeds and the counter directory is created.

## Smoke Tests

- Run the full CLI smoke test suite on Windows (or a Windows CI run) and confirm tests
  01–43 and 49–51 no longer fail with ENOENT.
- Run the CLI smoke tests on Linux/macOS to confirm no regression.

## Verify

```bash
# Compile
bun run compile

# Unit tests for the affected package
cd packages/node-utils && bun run test

# Full smoke tests (local Linux run as a sanity check)
cd apps/cli && bun run test:smoke
```

## Notes

- The `existsSync` check before `mkdirSync` was an unnecessary optimisation; `mkdirSync` with
  `recursive: true` is already idempotent and cheap, so the extra stat call adds complexity
  without benefit.
- Only tests that go through `TestUuidGenerator.generate()` are affected (i.e. tests run with
  `NODE_ENV=testing`). Credential/vault management tests (44-48, 52-63) do not call this path
  and pass fine on Windows.
- Tests 49, 50, 51, 59, 60 also fail on Windows for the same root cause despite not using the
  `init` command directly; they trigger UUID generation elsewhere in the same code path.
