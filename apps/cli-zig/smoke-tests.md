# smoke-tests.sh

Runs the Zig CLI smoke tests: every `smoke-tests/<number>-<name>/test.sh`, each in a directory of its own, through the rolling test pool in `scripts/lib/test-pool.sh`. Every test runs the Zig `psi`, which the runner builds for the run with `zig build --prefix` into a directory of its own (`build_zig_cli`) and removes at the end, and checks each database it writes with `psi verify`. The sync and metadata tests read and change records directly with `psi debug record` and `psi debug edit`, and check merkle tree order with `psi debug merkle-check`.

Run it through the root `package.json`, from the repository root:

```
bun run test:cli:zig
bun run test:cli:zig -- <number|name>
```

## Arguments

- `<command|test-name>`: `all` (the default), a test number or name, `to <number>` for tests 1 to `<number>`, `setup` (build the executables and remove them again) or `help`. Several commands may be joined with commas and no spaces.
- `-t`, `--tmp-dir <dir>`: use `<dir>` for the suite's own files instead of a directory allocated for the run.
- `--sequential`: run the tests one at a time.
- `--parallel [N]`: run `N` tests at a time. The default comes from the core count, or from `PHOTOSPHERE_TEST_PARALLEL`.
- `--capture-baseline <target>`: record `<target>` as passed with `what-changed` when a full run passes. The `test:cli:zig` script passes it.

See [Testing](../../docs/testing/README.md) for how the suite fits with the others.
