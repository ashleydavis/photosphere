# Zig test coverage

How to measure the line coverage of the unit tests of the Zig packages (`packages-zig/*`) and of the Zig CLI
(`apps/cli-zig`), and where it stands.

## Measuring

Coverage is measured with [kcov](https://github.com/SimonKagstrom/kcov), which reads the DWARF debug info of a test
program and counts the lines it runs. kcov is not in the Ubuntu package archive of the development container, so it
is built from source (it needs the libcurl headers even when its code-coverage uploads are never used).

Every Zig `build.zig` takes a `-Dcoverage=<dir>` option. With it the unit test program is compiled with the LLVM
backend (the debug info of Zig's own backend is not something kcov can read) and run under kcov, which writes a report
of the package's own sources, not its tests or its dependencies, to `<dir>`:

```bash
cd packages-zig/bdb-zig
zig build test -Dcoverage=/tmp/coverage/bdb-zig
```

For `apps/cli-zig` pass `-Doptimize=Debug` as well, because the CLI builds in ReleaseSafe by default.

Each run leaves `cobertura.xml` in a subdirectory of `<dir>` per program kcov ran (`test`, and for node-utils-zig
`termination-test`), with `index.html` beside it for reading in a browser.

The storage package's integration tests run against a real S3 server. To include them, start the local MinIO server
with `bun run s3-emulator start <state-dir>`, source `<state-dir>/env`, and run both steps with the variables the
integration tests read:

```bash
AWS_ACCESS_KEY_ID=$S3_EMULATOR_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$S3_EMULATOR_SECRET_KEY \
AWS_ENDPOINT=http://127.0.0.1:$S3_EMULATOR_PORT AWS_REGION=us-east-1 TEST_S3_BUCKET=$S3_EMULATOR_BUCKET \
zig build test test-integration -Dcoverage=/tmp/coverage/storage-zig
```

and stop the server afterwards with `bun run s3-emulator stop <state-dir>`.

## What kcov cannot see

- **Programs the tests start.** kcov counts the lines of the program it runs. A separate program a test starts (the
  `psi` binary of `apps/cli-zig`, the termination child of node-utils-zig) is traced but not
  counted, so code reached only that way shows as uncovered. A kcov of their own does count them, in the second pass of
  a coverage build, once the first pass has finished (see `build.zig` of the CLI). On 2026-10-04 that second pass ran
  every MCP test of the CLI, with `psi mcp` under kcov, and finished without hanging; the hang the audit saw earlier was
  not reproduced and its cause was not found.
- **Two kcov runs at once into one directory.** The termination tests of node-utils-zig start a child under a kcov of its
  own, which writes to the coverage directory the kcov of the unit tests writes to. Run at the same time, the unit test
  program ended with a segmentation fault in `_dl_fini` after every test had passed. The termination tests now wait for
  the unit test step when a coverage report is built, and that run finishes cleanly.
- **Code for other platforms.** Windows- and macOS-only code is not compiled on Linux, so it is not in a Linux report
  at all; it is run by the unit tests on those platforms.
- **`unreachable` and `@panic` lines**, which a passing test never runs.

## Figures

Line coverage of the unit tests on Linux, as kcov reports it. "Before" is the start of the coverage audit, "after" is
its end. storage-zig includes its integration tests against MinIO.

| Package | Before | After | Measured 2026-10-04 |
| --- | --- | --- | --- |
| api-zig | 97.1% (439/452) | 100.0% (452/452) | 100.0% (452/452) |
| bdb-zig | 89.7% (2035/2269) | 96.3% (2169/2252) | 98.2% (2148/2188) |
| cli-zig | 85.6% (4751/5550) | not measured: the run hangs in the MCP tests (see above) | 85.7% (7999/9329), the unit tests with `psi` and the test driver run under kcov; the unit test program alone is 87.2% (4902/5620) |
| encryption-zig | 91.9% (558/607) | 94.9% (575/606) | 95.9% (582/607) |
| fuzzy-match-zig | 84.0% (42/50) | 100.0% (50/50) | 100.0% (50/50) |
| lan-share-core-zig | 100.0% (33/33) | 100.0% (33/33) | 100.0% (33/33) |
| lan-share-network-zig | 90.3% (552/611) | 94.3% (576/611) | 96.6% (603/624) |
| merkle-tree-zig | 97.7% (1205/1233) | 99.8% (1230/1232) | 99.8% (1230/1232) |
| node-api-zig | 89.1% (5435/6099) | 95.2% (5871/6168) | 95.2% (5875/6171) |
| node-utils-zig | 93.2% (1907/2047) | 96.6% (2156/2232) | 99.2% (2239/2258), the unit tests with the termination child run under kcov |
| serialization-zig | 96.4% (854/886) | 99.4% (903/908) | 99.5% (909/914) |
| storage-zig | 50.0% (883/1765) | 92.3% (1653/1791) | 97.4% (1831/1880), the unit tests with the integration tests |
| task-queue-zig | 92.5% (371/401) | 94.3% (380/403) | 94.3% (380/403) |
| tools-zig | 90.5% (334/369) | 97.2% (343/353) | 97.9% (416/425) |
| utils-zig | 93.1% (619/665) | 96.8% (816/843) | 96.1% (815/848), the unit test program alone |
| vault-zig | 91.1% (419/460) | 99.0% (493/498) | 98.0% (485/495), the unit test program alone |

The line counts move between the columns because the code changed during the audit. The uncovered lines of the last column are not yet each covered or explained.
