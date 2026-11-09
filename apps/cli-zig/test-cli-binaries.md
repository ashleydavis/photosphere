# test-cli-binaries.sh

A library the Zig CLI smoke suite sources to build the Zig `psi` into a directory that belongs to one run, and to name it for the tests.

## Why

The suites used to run whatever a plain `zig build` had last installed in the repository's `zig-out/bin`, one path for every run and never rebuilt by the suites themselves. Each run now installs its own with `zig build --prefix <allocated dir>`. The zig build cache stays shared; zig makes that safe for concurrent builds.

## How it is used

It is sourced, not run:

```bash
source "<repo>/apps/cli-zig/test-cli-binaries.sh"
```

It sources `scripts/lib/test-lib.sh` for the per-test temporary directory allocator. Each of its functions is described above it in the script.

The runner calls `build_test_zig_cli` before any test, and calls `remove_test_zig_cli` from its exit trap after stopping the processes it started, because Windows cannot delete an executable that is still running. The tests the runner starts inherit `PHOTOSPHERE_ZIG_CLI_DIR` and find the executable through `test_zig_cli_path`, which `get_zig_cli_command` calls.

The executable is removed when the run ends. The per-test directories beside them are left for inspection, as `scripts/lib/test-lib.sh` describes.

See [Testing](../../docs/testing/README.md) for the suites themselves.
