# Zig test coverage

How to measure the line coverage of the unit tests of the Zig packages (`packages-zig/*`) and of the Zig CLI
(`apps/cli-zig`), and where it stands.

## Measuring

Coverage is measured with [kcov](https://github.com/SimonKagstrom/kcov), which reads the DWARF debug info of a test
program and counts the lines it runs. kcov is not in the Ubuntu package archive of the development container, so it
is built from source (it needs the libcurl headers even when its code-coverage uploads are never used).

The `build.zig` at the root of the repository takes a `-Dcoverage=<dir>` option on the `test` step. With it the unit test
program of the packages is compiled with the LLVM backend (the debug info of Zig's own backend is not something kcov can read)
and run under kcov, which writes a report of the packages' own sources, not their tests or their dependencies, to `<dir>`:

```bash
zig build test -Dcoverage=/tmp/coverage/packages
```

`-Dtest-file=<package>/<file>.test.zig` limits the run to one test file. Coverage of the CLI (`apps/cli-zig`) is not measured by
the root build yet.

Each run leaves `cobertura.xml` in a subdirectory of `<dir>` per program kcov ran (`unit-tests`), with `index.html` beside it for reading in a browser.

The storage package's integration tests run against a real S3 server. To include them, start the local MinIO server
with `bun run s3-emulator start <state-dir>`, source `<state-dir>/env`, and run both steps with the variables the
integration tests read:

```bash
AWS_ACCESS_KEY_ID=$S3_EMULATOR_ACCESS_KEY AWS_SECRET_ACCESS_KEY=$S3_EMULATOR_SECRET_KEY \
AWS_ENDPOINT=http://127.0.0.1:$S3_EMULATOR_PORT AWS_REGION=us-east-1 TEST_S3_BUCKET=$S3_EMULATOR_BUCKET \
zig build test test-integration -Dcoverage=/tmp/coverage/packages
```

and stop the server afterwards with `bun run s3-emulator stop <state-dir>`.

## What kcov cannot see

- **Programs the tests start.** kcov counts the lines of the program it runs. A separate program a test starts (the
  `psi` binary and the test driver of `apps/cli-zig`, the termination child of node-utils-zig) is traced but not
  counted, so code reached only that way shows as uncovered. Running those programs under a kcov of their own does not
  work either: they are children of a traced process, and `psi mcp` did not exit when traced in the runs made for the audit (its
  threads were left waiting; the cause under ptrace was not pinned down), so a run can hang in the MCP tests.
- **Code for other platforms.** Windows- and macOS-only code is not compiled on Linux, so it is not in a Linux report
  at all; it is run by the unit tests on those platforms.
- **`unreachable` and `@panic` lines**, which a passing test never runs.

## Figures

Line coverage of the unit tests on Linux, as kcov reports it. "Before" is the start of the coverage audit, "after" is
its end. storage-zig includes its integration tests against MinIO.

| Package | Before | After |
| --- | --- | --- |
| api-zig | 97.1% (439/452) | 100.0% (452/452) |
| bdb-zig | 89.7% (2035/2269) | 96.3% (2169/2252) |
| cli-zig | 85.6% (4751/5550) | not measured: the run hangs in the MCP tests (see above) |
| encryption-zig | 91.9% (558/607) | 94.9% (575/606) |
| fuzzy-match-zig | 84.0% (42/50) | 100.0% (50/50) |
| lan-share-core-zig | 100.0% (33/33) | 100.0% (33/33) |
| lan-share-network-zig | 90.3% (552/611) | 94.3% (576/611) |
| merkle-tree-zig | 97.7% (1205/1233) | 99.8% (1230/1232) |
| node-api-zig | 89.1% (5435/6099) | 95.2% (5871/6168) |
| node-utils-zig | 93.2% (1907/2047) | 96.6% (2156/2232) |
| serialization-zig | 96.4% (854/886) | 99.4% (903/908) |
| storage-zig | 50.0% (883/1765) | 92.3% (1653/1791) |
| task-queue-zig | 92.5% (371/401) | 94.3% (380/403) |
| tools-zig | 90.5% (334/369) | 97.2% (343/353) |
| utils-zig | 93.1% (619/665) | 96.8% (816/843) |
| vault-zig | 91.1% (419/460) | 99.0% (493/498) |

The line counts move between the two columns because the code changed during the audit.
