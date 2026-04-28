# Fix macOS `timeout` Command Not Found in Smoke Tests

## Overview
On macOS, the GNU `timeout` command is not available by default — it is a Linux/GNU coreutils utility. The smoke test script (`smoke-tests.sh`) calls `timeout` unconditionally, causing every single test to fail immediately on macOS CI runners. The fix adds a compatibility shim near the top of the script that detects macOS and either aliases `timeout` to `gtimeout` (from Homebrew's `coreutils` package) or exits with a clear installation instruction.

## Steps
1. Open `apps/cli/smoke-tests.sh`.
2. Near the top of the script (after the shebang and before any test logic), add a macOS compatibility block:
   ```bash
   # macOS doesn't have GNU timeout; use gtimeout from coreutils or a fallback
   if [[ "$OSTYPE" == "darwin"* ]]; then
       if command -v gtimeout &>/dev/null; then
           timeout() { gtimeout "$@"; }
       else
           echo "[ERROR] 'timeout' not available. Run: brew install coreutils" >&2
           exit 1
       fi
   fi
   ```
3. Verify that the shim is placed before line 464 (the first use of `timeout`).

## Unit Tests
None — this is a shell script change with no TypeScript unit tests to write.

## Smoke Tests
Run the full smoke test suite on a macOS environment to confirm all 63 tests pass:
```
bun run test:cli
```

## Verify
- All 63 smoke tests pass on macOS (zero `timeout: command not found` errors).
- Smoke tests continue to pass unchanged on Linux.

## Notes
- `gtimeout` is provided by `brew install coreutils`. macOS CI runners (e.g. GitHub Actions `macos-latest`) do not include it by default; the CI workflow may need a `brew install coreutils` step added before running smoke tests.
- An alternative is to vendor a pure-shell `timeout` fallback (using `( sleep N; kill $! ) &`), but relying on `gtimeout` is simpler and more reliable.
