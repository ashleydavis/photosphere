# Per-test temporary directories

## Overview

Every test, not every suite, must own a uniquely named temporary directory for its fixtures, artifacts and logs, and must get one without opting in. Today isolation is opt-in and inconsistent, so tests share directories and interfere with each other. Three separate failures traced to this: one suite deleted `/tmp/photosphere` while another was writing its log header there, giving `ENOENT ... /tmp/photosphere/logs/psi-*.log`; concurrent mobile runs shared `tests/<name>/tmp` until a per-run directory was bolted on; and those per-run directories then accumulated in their thousands because nothing removed them, slowing a run from 15 seconds to 46. The goal is that no test can be affected by, or affect, any other test's files, and that this holds by construction rather than by each suite remembering to arrange it.

Concretely: `getProcessTmpDir()` in `packages/node-utils/src/lib/fs.ts` returns `os.tmpdir()` unless `TEST_TMP_DIR` is set, and the CLI appends a fixed `photosphere` segment, so every CLI process on the machine shares one directory. `apps/cli/smoke-tests.sh` sets `TEST_TMP_DIR` (it was not exported until recently, which is what caused the deletion). `apps/cli/smoke-tests-lan-share.sh` and `apps/cli/smoke-tests-encrypted.sh` set it without exporting. `apps/smoke-tests` (mobile) never sets it at all, while 16 of its tests invoke the CLI. `apps/desktop/smoke-tests.sh` gives each test a fixed `<test>/tmp`, shared by concurrent runs. Unit tests are better but inconsistent: 18 use `mkdtempSync`, 27 build names from `Date.now()`, which collides when two tests start in the same millisecond.

## Issues

## Steps

1. Add `createTestTempDir(label: string): string` and `removeTestTempDir(dir: string): void` to `packages/node-utils/src/lib/test-temp-dir.ts` (new file). `createTestTempDir` creates a directory under the process temp root using `fs.mkdtempSync` with a prefix built from `label`, so uniqueness comes from the OS rather than from a timestamp or counter, and returns its absolute path. `removeTestTempDir` removes a directory only when it sits under the process temp root, and throws otherwise, so a wrong path cannot delete something real. Export both from `packages/node-utils/src/index.ts`.

2. Add `getTestTempRoot(): string` to the same file, returning the directory that per-test directories are created inside: `path.join(getProcessTmpDir(), "photosphere-tests")`. Keep it separate from the CLI's own `photosphere` directory so a test tree can never be confused with, or deleted by, a product code path such as `clearCacheCommand`.

3. Change `getProcessTmpDir()` in `packages/node-utils/src/lib/fs.ts` to read `PHOTOSPHERE_TEST_TMP_ROOT` in preference to `TEST_TMP_DIR`, keeping `TEST_TMP_DIR` working for now so nothing breaks mid-migration. Document in the comment that the new variable is set per test rather than per suite.

4. Add `photosphere_test_temp_dir <label>` to `apps/smoke-tests/lib/common.sh`, which creates a unique directory with `mktemp -d` under the suite's temp root and prints its path. Add `photosphere_export_test_temp <dir>` which exports `PHOTOSPHERE_TEST_TMP_ROOT` and `TEST_TMP_DIR` pointing at it, so every child process the test starts, including the CLI, writes inside the test's own directory.

5. Change `apps/smoke-tests/lib/runner.sh` so the worker loop allocates a fresh directory per test with `photosphere_test_temp_dir "$name"` before running it, exports it, and passes it down in place of the current `PHOTOSPHERE_TEST_TMP` scheme. Remove `RUN_TMP_NAME` and the `rm -rf "$dir/$RUN_TMP_NAME"` wipe: with a unique directory per test there is nothing to wipe beforehand.

6. Change `apps/smoke-tests/run.sh` to stop setting `PHOTOSPHERE_TEST_TMP` to `tmp/run-$$`, since step 5 makes it redundant.

7. Change `apps/smoke-tests/lib/common.sh` so `TMP_DIR` in each test comes from the allocated directory rather than from `TEST_TMP_NAME`, and remove `TEST_TMP_NAME`.

8. Change `apps/desktop/smoke-tests.sh` to allocate a unique directory per test the same way, replacing the fixed `<test>/tmp` and its `rm -rf`/`mkdir` pair. Update `apps/desktop/smoke-tests/lib/common.sh` to take the directory from the environment.

9. Export `TEST_TMP_DIR` in `apps/cli/smoke-tests-lan-share.sh` and `apps/cli/smoke-tests-encrypted.sh`, and change both to allocate per-test directories rather than one directory for the whole suite. `apps/cli/smoke-tests.sh` already exports it; change it to allocate per test as well.

