# test-cli-binaries.sh

A library the CLI smoke suites source to build the compiled `psi`, `mk` and `bdb` executables, and the Zig port of `psi`, into directories that belong to one run, and to name those executables for the tests.

## Why

The suites used to build through the package scripts (`bun run build-win`, `build-linux`, `build-mac-x64`, `build-mac-arm64`), which all write to one fixed path per platform, such as `apps/cli/bin/x64/win/psi.exe`. On Windows a running executable cannot be replaced, so a suite rebuilding it while another suite, or another worktree's run, was executing it failed with `failed to move executable ... EPERM`. Each run now builds its own copy, so no two runs share one.

The package scripts are unchanged, for building by hand. The suites no longer read or write their output.

The `*-zig` suites likewise used to run whatever a plain `zig build` had last installed in the repository's `zig-out/bin`, one path for every run and never rebuilt by the suites themselves. Each run now installs its own with `zig build --prefix <allocated dir>`. The zig build cache stays shared; zig makes that safe for concurrent builds.

## How it is used

It is sourced, not run:

```bash
source "<repo>/apps/cli/test-cli-binaries.sh"
```

It sources `scripts/lib/test-lib.sh` for the per-test temporary directory allocator.

| Function | What it does |
|----------|--------------|
| `build_test_cli_binaries` | Allocates a directory with `photosphere_test_temp_dir cli-binaries`, builds `psi`, `mk` and `bdb` into `psi/`, `mk/` and `bdb/` inside it with the same `bun build` flags as the package scripts, and exports it as `PHOTOSPHERE_CLI_BIN_DIR`. Builds once per shell; a second call returns at once. Returns non-zero if any build fails. |
| `test_cli_binary_path <psi\|mk\|bdb>` | Prints the path of that executable under `PHOTOSPHERE_CLI_BIN_DIR`, with `.exe` on Windows. Fails with a message naming what is missing when no run built them. |
| `build_test_zig_cli` | Allocates a directory with `photosphere_test_temp_dir zig-cli`, runs `zig build --prefix <dir>` in the repository root, and exports it as `PHOTOSPHERE_ZIG_CLI_DIR`. Builds once per shell. Returns non-zero if the build fails. |
| `test_zig_cli_path` | Prints `<PHOTOSPHERE_ZIG_CLI_DIR>/bin/psi`, with `.exe` on Windows. Fails with a message when no run built it. |
| `remove_test_cli_binaries` | Removes, by name, the executables and source maps this shell built, and the Zig `psi` (with its `.pdb` on Windows) through `remove_test_zig_cli`, then the emptied directories. Does nothing in a shell that built none, so a test never removes its runner's executables. Anything that will not go is reported on stderr. |
| `remove_test_zig_cli` | The Zig half of the above, called by it. |
| `test_cli_executable_name <name>` | Prints the name with `.exe` on Windows, unchanged elsewhere. |
| `test_cli_bun_target` | Prints the `bun build --target` for this host. |

A suite runner calls `build_test_cli_binaries` when it runs against the compiled executables (a full `smoke-tests-zig.sh` run, or `smoke-tests-zig.sh --binary`), and a `*-zig` runner always calls `build_test_zig_cli`; and calls `remove_test_cli_binaries` from its exit trap after stopping the processes it started, because Windows cannot delete an executable that is still running. The tests the runner starts inherit `PHOTOSPHERE_CLI_BIN_DIR` and `PHOTOSPHERE_ZIG_CLI_DIR` and find the executables through `test_cli_binary_path`, which the test libraries' `get_cli_command`, `get_mk_command` and `get_bdb_command` call, and through `test_zig_cli_path`, which `get_zig_cli_command` calls.

The executables, about 300MB a run, are removed when the run ends. The per-test directories beside them are left for inspection, as `scripts/lib/test-lib.sh` describes.

See [Testing](../../docs/testing/README.md) for the suites themselves.
