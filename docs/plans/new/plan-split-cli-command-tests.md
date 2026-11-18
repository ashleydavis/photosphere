# Split the CLI command tests into one test file per command

## Decisions not approved by a human

None

## Acceptance criteria

- Every test of a CLI command lives in the test file of that command, `apps/cli-zig/src/test/<command>.test.zig`, named after its source file `apps/cli-zig/src/cmd/<command>.zig`.
- `commands.test.zig`, `cmd.test.zig`, `cli-c-databases.test.zig`, `cli-d-commands.test.zig`, `cli-d-rest-commands.test.zig` and `dbs-interactive.test.zig` no longer exist.
- The set of CLI test names is exactly the same before and after, and the `cli-tests` pass count is unchanged.
- `zig build test -Dcli-test-file=<command>.test.zig` runs the tests of that one command.
- The documentation says where a command's tests go.

## Overview

The tests of the CLI commands are spread over a few files that each mix many commands. `apps/cli-zig/src/test/commands.test.zig` alone is about 4,270 lines with 90 tests for most of the commands, and `cmd.test.zig`, `cli-c-databases.test.zig`, `cli-d-commands.test.zig`, `cli-d-rest-commands.test.zig` and `dbs-interactive.test.zig` mix several more. That makes a command's tests hard to find and makes it impossible to run one command's tests on their own. Each command already has its own source file in `apps/cli-zig/src/cmd/`. This plan gives each command its own test file to match, moves every test into it word for word, and moves the helpers that more than one command's tests use into one shared, non-test helper file. No test changes what it asserts.

## Issues

## Steps

