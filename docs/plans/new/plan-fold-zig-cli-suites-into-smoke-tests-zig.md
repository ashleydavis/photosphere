# Fold the separate Zig CLI smoke suites into smoke-tests-zig

## Overview

The Zig CLI has one main smoke runner, `apps/cli/smoke-tests-zig.sh`, which finds every `apps/cli/smoke-tests-zig/<NN>-<name>/test.sh` and runs them in a rolling pool. Beside it sit five more Zig suites, each a standalone script with its own runner, its own `package.json` script, its own `what-changed.yaml` target, its own lane in `scripts/test-everything-parallel.sh` and its own CI step: `smoke-tests-encrypted-zig.sh`, `smoke-tests-lan-share-zig.sh`, `sync-smoke-test-zig.sh`, `write-lock-smoke-test-zig.sh` and `hash-cache-smoke-test-zig.sh` (all in `apps/cli/`). This plan moves every test in those five scripts into its own numbered directory under `apps/cli/smoke-tests-zig/`, so the main runner picks them up, and deletes the five scripts and everything that only exists to run them. Only the Zig suites are in scope. The TypeScript suites (`smoke-tests-encrypted.sh`, `smoke-tests-lan-share.sh`, `sync-smoke-test.sh`, `write-lock-smoke-test.sh`, `hash-cache-smoke-test.sh`, `smoke-tests/`) and the Photosphere App suite (`apps/photosphere-smoke-tests/`) are not touched: the five scripts all drive `psi`, so none of them belongs in the App suite.

## Issues

1. [x] Step 3's `capture_receiver_broadcast` starts `udp-listen.ts` "writing to the log" and prints the log's contents, without saying what happens to its stderr. The old capture discarded stderr (`2>/dev/null`) and took stdout alone, and `131` parses the result as `PSIE_RECV:{port}:{codeHash}:{fingerprint}` with parameter expansion. Any line `bun` writes to stderr that lands in the same log ends up in the parsed text.

## Steps

### Rules for every new test

- Read `98-hash-cache/test.sh`, `76-s3-write-locks/test.sh` and `78-dbs-share-cancel/test.sh` first and follow them: a `test.sh` that sets `DESCRIPTION`, sets `SCRIPT_DIR`, sources `$SCRIPT_DIR/../lib/common.sh` and sets `trap cleanup_and_show_summary EXIT`. `cleanup_and_show_summary` exits with the `$?` it finds on entry, so a test that needs cleanup of its own does what `76-s3-write-locks` does: a cleanup function whose first line is `local exit_code=$?`, which does its work and ends with `return $exit_code`, set as `trap '<cleanup function>; cleanup_and_show_summary' EXIT`. Never put any other command between the test's exit and `cleanup_and_show_summary`, or a failed test exits 0 and the runner reports PASS.
- Working directory: `smoke-tests-zig.sh` changes to `apps/cli` and starts each test with `bash <path to test.sh>`, so every test runs with `apps/cli` as its working directory, the same directory the five old scripts `cd` to. Paths relative to `apps/cli` (`test/udp-listen.ts`, `../../test`, `TEST_FILES_DIR` from `lib/common.sh`) keep working unchanged. Paths the old scripts built from their own location (`$_LAN_SHARE_SCRIPT_DIR/...`, `$SCRIPT_DIR/...`, `check-tools.sh` beside the script) are rebuilt from `$REPO_ROOT`, which `lib/common.sh` sets.
- Tool checks: `smoke-tests-zig.sh` runs `check_tools` (`apps/cli/check-tools.sh`, `run_check_tools`) once before any test, which covers ImageMagick. Tests do not repeat it. A check the runner does not make (the `sha256sum`/`shasum` check in sync and write lock) stays in the test that needs it.
- Failure reporting: `lib/common.sh`'s `test_failed` and `invoke_command` exit the test at once, which is how the runner sees a failure. Translate as follows, and keep every message the original printed:
    - Encrypted suite: `invoke_command "<desc>" "<cmd>" || { test_failed "$name"; return; }` becomes `invoke_command "<desc>" "<cmd>"` (expected exit code 0 is the default). Where the old code captured output with `output=$(invoke_command ...)`, use `invoke_command "<desc>" "<cmd>" 0 output`. Where a non-zero exit is expected, pass that exit code. `log_error "<msg>"; test_failed "$name"; return` becomes `log_error "<msg>"; test_failed "$name"`. The final `test_passed "$name"` becomes `test_passed`.
    - LAN share suite: `log_fail "<msg>"` followed by `return 1` becomes `test_failed "<msg>"`. A `log_fail` with no `return` after it (three in `test_rogue_receiver_rejected`) also becomes `test_failed "<msg>"`; the test then stops at the first failure instead of checking the rest, which still reports a failure and is noted in Notes. `log_success "<msg>"` becomes `log_success "<msg>"` from `lib/common.sh` (prints, counts nothing). The test ends with `test_passed`.
    - Sync, write lock and hash cache: every `log_error` followed by `exit 1` or `return 1` that fails the run becomes `test_failed "<msg>"`, and the script ends with `test_passed`. `lib/common.sh`'s `test_passed` and `test_failed` run `psi root-hash` and `check_merkle_tree_order` on `$TEST_DB_DIR` when it holds a database, which the sync and write lock scripts never did. Both scripts name their database `TEST_DB_DIR`, so in `136` and `137` rename it (`SYNC_DB_DIR`, `WRITE_LOCK_DB_DIR`) and leave `TEST_DB_DIR` at the value `lib/common.sh` gives it, where no database is created, so those checks do not run. After porting, `grep -n TEST_DB_DIR` on both tests returns nothing.