10. Add retention and cleanup: after a test passes, remove its directory; after a test fails, keep it and print its path. Implement in the runner loops changed in steps 5 and 8. This replaces the accumulation problem rather than reintroducing it, and keeps exactly the evidence that is useful.

11. Add `PHOTOSPHERE_KEEP_TEST_TEMP=1` support to the runners so a developer can keep directories for passing tests too when debugging. Document it in `docs/testing/README.md`.

12. Migrate unit tests that build temp paths from `Date.now()` to `createTestTempDir`. The 27 call sites are in `packages/node-api/src/test/`, `packages/node-utils/src/test/` and `packages/storage/src/test/`; find them with a grep for `Date.now()` near `getProcessTmpDir` or `os.tmpdir`. Each test allocates in `beforeEach` and removes in `afterEach`.

13. Add a check to `scripts/find-flakey-tests.sh` reporting how many directories exist under the test temp root at the end of a session, so a leak becomes visible immediately rather than after thousands have built up.

14. Update `docs/testing/README.md` with a short section stating that every test gets its own directory automatically, where it lives, when it is kept, and how to keep it deliberately.

Each step must compile (`bun run compile`), keep the unit suite green (`bun run test`), and keep the affected smoke suite green before it is considered done.

## Unit Tests

- `createTestTempDir` returns a path that exists, is inside the test temp root, and differs from a second call with the same label.
- `createTestTempDir` includes the label in the directory name, so a stray directory can be traced to its test.
- `removeTestTempDir` removes a directory under the test temp root.
- `removeTestTempDir` throws, and removes nothing, for a path outside the test temp root. Must be watched failing against a version with the guard removed.
- `getTestTempRoot` is inside `getProcessTmpDir()` and is not the CLI's own `photosphere` directory.
- `getProcessTmpDir` prefers `PHOTOSPHERE_TEST_TMP_ROOT` over `TEST_TMP_DIR`, uses `TEST_TMP_DIR` when only that is set, and falls back to `os.tmpdir()` when neither is.

## Smoke Tests

- Extend `apps/desktop/smoke-tests/lib/common.test.sh` with a case asserting each test receives a directory that no other test has, by allocating twice and comparing.
- Add a shell test for `photosphere_test_temp_dir` and `photosphere_export_test_temp` in `apps/smoke-tests/`: two allocations differ, the exported variables point inside the allocated directory, and a child process writing to `getProcessTmpDir()` lands inside it.
- Add a case proving a passing test's directory is removed and a failing test's directory is kept with its path printed.
- Run `bun run test:and` twice concurrently out of one checkout and assert neither run's directories are touched by the other. This is the case the current design fails.
- Run `bun run test:cli` with a marker file in `/tmp/photosphere` and assert the marker survives, proving no suite reaches outside its own directory.

## Verify

- `bun run compile` exits 0.
- `bun run test` passes, including the new unit tests.
- `bun run test:cli`, `bun run test:electron` and `bun run test:and` each pass.
- After a full `bun run test:and`, the number of directories under the test temp root equals the number of failed tests, and is zero when all pass.
- `grep -rn "TEST_TMP_NAME\|PHOTOSPHERE_TEST_TMP=" apps/` returns nothing, confirming the old scheme is gone.
- Two concurrent `bun run test:and` runs both pass.

## Notes

- The CLI's own temp directory (`getProcessTmpDir()/photosphere`) is deliberately left as it is. It is correct for a person running `psi`, and the isolation comes from pointing `getProcessTmpDir()` at a per-test root during tests, not from changing what the product does.
- `clearCacheCommand` in `apps/cli/src/cmd/clear-cache.ts` deletes `getProcessTmpDir()/photosphere` outright. With per-test roots that deletion is confined to the test that ran it, which is what makes the current `hash-cache clear` failure impossible rather than merely unlikely. Worth stating in the commit message.
- Keeping directories for failed tests only is a deliberate trade. Keeping everything is what caused the accumulation; keeping nothing throws away the evidence that made several of these failures diagnosable.
- Uniqueness must come from `mkdtemp`, not from `Date.now()` or a counter. Two tests starting in the same millisecond is exactly the case that a timestamp misses, and 27 existing call sites do it that way.
- Open question: whether `packages/storage` tests that create their own temp trees should also migrate, or whether their existing `mkdtempSync` usage is already sufficient. They appear safe, but were not audited in detail during this research.
- This plan does not address the emulator network stalls or any other current flaky failure. It removes one class of interference between tests and nothing more.
