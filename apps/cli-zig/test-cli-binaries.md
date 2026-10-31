# test-cli-binaries.sh

A library the Zig CLI smoke suite sources to build the Zig `psi` into a directory that belongs to one run, and to name it for the tests.

## Why

The suites used to run whatever a plain `zig build` had last installed in the repository's `zig-out/bin`, one path for every run and never rebuilt by the suites themselves. Each run now installs its own with `zig build --prefix <allocated dir>`. The zig build cache stays shared; zig makes that safe for concurrent builds.

## How it is used

It is sourced, not run:

```bash
source "<repo>/apps/cli-zig/test-cli-binaries.sh"
```

It sources `scripts/lib/test-lib.sh` for the per-test temporary directory allocator.

| Function | What it does |
|----------|--------------|
| `build_test_zig_cli` | Allocates a directory with `photosphere_test_temp_dir zig-cli`, runs `zig build --prefix <dir>` in the repository root, and exports it as `PHOTOSPHERE_ZIG_CLI_DIR`. Builds once per shell. Returns non-zero if the build fails. |
| `test_zig_cli_path` | Prints `<PHOTOSPHERE_ZIG_CLI_DIR>/bin/psi`, with `.exe` on Windows. Fails with a message when no run built it. |
| `remove_test_zig_cli` | Removes, by name, the Zig `psi` this shell built (with its `.pdb` on Windows), then the emptied directories. Does nothing in a shell that built none, so a test never removes its runner's executable. Anything that will not go is reported on stderr. |
| `test_cli_executable_name <name>` | Prints the name with `.exe` on Windows, unchanged elsewhere. |

The runner calls `build_test_zig_cli` before any test, and calls `remove_test_zig_cli` from its exit trap after stopping the processes it started, because Windows cannot delete an executable that is still running. The tests the runner starts inherit `PHOTOSPHERE_ZIG_CLI_DIR` and find the executable through `test_zig_cli_path`, which `get_zig_cli_command` calls.

The executable is removed when the run ends. The per-test directories beside them are left for inspection, as `scripts/lib/test-lib.sh` describes.

See [Testing](../../docs/testing/README.md) for the suites themselves.