- `--binary`: `lib/common.sh`'s `get_cli_command` returns the compiled TypeScript `psi` when `USE_BINARY=true`, as `smoke-tests-zig.sh --binary` sets in CI, and `bun run --silent start --` otherwise. The ported `ts_verify` calls and the LAN share interop tests therefore run against the compiled TypeScript CLI in CI, where the old CI steps ran it from source. This is the same TypeScript CLI every existing test in `smoke-tests-zig/` already uses in CI, and `smoke-tests-lan-share-zig.sh --binary` already supported it.
- `NODE_ENV`: `smoke-tests-zig.sh` exports `NODE_ENV=testing`, which the encrypted suite also set, but the LAN share, sync, write lock and hash cache scripts did not. Each test ported from those four starts with `unset NODE_ENV`. That alone is not enough, because `lib/common.sh`'s `invoke_command` puts `NODE_ENV=testing` in front of every command it runs, and its `ts_verify` runs through `invoke_command`. So those tests call neither: they run commands the way the old scripts did (directly, or through `run_cli_tracked` in the LAN share tests), and the sync and write lock tests keep the old scripts' own `ts_verify` in the test, which overrides the `lib/common.sh` one for that test only, with a comment saying why, and record its timing to `$TEST_TMP_DIR/ts-verify-milliseconds.log` (the file `lib/common.sh`'s version writes and the runner sums). The hash cache and LAN share scripts have no `ts_verify` call. After porting, `grep -n 'invoke_command\|ts_verify'` on each of those tests shows only the kept local `ts_verify`.
- No `rm -r`: every `rm -rf` in the old scripts (`reset_environment`, `prepare_test_dir`, `reset_dirs`, the two in `test_receiver_cancel` and `test_cert_fingerprint_matches_broadcast`, sync's `setup_test_environment` and `create_replicas`, write lock's `setup_test_environment`) clears a directory under a run-wide root so the next test starts clean. Each new test gets a freshly allocated, empty `TEST_TMP_DIR` from the runner, so there is nothing to clear: replace each with `mkdir -p` of the same paths and write no `rm -r` anywhere.
- Background processes are started with `&`, have `$!` recorded at once (in a pid file when a watchdog or trap subshell must see them) and are waited on with `wait`; cleanup kills through `kill_process_tree` from `$REPO_ROOT/scripts/lib/process-control.sh`, never by name.
- A port asserts exactly what the original asserted: no assertion is dropped, loosened or reworded to make it pass.
- After writing each new test, run it alone with `mise exec -- bun run test:cli:zig -- <number>` from the repository root, break one of its assertions (assert a wrong value), run it again and confirm it goes red, put the assertion back and confirm it passes. A step is complete only when every test it adds has been watched fail and pass.

### Steps

1. Encrypted tests. Read `apps/cli/smoke-tests-encrypted-zig.sh` in full. Create one directory per test function, the `test.sh` holding that function's body:
    - `105-encrypted-init` from `test_init_encrypted`
    - `106-encrypted-init-generate-key-file` from `test_init_generate_key_file`
    - `107-encrypted-replicate-to` from `test_replicate_to_encrypted`
    - `108-encrypted-replicate-from` from `test_replicate_from_encrypted`
    - `109-encrypt-plain` from `test_encrypt_plain`
    - `110-encrypt-generate-key-file` from `test_encrypt_generate_key_file`
    - `111-encrypt-reencrypt` from `test_encrypt_reencrypt`
    - `112-encrypt-old-to-new-format` from `test_encrypt_old_to_new_format`
    - `113-decrypt-encrypted` from `test_decrypt_encrypted`
    - `114-encrypted-add` from `test_add_encrypted_file`
    - `115-encrypted-export` from `test_export_encrypted_file`
    - `116-encrypted-verify` from `test_verify_encrypted_db`
    - `117-encrypted-delete` from `test_delete_encrypted_file`
    - `118-encrypted-list` from `test_list_encrypted_files`
    - `119-encrypted-replicate-decrypted` from `test_replicate_decrypted_from_encrypted`
    - `120-encrypted-export-multiple-keys` from `test_export_with_multiple_keys`
    - `121-encrypt-multi-key` from `test_multi_key_encrypt`
    - `122-encrypt-partial` from `test_partial_encrypt`
    - `123-encrypted-key-not-found-noninteractive` from `test_key_not_found_noninteractive`
    - `124-encrypted-key-not-found-message` from `test_key_not_found_message`

    Details:
    - `ENCRYPTED_TESTS` lists `init-generate-key-file` and `encrypt-generate-key-file` twice each, so the second run meets a vault that already holds the key the first run generated. `106` and `110` keep that: each runs its body twice in a row against the same vault, the second time in a second database directory, with the same assertions both times.
    - The old suite kept one vault for the whole run, and the comment in `run_single_test` says some tests read a key an earlier test created. Find every test that reads a key, key file or database it did not create itself, and make it create that key, key file or database at its own start, using the same commands the earlier test used.
    - `DESCRIPTION` in each `test.sh` is the text `get_test_description` returns for that test name. Drop `print_test_header`, `get_test_description`, `reset_environment`, `check_tools`, `run_single_test`, `run_encrypted_test*`, `run_all_tests`, `show_usage` and the suite's own `log_*`, `test_passed`, `test_failed`, `get_cli_command`, `get_zig_cli_command`, `invoke_command` and `ts_verify`: `lib/common.sh` and the runner provide them.
    - `read_magic_tag`, `assert_database_assets_encrypted`, `assert_database_assets_plain` and `get_asset_id_for_filename` (and any other helper used by more than one test) go into a new `apps/cli/smoke-tests-zig/lib/encrypted.sh`, with a `#` comment block above each function, sourced by the tests that use them. A helper used by one test goes into that test. `prepare_test_dir` becomes `mkdir -p` at the call site.

2. LAN share library. Create `apps/cli/smoke-tests-zig/lib/lan-share.sh` from `apps/cli/smoke-tests-lan-share-zig.sh`, sourced after `lib/common.sh`, with a `#` comment block above every function and variable. It holds:
    - The `sha256sum` shim for macOS. Not the `timeout` shim: its only callers were the two `timeout 5` captures that step 3 replaces. (`--timeout 5` in `test_wrong_pairing_code` is an option of `psi secrets send`, the discovery window that test exercises, and stays as it is.)
    - `use_test_temp_dir` without the `photosphere_export_test_temp` call (the runner has already set `TEST_TMP_DIR` and `lib/common.sh` the temp and cache directories), called once by the library on `$TEST_TMP_DIR` to set `SENDER_VAULT_DIR`, `SENDER_CONFIG_DIR`, `RECEIVER_VAULT_DIR` and `RECEIVER_CONFIG_DIR`, followed by `mkdir -p` of the two receiver directories in place of `reset_dirs`.
    - `ZIG_CLI_CMD` set from `get_zig_cli_command` and `TS_CLI_CMD` set from `get_cli_command`, with `SENDER_CLI_CMD` and `RECEIVER_CLI_CMD` both set to `ZIG_CLI_CMD`. Not `build_test_zig_cli` or `remove_test_cli_binaries`: the runner builds and removes the binaries.
    - `RECEIVER_PID`, `TEST_PIDS`, `TEST_PID_FILE` (set to `$TEST_TMP_DIR/test-pids` and created empty), `kill_proc`, `track_test_pid`, `run_cli_tracked`, `kill_test_pids`, `test_cleanup`, `start_receiver_with_code` and `wait_for_receiver_exit`, with their `log_fail` calls translated as in the rules above.
    - A cleanup function `lan_share_exit` whose first line is `local exit_code=$?`, which calls `test_cleanup`, kills any remaining job with `kill_process_tree` and ends with `return $exit_code`. The library sets `trap 'lan_share_exit; cleanup_and_show_summary' EXIT`, so a LAN share test does not set its own trap, and `cleanup_and_show_summary` sees the test's own exit code. When step 3 watches each test fail, confirm the runner prints FAIL for it, which proves the exit code survives the trap.
    - `merge_vault_secret`, `seed_vault_secret_from_file` and `count_vault_secrets`, which `lib/common.sh` does not have.
    - Not `seed_vault_secret` or `seed_databases_config`: `lib/common.sh` already defines both, writing to `PHOTOSPHERE_VAULT_DIR` and `PHOTOSPHERE_CONFIG_DIR`. Every LAN share call `seed_vault_secret "<dir>" <name> <type> <value>` becomes `PHOTOSPHERE_VAULT_DIR="<dir>" seed_vault_secret <name> <type> <value>`, and every `seed_databases_config "<dir>" <json>` becomes `PHOTOSPHERE_CONFIG_DIR="<dir>" seed_databases_config <json>`. Before converting, compare the two pairs of functions line by line and confirm they write the same file in the same format; if they differ, stop and report the difference.
    - Not `run_test` or its watchdog subshell: the runner's per-test timeout replaces it.

3. LAN share tests. Create, each sourcing `lib/common.sh` then `lib/lan-share.sh`, starting with `unset NODE_ENV`:
    - `125-lan-share-database` from `test_share_database`
    - `126-lan-share-secret` from `test_share_secret`
    - `127-lan-share-wrong-pairing-code` from `test_wrong_pairing_code`
    - `128-lan-share-database-no-secrets` from `test_share_database_no_secrets`
    - `129-lan-share-receiver-cancel` from `test_receiver_cancel`
    - `130-lan-share-rogue-receiver-rejected` from `test_rogue_receiver_rejected`
    - `131-lan-share-cert-fingerprint` from `test_cert_fingerprint_matches_broadcast`
    - `132-lan-share-database-ts-to-zig`: `SENDER_CLI_CMD="$TS_CLI_CMD"`, then the body of `test_share_database`
    - `133-lan-share-database-zig-to-ts`: `RECEIVER_CLI_CMD="$TS_CLI_CMD"`, then the body of `test_share_database`
    - `134-lan-share-secret-ts-to-zig`: `SENDER_CLI_CMD="$TS_CLI_CMD"`, then the body of `test_share_secret`
    - `135-lan-share-secret-zig-to-ts`: `RECEIVER_CLI_CMD="$TS_CLI_CMD"`, then the body of `test_share_secret`

    The bodies of `test_share_database` and `test_share_secret` are used by three tests each, so they go into `lib/lan-share.sh` as `share_database_and_check` and `share_secret_and_check`, called by `125`/`132`/`133` and `126`/`134`/`135`. Every pairing code comes from `allocate_pairing_code`, as it does now. In `130` and `131`, `timeout 5 bun run test/udp-listen.ts ...` runs in the foreground, where its pid cannot be recorded, under a 5 second limit that a loaded machine can exceed while starting `bun`. Replace it with a wait on the events themselves, with no time limit of its own: add `capture_receiver_broadcast <code hash> <log file>` to `lib/lan-share.sh`, which starts `bun run test/udp-listen.ts "<code hash>"` in the background with stdout to the log and stderr to a separate `<log file>.stderr` (the old capture took stdout alone and discarded stderr, and `130` and `131` parse the captured text as `PSIE_RECV:{port}:{codeHash}:{fingerprint}`, so nothing `bun` writes to stderr may reach it; keeping stderr in its own file rather than `/dev/null` leaves it readable when a capture fails), records its pid with `track_test_pid`, then loops (sleeping 0.2 seconds between passes, as `start_receiver_with_code` does) until either `udp-listen.ts` has exited, which it does by itself on the first broadcast matching the code hash, or the receiver (`RECEIVER_PID`) is no longer alive, in which case it kills `udp-listen.ts` with `kill_process_tree`. It then prints the stdout log's contents, and only that. A test that gets no broadcast back fails with the original message ("Rogue test: could not capture UDP broadcast", "Cert test: could not capture UDP broadcast"). A receiver that stays alive and never broadcasts is wedged, and the runner's per-test timeout ends it, the same way `start_receiver_with_code`'s comment describes for a wedged receiver.

    Contention check, now rather than at the end: run `mise exec -- bun run test:cli:zig` (the new tests run in the pool beside each other and beside `78-dbs-share-cancel`, `79-secrets-share-cancel` and `102-share-discovery-timeout`), then `mise exec -- bun run test:parallel -- --scripts "test:cli:zig test:lan-share:cli-desktop test:cli:lan-share"`, which also pairs `test:cli:zig` with itself. Any failure in company is a bug in the new tests to find and fix before step 4. `127` waits out the sender's 60 second discovery window by design; confirm from the run's PASS line that it finishes well inside `PHOTOSPHERE_PER_TEST_TIMEOUT`.

4. Sync test. Read `apps/cli/sync-smoke-test-zig.sh` in full. Create `136-sync-parallel/test.sh`, starting with `unset NODE_ENV`, holding `setup_test_environment`, `create_replicas`, `worker_process`, `cleanup_processes`, `start_parallel_processes`, `final_sync_round`, `verify_root_hashes` and the body of `main`, with `NUM_REPLICAS=4` and `NUM_ITERATIONS=10` as values in the test.
    - Keep the script's own `ts_verify` in the test, as the `NODE_ENV` rule above requires. Drop the copies of what `lib/common.sh` provides: `detect_platform`, `detect_architecture`, `get_cli_command`, `get_zig_cli_command`, `get_bdb_command`, `log_info`, `log_success`, `log_error`, `log_warning`. Compare each copy with the `lib/common.sh` version first; where they differ, keep the behaviour the old test relied on inside the test and say why in a comment.
    - `generate_png_file` is also in the write lock script, where it differs only in reading the ImageMagick command from `IMAGEMAGICK_CONVERT_CMD`, a global set by that script's `check_dependencies`. Move the sync script's copy, which picks `magick` or `convert` itself with the same preference order, into `lib/common.sh` with a comment block, and call it from both tests. `IMAGEMAGICK_CONVERT_CMD` is not carried over.
    - `generate_uuid` is used only here: keep it in the test.
    - `check_dependencies`: keep only the `sha256sum`/`shasum` check, in the test.
    - Drop `start_suite_watchdog`, the argument parsing and `--binary` handling: the runner provides all three.

5. Write lock test. Read `apps/cli/write-lock-smoke-test-zig.sh` in full. Create `137-write-lock-parallel/test.sh`, starting with `unset NODE_ENV`, from `setup_test_environment`, `worker_process`, `cleanup_processes`, `start_parallel_processes`, `validate_results` and the body of `main`, with `NUM_PROCESSES=4`, `NUM_ITERATIONS=6` and the default sleep range as values in the test.
    - Keep its own `ts_verify`, as in step 4. Drop its copies of `detect_platform`, `detect_architecture`, `get_cli_command`, `get_zig_cli_command`, `log_info`, `log_success`, `log_error` and `log_warning`, compared first as in step 4.
    - `get_test_db_dir` becomes `"$TEST_TMP_DIR/write-lock-test-db"` inline: the cloud branch goes with the `--cloud` option.
    - `check_dependencies`: keep only the `sha256sum`/`shasum` check. The ImageMagick part, and `IMAGEMAGICK_CONVERT_CMD` with it, goes: the runner's `check_tools` checks ImageMagick, and `generate_png_file` from `lib/common.sh` (step 4) picks the command itself.
    - Drop `start_suite_watchdog`, the argument parsing (`--processes`, `--iterations`, `--sleep-range`, `--simulate-failure`, `--cloud`) and the `--simulate-failure` code path.

6. Hash cache test. Read `apps/cli/hash-cache-smoke-test-zig.sh` in full. Create `138-hash-cache-concurrency/test.sh`, starting with `unset NODE_ENV`, from it, with `NUM_PROCESSES=10` and `ENTRIES_PER_PROCESS=10` as values in the test, keeping `run_writer`, `stop_writers`, `psi_cmd` and `ts_psi_cmd`. `ts_psi_cmd` calls `get_cli_command` instead of `cd "$SCRIPT_DIR" && bun run --silent start --`, so it follows `--binary`. The writers' pids are recorded at launch and stopped through `kill_process_tree`. Drop `start_suite_watchdog` and the argument parsing.

7. Assertion check. For each of the five old scripts, list every point where the original can fail a test (each `log_fail`, `log_error` that fails, `test_failed`, `exit 1`, failing `invoke_command`, `ts_verify` and comparison) and find the matching point in the ported test. Every one must have a match that checks the same thing against the same expected value. Fix any gap in the port. Put the list (old location, new location) in the final report to the human. Then compare `129-lan-share-receiver-cancel` against `78-dbs-share-cancel` and `79-secrets-share-cancel`, `137-write-lock-parallel` against `76-s3-write-locks`, and `138-hash-cache-concurrency` against `98-hash-cache`, assertion by assertion, and put the overlapping assertions in the same report. Do not delete or merge any test.

8. Timing check. Run `mise exec -- bun run test:cli:zig` and read the duration on each new test's PASS line, then run `mise exec -- bun run tev` once and read the same lines from the `test:cli:zig` log there, where the machine is under load. Report the slowest new tests with both durations to the human. A test that takes more than half of `PHOTOSPHERE_PER_TEST_TIMEOUT` (`scripts/lib/test-timeout.sh`) in either run is reported as such; changing the limit is the human's decision.

9. Remove the old runners. Delete `apps/cli/smoke-tests-encrypted-zig.sh`, `apps/cli/smoke-tests-lan-share-zig.sh`, `apps/cli/sync-smoke-test-zig.sh`, `apps/cli/write-lock-smoke-test-zig.sh`, `apps/cli/hash-cache-smoke-test-zig.sh`, `apps/cli/smoke-tests-lan-share-zig.md` and `apps/cli/hash-cache-smoke-test-zig.md`, each with `rm` by name. Then remove what only ran them:
    - `package.json`: delete the `test:cli:encrypted:zig`, `test:cli:sync:zig`, `test:cli:write-lock:zig`, `test:cli:lan-share:zig` and `test:cli:hash-cache:zig` scripts.
    - `what-changed.yaml`: delete the targets of the same five names.
    - `scripts/test-everything-parallel.sh`: delete the same five names from `SCRIPTS`, and from `SERIAL_GROUPS` or any other list in that file that holds them.
    - `.github/workflows/release-zig-linux.yml`, `release-zig-macos-arm64.yml`, `release-zig-macos-x64.yml` and `release-zig-windows.yml`: delete the steps that run the five scripts (editing existing workflows; no new workflow is added).
    - Run `git grep -nE 'smoke-tests-encrypted-zig|smoke-tests-lan-share-zig|sync-smoke-test-zig|write-lock-smoke-test-zig|hash-cache-smoke-test-zig|test:cli:(encrypted|sync|write-lock|lan-share|hash-cache):zig'` from the repository root and fix every remaining hit outside `docs/plans/`.
    - Run `mise exec -- bun run test:cli:zig` and confirm it passes with every new test.

10. Suite and CI timeouts. Read the total time the step 9 run of `test:cli:zig` reports. `smoke-tests-zig.sh` holds the whole run to `PHOTOSPHERE_SUITE_TIMEOUT` (`scripts/lib/test-timeout.sh`): if the run takes more than half of it, report the measured time to the human and stop, because raising the limit is their decision. Otherwise leave every `timeout-minutes` in the four `release-zig-*.yml` workflows as it is. The suite watchdog ends the run at `PHOTOSPHERE_SUITE_TIMEOUT`, which sits below the `./smoke-tests-zig.sh --binary` step's `timeout-minutes`, so the watchdog fires first and the step's log survives; raising the step limit would change nothing while the watchdog stays where it is. Removing the steps in step 9 only shortens each `cli-smoke-tests` job, so its job-level `timeout-minutes` still covers it. The macOS and Windows jobs now run the LAN share tests for the first time; any failure there is a bug to find and fix in the test or the code, not to skip.

11. Documentation, last. Update:
    - `apps/cli/smoke-tests-zig/lib/ts-verify-timing.md`: drop the names of the deleted suites from the list of callers.
    - `apps/cli/test-cli-binaries.md`: drop the mention of "`--binary` in any other `*-zig` suite", since `smoke-tests-zig.sh` is now the only Zig suite runner that takes it.
    - `docs/testing/README.md`: where it describes the Zig CLI smoke tests, say that the encrypted database, LAN share, parallel sync, parallel write lock and hash cache concurrency tests are part of `test:cli:zig` and run one at a time with `bun run test:cli:zig -- <number or name>`.
    - Add `apps/cli/smoke-tests-zig/lib/encrypted.md` and `apps/cli/smoke-tests-zig/lib/lan-share.md`, one beside each new library script, saying what it is for, which tests source it and what each function takes.
## Unit Tests

None. The change adds and moves shell smoke tests only, and the repository rules ban tests for shell scripts. No TypeScript or Zig function changes.

## Smoke Tests

Every test in the five old scripts becomes a smoke test of its own under `apps/cli/smoke-tests-zig/`, numbered 105 to 138 as listed in Steps. Each is run alone, watched fail with a broken assertion and watched pass, as the rules at the top of Steps require.

## Verify

- `mise exec -- bun run test:cli:zig` from the repository root exits 0 with every new test listed as PASS.
- `mise exec -- bun run test:cli:zig -- <number>` passes for each new test number on its own.
- `mise exec -- bun run test:parallel -- --scripts "test:cli:zig test:lan-share:cli-desktop test:cli:lan-share"` exits 0.
- `mise exec -- bun run tev -- --plan` no longer lists any of the deleted scripts.
- `mise exec -- bun run tev` exits 0.
- The `git grep` from step 9 returns nothing outside `docs/plans/`.
- `git grep -n 'rm -r' -- apps/cli/smoke-tests-zig` returns nothing in the new tests and libraries.
- `mise exec -- bun run compile` exits 0.

## Notes

- The human chose no documentation review stop, so the plan starts with implementation and writes the documentation in the last step.
- The human chose to run the LAN share tests on every platform. CI used to run them on Linux only. They now run in the macOS and Windows jobs too, and any failure there is fixed, not skipped.
- Three `log_fail` calls in `test_rogue_receiver_rejected` were not followed by `return`, so the old test carried on and checked the rest after a failure. The port stops at the first failure. A failure is still reported; later checks in that test are not run after it.
- Options not carried over, because a test directory takes no arguments and neither `package.json` nor any CI workflow passes them: sync's `--replicas` and `--iterations`; write lock's `--processes`, `--iterations`, `--sleep-range`, `--simulate-failure` and `--cloud`; hash cache's `--processes` and `--entries`. S3 write locks are covered by `76-s3-write-locks`.
- Step 10 measures the run time on this machine only. CI runners are slower (the comment above `start_suite_watchdog` in `smoke-tests-zig.sh` gives windows-latest at 15 minutes normally), and the plan cannot measure them without a CI run. If a CI run of the longer suite hits the suite watchdog, that run's log names it, and the limit is the human's decision.
- Numbering starts at 105 because the highest existing number is 104. The gap at 96 and 103 is left alone.
- Possible duplicates, not merged or deleted by this plan: `129-lan-share-receiver-cancel` against `78-dbs-share-cancel` and `79-secrets-share-cancel`, `137-write-lock-parallel` against `76-s3-write-locks`, `138-hash-cache-concurrency` against `98-hash-cache`. The final report says which assertions overlap, so the human can decide.
- The TypeScript counterparts and their documentation (including `apps/cli/WRITE_LOCK_SMOKE_TEST_README.md`) are out of scope and stay as they are.
