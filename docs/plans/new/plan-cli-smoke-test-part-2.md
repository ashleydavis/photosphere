# CLI Smoke Test Parallel Execution

## Overview
Building directly on the separated test scripts from the CLI smoke test separation plan, this plan adds parallel batch execution to the CLI smoke test orchestrator. The default invocation (`./smoke-tests.sh`) runs all independent test scripts in parallel batches of 5. Sequential execution is available via `--sequential`. The implementation follows the same pattern as the Electron smoke tests (`apps/desktop/smoke-tests.sh` in the `electron-smoke-tests` worktree). No test function bodies change; only the orchestrator and the per-script environment setup change to enable safe concurrent execution.

## Goals
- Minimal changes to existing code — only add or modify what is strictly necessary for parallel execution, so the diff is easy to review.

## Issues

## Steps

### 1. Add per-script `TEST_TMP_DIR` isolation to each individual test script
Tests 44–51 use the global `PHOTOSPHERE_VAULT_DIR` and `PHOTOSPHERE_CONFIG_DIR`, which are derived from `TEST_TMP_DIR`. If two such tests run simultaneously with the same `TEST_TMP_DIR`, they conflict. The fix is to give each individual test script its own isolated `TEST_TMP_DIR`.

In `lib/common.sh`, change the `TEST_TMP_DIR` default so that if `ISOLATED_TEST_TMP_DIR` is set (by the orchestrator for parallel runs), it takes precedence:
```
TEST_TMP_DIR="${ISOLATED_TEST_TMP_DIR:-${TEST_TMP_DIR:-./test/tmp}}"
```

In `run_script` in the orchestrator (step 2), export `ISOLATED_TEST_TMP_DIR=<base>/<script-name>` before spawning each individual script. The core group (`01-core`) is always run with the shared `TEST_TMP_DIR` (no `ISOLATED_TEST_TMP_DIR`), so its shared database state is preserved within the group.

This change requires no modifications to any test function body.

### 2. Refactor `smoke-tests.sh` orchestrator parallel execution functions
Add four functions mirroring the Electron smoke tests pattern exactly. All test output is redirected to a per-test log file — nothing from the test scripts themselves is printed to the terminal. Only the orchestrator's own `RUN / PASS / FAIL` lines appear on stdout.

#### `run_one SCRIPT_PATH`
Runs a single test script sequentially. Redirects all script output (stdout + stderr) to `$(dirname SCRIPT_PATH)/tmp/test-run.log`. Prints `RUN` before starting and `PASS` or `FAIL` after completion. Returns 0 on success, 1 on failure.

```bash
run_one() {
    local test_sh="$1"
    local dir num name log_file
    dir="$(dirname "$test_sh")"
    num="$(test_number "$test_sh")"
    name="$(test_name "$test_sh")"
    log_file="$dir/tmp/test-run.log"
    mkdir -p "$dir/tmp"
    printf "${BLUE}RUN ${NC}   %s  %s\n" "$num" "$name"
    if timeout 300 bash "$test_sh" >"$log_file" 2>&1; then
        printf "${GREEN}PASS${NC}  %s  %s\n" "$num" "$name"
        return 0
    else
        printf "${RED}FAIL${NC}  %s  %s  (log: %s)\n" "$num" "$name" "$log_file"
        return 1
    fi
}
```

#### `run_sequential SCRIPTS...`
Runs each script one at a time with `run_one`, accumulates pass/fail counts, calls `print_summary`.

```bash
run_sequential() {
    local pass=0
    local fail=0
    for t in "$@"; do
        if run_one "$t"; then
            pass=$((pass + 1))
        else
            fail=$((fail + 1))
        fi
    done
    print_summary "$pass" "$fail"
    return $((fail > 0 ? 1 : 0))
}
```

#### `run_parallel N SCRIPTS...`
Batches the scripts into groups of N. For each batch: prints `RUN` for every script in the batch, launches each as a background process with output redirected to its log file, waits for all PIDs, then prints `PASS` or `FAIL` for each. Accumulates counts across batches and calls `print_summary`. All script output goes to log files — none reaches the terminal.

```bash
run_parallel() {
    local n="$1"
    shift
    local tests=("$@")
    local pass=0
    local fail=0
    local total="${#tests[@]}"
    local i=0

    while ((i < total)); do
        local batch_tests=()
        local batch_pids=()
        local j=0
        while ((j < n && i < total)); do
            batch_tests+=("${tests[i]}")
            i=$((i + 1))
            j=$((j + 1))
        done

        for t in "${batch_tests[@]}"; do
            local dir log_file num name
            dir="$(dirname "$t")"
            num="$(test_number "$t")"
            name="$(test_name "$t")"
            log_file="$dir/tmp/test-run.log"
            mkdir -p "$dir/tmp"
            printf "${BLUE}RUN ${NC}   %s  %s\n" "$num" "$name"
            timeout 120 bash "$t" >"$log_file" 2>&1 &
            batch_pids+=($!)
        done

        local k=0
        for pid in "${batch_pids[@]}"; do
            local t num name
            t="${batch_tests[$k]}"
            num="$(test_number "$t")"
            name="$(test_name "$t")"
            if wait "$pid"; then
                printf "${GREEN}PASS${NC}  %s  %s\n" "$num" "$name"
                pass=$((pass + 1))
            else
                printf "${RED}FAIL${NC}  %s  %s  (log: %s/tmp/test-run.log)\n" "$num" "$name" "$(dirname "$t")"
                fail=$((fail + 1))
            fi
            k=$((k + 1))
        done
    done

    print_summary "$pass" "$fail"
    return $((fail > 0 ? 1 : 0))
}
```