1. **Record the starting point.**
   - Create `tmp/evidence/compile`, `tmp/evidence/tests` and `tmp/evidence/acceptance` in the repository root (the project's `tmp/` is already in `.gitignore`).
   - Run `grep -h '^test "' apps/cli-zig/src/test/*.test.zig | sort > tmp/evidence/acceptance/test-names-before.txt`.
   - Run `mise exec -- zig build test --summary all 2>&1 | tee tmp/evidence/tests/before.txt` from the repository root and confirm it passes. Record the `run test cli-tests <N> pass` count from it in this step's notes.

2. **Create the shared helper file `apps/cli-zig/src/test/command-test-helpers.zig`.**
   - The name does not end in `.test.zig`, so the build in `build.zig` (the CLI test loop that copies every depth-1 `.zig` file of `apps/cli-zig/src/test` and imports only the `.test.zig` ones) copies it beside the tests without making it a test root. Nothing in `build.zig` changes.
   - Move into it, as `pub fn` or `pub const`, every helper of `commands.test.zig`, `cmd.test.zig`, `cli-c-databases.test.zig`, `cli-d-commands.test.zig` and `cli-d-rest-commands.test.zig` that the tests of more than one command call. From `commands.test.zig` these include `zigCliPath`, `runZig`, `expectResult`, `setup`, `normalizeTaskIds`, `maskRetainedSessionDir`, `normalize`, `runZigWithInput`, `runZigToFile`, `runZigWithPrompts`, `usePathOfEmptyDirectory` and `bug_report_hint`. Decide each by searching for its callers with `grep -n "<name>(" apps/cli-zig/src/test/<file>.test.zig` and mapping each caller to its command with the rules in step 3.
   - Several files define a helper with the same name (`zigCliPath`, `runZig`, `expectResult`, `maskRetainedSessionDir`, `normalize`, `setup`, `expectContains`). Compare the bodies. Where they are identical, keep one copy. Where they differ (for example `setup` in `cli-c-databases.test.zig` takes a databases config and a vault, unlike `setup` in `commands.test.zig`), keep each under a name that says what it sets up, such as `setupV6Database` and `setupConfigAndVaultDatabase`, and change its callers to the new name.
   - A helper that only one command's tests call is not moved here. It goes with those tests in step 3.
   - Keep every helper's comment block, and keep its body unchanged apart from the renames above. Imports go at the top of the file in `const` declarations.

3. **Move every test into its command's file, one command at a time.** Run the steps below for each command file in `apps/cli-zig/src/cmd/`, in alphabetical order.
   - Each test goes to the file of the command it runs, with its comment and any constants or helpers only it uses, moved word for word. Then remove it from the file it came from in the same edit, so no test runs twice.
   - The destination is `apps/cli-zig/src/test/<command>.test.zig`, where `<command>` is the stem of the source file in `apps/cli-zig/src/cmd/`, the file that implements the command or subcommand the test runs. Create the file when it does not exist, with `const` imports at the top for the modules its tests use, and `const helpers = @import("command-test-helpers.zig");` when it uses the shared helpers. Call the shared helpers through that name.
   - Where the file already exists, append the tests to it: `bug.test.zig`, `debug.test.zig`, `news.test.zig`, `hash-cache-tools.test.zig` and `tools-cmd.test.zig`.
   - Two command files share a stem with a library file whose tests already hold the plain name.
     - `src/cmd/tools.zig` keeps `tools-cmd.test.zig`, which already holds its tests.
     - `src/cmd/find-orphans.zig` gets `find-orphans-cmd.test.zig`. `find-orphans.test.zig` stays the test file of `src/lib/find-orphans.zig`.
   - A test whose name names more than one command goes to the file of the first command it names: "root-hash and database-id print the values" to `root-hash.test.zig`, "origin and set-origin read and write the origin" to `origin.test.zig`, "list and summary report a database with no assets" to `list.test.zig`, "the replicate and verify options default to undefined" to `replicate.test.zig`.
   - A test of a function rather than a command run goes to the file of the command whose source file defines the function:
     - "configOrigin reads a string origin and nothing else" goes to `sync.test.zig` (`cli.sync.configOrigin`).
     - "info classifyInput tells an asset id and a hash from a path" goes to `info.test.zig`.
     - The "... is a problem" and "has no problems" tests of `cmd.test.zig` go to `verify.test.zig`.
     - "watchSettings ..." and "the add progress line ..." go to `add.test.zig`, because `watchSettings` is in `src/cmd/add.zig`.
   - "help prints the help of the program" and "help prints the help of a command" go to `help.test.zig`. They test the `help` command, which has no source file of its own in `src/cmd/`. "--version prints the version" goes to `version.test.zig`.
   - The prompt tests of `dbs-interactive.test.zig` go to `dbs.test.zig`, with its constants (`down`, `enter`, `seed_config`, `seed_vault`, `cancel`). Rename a constant with a clashing name the same way as the helpers in step 2.
   - After each command, run `mise exec -- zig build test -Dcli-test-file=<command>.test.zig --summary all` and confirm every test in the file passes. Append the output to `tmp/evidence/tests/per-command.txt`.

4. **Confirm the old multi-command files hold no tests.** Run `grep -c '^test "' apps/cli-zig/src/test/commands.test.zig apps/cli-zig/src/test/cmd.test.zig apps/cli-zig/src/test/cli-c-databases.test.zig apps/cli-zig/src/test/cli-d-commands.test.zig apps/cli-zig/src/test/cli-d-rest-commands.test.zig apps/cli-zig/src/test/dbs-interactive.test.zig` and confirm every count is 0. Any test left over goes to its command's file by the rules in step 3. Remove whatever is left in those files (imports and helpers no test calls any more) by editing each file down to empty.

5. **Compile and run the whole CLI test program.**
   - Run `mise exec -- zig build --summary all 2>&1 | tee tmp/evidence/compile/build.txt` and confirm it succeeds.
   - Run `mise exec -- zig build test --summary all 2>&1 | tee tmp/evidence/tests/after.txt` and confirm it passes with the same `cli-tests` pass count recorded in step 1.
   - Run `grep -h '^test "' apps/cli-zig/src/test/*.test.zig | sort > tmp/evidence/acceptance/test-names-after.txt` and `diff tmp/evidence/acceptance/test-names-before.txt tmp/evidence/acceptance/test-names-after.txt | tee tmp/evidence/acceptance/test-names-diff.txt`, and confirm the diff is empty.

6. **Write the documentation.** In `docs/testing/README.md`, add a sentence after the paragraph that explains `bun run test:zig` and `-Dcli-test-file`. It says:
   - Each CLI command's tests are in `apps/cli-zig/src/test/<command>.test.zig`, named after `apps/cli-zig/src/cmd/<command>.zig`.
   - The two exceptions are `tools-cmd.test.zig` and `find-orphans-cmd.test.zig`, where a library file has the plain name.
   - Helpers that several commands' tests share are in `apps/cli-zig/src/test/command-test-helpers.zig`.
   - `-Dcli-test-file=<command>.test.zig` runs one command's tests.

7. **Verify.** Run the checks in the "Verify" section and save their output in `tmp/evidence/`.

8. **Self Review.** Check the evidence the earlier steps saved in `tmp/evidence/`, and tick each item of the "Review" checklist only when its evidence confirms it. Uncheck any earlier step that is incomplete, and add a step before Verify for anything missed.

9. **Clean up.** Delete the six emptied files: `apps/cli-zig/src/test/commands.test.zig`, `apps/cli-zig/src/test/cmd.test.zig`, `apps/cli-zig/src/test/cli-c-databases.test.zig`, `apps/cli-zig/src/test/cli-d-commands.test.zig`, `apps/cli-zig/src/test/cli-d-rest-commands.test.zig` and `apps/cli-zig/src/test/dbs-interactive.test.zig`. Then run `mise exec -- zig build test --summary all 2>&1 | tee tmp/evidence/tests/after-clean-up.txt` and confirm the same `cli-tests` pass count again.

## Unit Tests

- No test is added, changed or removed. Every existing CLI test moves word for word to its command's file, and its assertions stay as they are.
- The helpers moved into `command-test-helpers.zig` keep their bodies. They are covered by the tests that call them, as they are now.

## Smoke Tests

- None change. `bun run test:cli:zig` runs the CLI smoke tests in `apps/cli-zig/smoke-tests-zig/`, which do not depend on how the unit test files are laid out, and it is run in Verify to confirm that.

## Verify

- `mise exec -- zig build` succeeds (evidence in `tmp/evidence/compile`).
- `mise exec -- bun run tev` passes (evidence in `tmp/evidence/tests/tev.txt`). This is the full set for this machine: compile, the TypeScript unit tests, `test:zig` (which includes the CLI unit tests) and `test:cli:zig`.
- The `cli-tests` pass count after the move equals the count recorded in step 1 (evidence in `tmp/evidence/tests/before.txt` and `tmp/evidence/tests/after.txt`).
- `tmp/evidence/acceptance/test-names-diff.txt` is empty.
- `mise exec -- zig build test -Dcli-test-file=info.test.zig --summary all` runs only the info tests and passes (evidence in `tmp/evidence/acceptance/info-only.txt`).
- `ls apps/cli-zig/src/test/commands.test.zig apps/cli-zig/src/test/cmd.test.zig apps/cli-zig/src/test/cli-c-databases.test.zig apps/cli-zig/src/test/cli-d-commands.test.zig apps/cli-zig/src/test/cli-d-rest-commands.test.zig apps/cli-zig/src/test/dbs-interactive.test.zig` reports every file missing, after Clean up (evidence in `tmp/evidence/acceptance/old-files.txt`).

## Review

- [ ] The code compiles (evidence in `tmp/evidence/compile`).
- [ ] All tests have passed (evidence in `tmp/evidence/tests`).
- [ ] Acceptance criteria has been met (evidence in `tmp/evidence/acceptance`, including screenshots for GUI apps).
- [ ] The documentation is updated and accurate to the code. When the plan had a documentation review stop and the human approved the documentation, the code conforms to the approved documentation. Otherwise the documentation conforms to the code. Check the documentation against the rules too.
- [ ] Local project rules have been followed.
- [ ] Global rules have been followed.

## Reviewed

- [ ] The code compiles (evidence in `tmp/evidence/compile`).
- [ ] All tests have passed (evidence in `tmp/evidence/tests`).
- [ ] Acceptance criteria has been met (evidence in `tmp/evidence/acceptance`, including screenshots for GUI apps).
- [ ] The documentation is updated and accurate to the code. When the plan had a documentation review stop and the human approved the documentation, the code conforms to the approved documentation. Otherwise the documentation conforms to the code. Check the documentation against the rules too.
- [ ] Local project rules have been followed.
- [ ] Global rules have been followed.

## Review issues

## Notes

- The human asked for no documentation review stop, so the documentation is written in step 6, after the move.
- Each command already has its own source file in `apps/cli-zig/src/cmd/` (36 files, one per command; `dbs` and `secrets` hold their subcommands). Only the tests are split.
- `build.zig` needs no change. Its CLI test loop imports every depth-1 `*.test.zig` in `apps/cli-zig/src/test` into one generated root and copies every depth-1 `.zig` file beside it, so new test files are picked up and `command-test-helpers.zig` is importable. Files must stay at depth 1: the loop skips subdirectories, so a `cmd/` subdirectory of test files would not run.
- `-Dcli-test-file` matches one file name exactly, which is why one file per command makes one command's tests runnable on their own.
- Files that stay as they are, because they test library modules or the CLI's infrastructure rather than a command: `cli-a-infrastructure.test.zig`, `cli-b-setup.test.zig`, `init-cmd.test.zig` (`src/lib/init-cmd.zig`), `sync-watch.test.zig` (`src/lib/sync-watch.zig`), `find-orphans.test.zig` (`src/lib/find-orphans.zig`), `mcp-tools.test.zig` (the MCP server's tools), and the other library test files.
- `tools-cmd.test.zig` keeps its name, and the find-orphans command's tests go in `find-orphans-cmd.test.zig`, because `src/lib/find-orphans.zig` already owns `find-orphans.test.zig`. The `-cmd` suffix is the convention this directory already uses for that clash.
- Nothing references the files being removed: a search of `docs`, `apps`, `scripts`, `build.zig`, `package.json`, `what-changed.yaml` and `.github` found no mention of `commands.test.zig`, `cmd.test.zig`, `cli-c-databases`, `cli-d-commands`, `cli-d-rest-commands` or `tools-cmd.test`.
- Tests stay word for word, and no assertion changes. A test that seems to belong to two commands goes by the first command its name names, so no test is split or rewritten.
- Duplicated helpers that differ between files are renamed, not merged, because merging them would change what some tests do.