#### `print_summary PASS FAIL`
Prints the final counts and a PASS/FAIL banner.

```bash
print_summary() {
    local pass="$1"
    local fail="$2"
    local total=$((pass + fail))
    echo ""
    if ((fail == 0)); then
        printf "${GREEN}All %d tests passed${NC}\n" "$total"
    else
        printf "${RED}%d of %d tests failed${NC}\n" "$fail" "$total"
    fi
}
```

### 3. Update `run_all_tests` to use the new execution model
Replace the sequential loop in `run_all_tests` with:
1. Run `01-core/test.sh` via `run_one` (always sequential, blocking). Abort if it fails.
2. Collect all remaining scripts via `discover_tests` (excluding `01-core`).
3. If mode is `--sequential`, call `run_sequential` on remaining scripts.
4. Otherwise, call `run_parallel N` (default N=5) on remaining scripts.
5. Combine pass/fail counts from all phases and call `print_summary`.

### 4. Update `main()` argument parsing
Add new flags:
- `--sequential` — force sequential execution of all scripts
- `--parallel [N]` — parallel execution with batch size N (default 5)
- No new flags → default to parallel with batch size 5

Keep all existing flags (`--binary`, `--tmp-dir`, `-h/--help`) and positional commands (`all`, `to X`, single test name/number, `setup`, `check-tools`, `reset`) unchanged.

Update `print_usage` / `show_usage` to document the new flags.

### 5. Update `run_test NAME_OR_NUMBER` for single-test execution
When running a single test by number or name, always run it sequentially (no parallelism needed for one test). If the test is in the core group (numbers 1–26), run `01-core/test.sh` directly. Otherwise run the individual script.

### 6. Update `to X` for partial-run execution
When running `to X`:
- Always run `01-core` first.
- Then run scripts 27–X sequentially (since `to X` is typically used for debugging, sequential is safer).

## Unit Tests
No TypeScript code is changed. No unit tests to add or update.

## Smoke Tests
- `cd apps/cli && ./smoke-tests.sh` — all tests pass; independent tests run in parallel batches of 5
- `cd apps/cli && ./smoke-tests.sh --sequential` — all tests pass sequentially
- `cd apps/cli && ./smoke-tests.sh --parallel 3` — all tests pass in batches of 3
- `cd apps/cli && ./smoke-tests.sh --parallel 10` — all tests pass in batches of 10
- `cd apps/cli && ./smoke-tests.sh 27` — runs only test 27 independently (v2-readonly), passes
- `cd apps/cli && ./smoke-tests.sh to 30` — runs core + tests 27–30, passes
- Confirm that parallel mode produces no test failures due to shared state conflicts
- Confirm that sequential mode produces the same results as parallel mode

## Verify
- `./smoke-tests.sh` completes with all tests passing and shows parallel execution in output
- `./smoke-tests.sh --sequential` completes with the same results
- Log files exist at `smoke-tests/NN-name/tmp/test-run.log` for each test run
- `./smoke-tests.sh --parallel 1` is equivalent to sequential
- Wall-clock time for `./smoke-tests.sh` is significantly less than `./smoke-tests.sh --sequential`

## Notes
- **Core group is always sequential**: Tests 1–26 share `TEST_DB_DIR` state and cannot be parallelised internally. They remain sequential as one unit.
- **Test 43 isolation**: `replicate-partial` is made fully independent in Plan 1 and joins the parallel batch pool with no special ordering requirement.
- **Per-script `TEST_TMP_DIR`**: Each individual script (27–69, except 43) gets `ISOLATED_TEST_TMP_DIR=<base>/<script-name>` set by the orchestrator. This automatically isolates `PHOTOSPHERE_VAULT_DIR` and `PHOTOSPHERE_CONFIG_DIR` for vault/dbs tests, preventing conflicts in parallel runs.
- **Timeout**: Each script has a 300-second timeout in `run_one`, matching the Electron smoke tests pattern.
- **Failure behaviour in parallel mode**: All tests in a batch run to completion even if one fails (no abort-on-first-failure within a batch). The orchestrator reports all failures at the end, but exits non-zero if any test failed.
- **No terminal output from tests**: All stdout and stderr from individual test scripts is redirected to their log file (`>"$log_file" 2>&1`). Only the orchestrator's own `RUN / PASS / FAIL` lines appear on the terminal. This is essential for parallel runs where interleaved test output would be unreadable.
- **Log files**: Each script's full output is captured at `smoke-tests/<num>-<name>/tmp/test-run.log`. The `FAIL` line prints the log path so it is easy to inspect after a failure.
