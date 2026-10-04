# Remove the Zig CLI test driver

## Overview

`apps/cli-zig/src/test/drivers/test-driver.zig` is a second executable, built only for the tests and installed to `zig-out/test-bin/test-driver`, that calls internal functions of the Zig CLI (`configureS3IfNeeded`, `pickDirectory`, `dbsSend`, and so on) directly, outside of `psi`. Tests that use it check functions in a harness that no user ever runs, with options (a 1 ms discovery timeout, a receiver held on a thread) that `psi` cannot be given, so a green result does not show `psi` works. The driver also doubles as a fake browser opener for the `psi bug` tests. This plan removes the driver completely and moves every test that used it onto the real `psi` binary (`helpers.psi_path`), driving prompts through stdin with the existing `helpers.runWithPrompts`. The one thing `psi` cannot do today, shorten the 60 second LAN share discovery wait, becomes a real user-facing `--timeout <seconds>` option on `dbs send`, `dbs receive`, `secrets send` and `secrets receive`, added to both the TypeScript and Zig CLIs so they stay alike.

## Issues

## Steps

1. Add `--timeout <seconds>` to the TypeScript CLI share commands.
    - `apps/cli/src/cmd/dbs.ts`: in the command registration (the `cmd.command('send')` and `cmd.command('receive')` blocks), add `.option('--timeout <seconds>', 'How long to wait for the other device, in seconds (default 60)')`. Add a `timeout?: string` field (with a `//` comment) to the send and receive options interfaces. In `dbsSend`, replace the literal `sender.waitForReceiver(60000)` with the parsed value times 1000, and change `'No device found within 60 seconds.'` to name the parsed seconds. Do the same in `dbsReceive` for `new LanShareReceiver(60000)` and `'No device connected within 60 seconds.'`.
    - `apps/cli/src/cmd/secrets.ts`: the same for `secretsSend` (`waitForReceiver(60000)`, `'No receiver found within 60 seconds.'`) and `secretsReceive` (`new LanShareReceiver(60000)`, `'No sender connected within 60 seconds.'`).
    - Add one exported function, `parseShareTimeoutSeconds(text: string | undefined): number`, in a shared place both commands already import from (read `apps/cli/src/lib/` to choose; do not create a new file if an existing lib module fits). Undefined gives 60. A value that is not a whole number of at least 1 throws an error whose message names `--timeout` and the value given; the command logs it with `log.error(pc.red('✗ ...'))` and exits 1, as the existing `--code is required with --yes` check does.
    - Unit test `parseShareTimeoutSeconds` and update `apps/cli/src/test/cmd/dbs.test.ts` and `apps/cli/src/test/cmd/secrets.test.ts` so the existing `waitForReceiver`/`LanShareReceiver` expectations cover the default (60000) and a passed `--timeout 5` (5000). Run `mise exec -- bun run compile` and `mise exec -- bun run test` and watch the new tests fail before the implementation and pass after.

2. Add the same `--timeout <seconds>` option to the Zig CLI.
    - `apps/cli-zig/index.zig`: add `.option("--timeout <seconds>", "How long to wait for the other device, in seconds (default 60)", null)` beside each `--code <code>` registration of the share commands (around the `secrets send`/`secrets receive` and `dbs send`/`dbs receive` command builders).
    - `apps/cli-zig/src/cmd/dbs.zig` and `apps/cli-zig/src/cmd/secrets.zig`: replace the `discoveryTimeoutMs: i64 = 60000` field on `IDbsSendOptions`, `IDbsReceiveOptions`, `ISecretsSendOptions` and `ISecretsReceiveOptions` with `timeout: ?[]const u8 = null` (the raw option text, as `--code` is held), and parse it at the top of `dbsSend`, `dbsReceive`, `secretsSend` and `secretsReceive` with a Zig twin of `parseShareTimeoutSeconds` that rejects the same inputs with the same message and exit code. Put the twin beside the other shared helpers both files already import; read them to choose. Each "within 60 seconds" message name the parsed seconds, byte for byte as the TypeScript CLI prints them.
    - Update the comments that described `discoveryTimeoutMs` as existing for the tests: the option now exists for users.
    - Add parse tests to `apps/cli-zig/src/test/index.test.zig` beside the existing `dbs send ... --code` and `secrets send ... --code` parse tests (around the `parse(allocator, &.{ "secrets", "send", ...` and `"dbs", "send", ...` cases) asserting `--timeout 5` reaches the options. Unit test the Zig parse helper for the default, a valid value, `0`, a negative, a fraction and non-numeric text. Run `mise exec -- bun run --filter=cli-zig test` (or `zig build test` through the package's `test` script) and watch each fail first.

3. Move the LAN share tests in `apps/cli-zig/src/test/cli-c-databases.test.zig` onto `psi`.
    - The timeout tests ("dbs receive says no device connected ...", "secrets receive says no sender connected ...", "dbs send says no device found ...", "secrets send says no receiver found ...") run `psi` through the file's existing `runZig` helper, for example `dbs receive --yes --code 1234 --timeout 1`, and expect the same stdout with "within 1 seconds" (or whatever wording step 1 settled on for one second) in place of "within 60 seconds".
    - The "tells a mistyped pairing code from an absent device" tests start a real receiving `psi` in the background (`psi dbs receive --yes --code <otherCode> --timeout <longer than the sender's>`, and the `secrets` equivalent), wait until its stdout shows it is waiting (reuse or extend the receiving-device helper near `commands.test.zig:3021`, moving it to `test-helpers.zig` if both files need it), then run the sender with `--timeout 4` and assert the same stdout as now. Kill the receiver child at the end of the test with `child.kill`, so a failed assertion still stops it.
    - Delete `expectScenario`, `share_discovery_timeout` and `mismatched_receiver_timeout` once unused. Keep `randomPairingCode`.
    - Run the file's tests; for each moved test, break the expected text once and watch it fail.

4. Move the init and encryption prompt tests in `apps/cli-zig/src/test/init-cmd.test.zig` onto `psi`.
    - Each test that calls `environment.drive(...)` instead runs `psi` with `helpers.runWithPrompts(allocator, &.{ helpers.psi_path, ... }, prompts, &self.environ_map)` on a command that reaches the same function, then asserts what `psi` left behind and printed. Every value the old test asserted on the returned result (key name, `generateKey`, PEM text, region, endpoint, list length) must still be asserted exactly, read from where `psi` stores or prints it (the vault through `environment.readSecret`, the databases config, stdout). If a value is not visible through `psi`, stop and ask the human; do not drop it. Read each call site before choosing; the ones found are:
        - `configureS3IfNeeded`: `psi init s3:<bucket>/<path>` with no AWS variables and no stored credentials (`src/lib/init-cmd.zig` around the `configureS3IfNeeded` call in the init path). Assert the vault entry `default:s3` holds the typed values (already checked through `environment.readSecret`). The command may then fail to reach S3; assert its exit code and output as they are, and do not point it at a real bucket.
        - `promptForEncryption` and `selectEncryptionKey`: `psi init <empty dir>` without `--key`, answering "Would you like to encrypt your database?". Declined: the database is created unencrypted. Accepted with an existing key: the database is encrypted with that key (check through the files `psi init` writes, or `psi summary --key <name>`).
        - `promptToAddKey` and `promptToGenerateOrAddKey`: through `resolveKeyPemsWithPrompt`. `canGenerate=true` is `psi init <empty dir> --key missing-key` (the `promptToGenerateOrAddKey` call in `init-cmd.zig`); `canGenerate=false` is a command on an existing encrypted database such as `psi summary --db <db> --key missing-key` (the `resolveKeyPemsWithPrompt(..., false)` call in the load path). Assert the vault contents (`environment.readSecret`) and the command's output and exit code for cancel, paste, import from file and generate.
    - Remove the `drive` method from the test environment struct.
    - Run the file's tests and watch each moved test fail once against a deliberately wrong assertion.

5. Move the directory picker tests in `apps/cli-zig/src/test/directory-picker.test.zig` and `apps/cli-zig/src/test/cli-b-setup.test.zig` onto `psi`.
    - `pickDirectory` is reached only through `getDirectoryForCommand` (`src/lib/directory-picker.zig`), which `psi init` calls with `.init` and every database command (for example `psi summary`) calls with `.existing` when no `--db` is given. Run `psi` with `--cwd <dir>` (or the child's working directory, whichever the commands honour; read `init-cmd.zig` around the `getDirectoryForCommand` calls) and no database argument, typing the same keys.
    - Replace each assertion on the returned path with what `psi` did with it: for `.init`, a database exists at the chosen path (check for the files `psi init` creates) and nothing was created elsewhere; for `.existing`, the command printed the summary of the chosen database. Cancel and failure cases assert the exit code and the message on stdout or stderr, which these tests already check through `failed.stdout`.
    - Keep the exact returned value where a test asserts it (for example `"./photos"` for a created subdirectory and `"."` for the current directory, as opposed to an absolute path): find where `psi` prints or records the path it was given back (read `init-cmd.zig` after the `getDirectoryForCommand` call, and the databases config `psi init` writes) and assert that text exactly. If `psi` does not expose the value anywhere, stop and ask the human before going further; do not drop the assertion.
    - The `pickDirectory` message argument (`"Pick:"`) is no longer chosen by the test: wait for the real message `psi` shows ("Select an empty directory for new media database:" for init, "Select an existing media database directory:" for existing commands).
    - In `cli-b-setup.test.zig`, delete `IDriverRun`, `driveScenario` and `pickedDirectory`. In `directory-picker.test.zig`, delete `drive`.
    - Run both files' tests and watch each moved test fail once first.

6. Move the progress-line tests in `apps/cli-zig/src/test/terminal-utils.test.zig` onto `psi`.
    - Replace `writeProgressOnTerminal` with a function that runs `psi` on the pseudo-terminal from `openPseudoTerminal`, on a command that calls `writeProgress` with a fixed message on a small database: `psi check <db> <empty dir>` (which writes "Searching for files..." in `src/cmd/check.zig`) or another from the `writeProgress` callers; read the command first to pick one whose terminal output is fixed. Pass `--verbose` for the verbose case.
    - Assertions: on a TTY the output contains the exact sequence the current test asserts, `"\x1b[2K\x1b[1GSearching for files...\x1b[2K\x1b[1G"` (write then clear, with the message `psi` uses in place of `"Copying files..."`), as a substring of the whole output; with `--verbose` it does not contain `"\x1b[2K"`; with stdout a pipe (`helpers.runCli`) it does not contain `"\x1b[2K"`. If the command writes another progress message between that write and its clear, pick a command or input where it does not, so the exact sequence is still asserted.
    - Run the file's tests and watch each fail once first.

7. Replace the fake browser opener in the `psi bug` tests (`apps/cli-zig/src/test/commands.test.zig`, `bugEnvironment` and `expectOpened`).
    - Outside Windows, `bugEnvironment` writes a shell script named `xdg-open` (or `open` on macOS) into the test's PATH directory, mode 0755, which writes `"$@"` one argument per line to `<its own path>.opened.txt.partial` and then `mv`s it to `<its own path>.opened.txt`, so a test waiting for it never reads half of it. The record path comes from the script's own location (`$0`), not an environment variable, so `PHOTOSPHERE_TEST_OPENER_RECORD` goes away. `expectOpened` takes the opener's path and reads the record from beside it on every platform. Keep the existing non-Windows wait for the record (the opener runs detached) and the existing exact comparison of the arguments.
    - On Windows, `psi bug` starts `%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe` by full path (`src/lib/third-party/open.zig`), so the opener has to be a real executable and a script cannot stand in for it. Add `apps/cli-zig/src/test/drivers/opener-recorder.zig`: a standalone program that imports only `std` (nothing from the CLI or its packages) and does exactly what the driver's `PHOTOSPHERE_TEST_OPENER_RECORD` branch does now, writing its arguments one per line to `<its own path>.opened.txt.partial` and renaming that to `<its own path>.opened.txt`. Its record path comes from its own location, not an environment variable. Build it in `build.zig` the way the driver is built now, installed to `zig-out/test-bin`, with no module imports, and include it in the kcov coverage wrapper pass only if the driver was. On Windows `bugEnvironment` copies it to the `powershell.exe` path under the test's `SystemRoot`, as it copies the driver today, and `expectOpened` reads the record from beside it.
    - Keep `expectOpened`'s Windows behaviour exactly as it is now (check the arguments whenever the record exists, with the existing TODO), so the Windows check is neither lost nor made stricter than it is today.
    - Run the bug tests and watch `expectOpened` fail once against a wrong expected URL.

8. Delete the driver and its build wiring.
    - Delete `apps/cli-zig/src/test/drivers/test-driver.zig`.
    - `apps/cli-zig/build.zig`: remove `test_driver_module`, `test_driver`, `install_test_driver` and its `dependOn`, and the `installCoverageWrapper(b, test_driver, ...)` line, leaving the `opener-recorder` build from step 7 in place. Update the comments around them (the "tests run a second time" comment and the `use_llvm` comment near line 49) so they name `psi` and, where it applies, the opener recorder.
    - `apps/cli-zig/src/test/test-helpers.zig`: remove `test_driver_path`, `IDriverResult`, `runTestDriver` and `parseDriverResult`; rename `printDriverOutput` to `printProgramOutput` and update its comment and the comments of `IPromptKeys` and `prompt_wait_limit_seconds` so they say `psi`.
    - Run `grep -rn "test-driver\|test_driver\|runTestDriver\|parseDriverResult\|IDriverResult\|PHOTOSPHERE_TEST_OPENER_RECORD" apps packages-zig scripts docs --exclude-dir=node_modules --exclude-dir=.zig-cache --exclude-dir=zig-out --exclude-dir=plans` and fix every remaining hit in this package (the user-interface `test-driver.ts` hits are a different thing and stay).
    - Run `mise exec -- bun run --filter=cli-zig compile` and the Zig tests.

9. Shorten the 60 second waits in the shell LAN share suites now that `--timeout` exists.
    - `apps/cli/smoke-tests-lan-share.sh` and `apps/cli/smoke-tests-lan-share-zig.sh`, `test_wrong_pairing_code`: pass `--timeout 5` to the sender so the test no longer waits a full minute for its own deadline. Leave every other invocation on the default.
    - Run `mise exec -- bun run test:cli:lan-share` and `mise exec -- bun run test:cli:lan-share:zig` (check the exact script names in the root `package.json`).

10. Write the documentation.
    - `../photosphere.wiki/Sharing-Credentials.md` and `../photosphere.wiki/Managing-Databases.md` (the separate wiki checkout): add `--timeout <seconds>` to the option lists of `secrets send/receive` and `dbs send/receive`, saying it defaults to 60 and what happens when it runs out.
    - `docs/testing/e2e/cli/lan-share/share-database.md` and `docs/testing/e2e/cli/lan-share/share-secret.md`: mention the option where they describe waiting for the other device.
    - `apps/cli/smoke-tests-lan-share-zig.md`: if it describes the wrong-code test's duration, update it.
    - `docs/zig-test-coverage.md`: the coverage note near the "psi binary and the test driver of apps/cli-zig" line now names only `psi`.

## Unit Tests

- `parseShareTimeoutSeconds` (TypeScript): undefined gives 60; "5" gives 5; "0", "-1", "1.5", "abc" and "" throw with a message naming `--timeout`.
- The Zig twin of `parseShareTimeoutSeconds`: the same cases, same messages.
- `apps/cli/src/test/cmd/dbs.test.ts` and `secrets.test.ts`: send and receive pass 60000 by default and 5000 with `--timeout 5`.
- `apps/cli-zig/src/test/index.test.zig`: `dbs send`, `dbs receive`, `secrets send` and `secrets receive` parse `--timeout`.
- Every test listed in steps 3 to 7, rewritten to run `psi`, each watched failing once before being accepted.

## Smoke Tests

- `apps/cli-zig/src/test/cli-c-databases.test.zig`: the timeout tests and the mistyped-code tests, all against `psi`.
- `apps/cli/smoke-tests-lan-share.sh` and `apps/cli/smoke-tests-lan-share-zig.sh`: `test_wrong_pairing_code` using `--timeout`, and every other test in both suites unchanged and passing.
- The `psi init` and database-command prompt tests of steps 4 and 5, which are end-to-end runs of `psi` with typed input.

## Verify

- `mise exec -- bun run compile` succeeds.
- `cd apps/cli-zig && mise exec -- bun run test` succeeds, and `zig-out/test-bin/test-driver` is no longer built (only the opener recorder is in `zig-out/test-bin`).
- Nothing was lost: before step 3, write the name of every `test "..."` block in the files touched by steps 3 to 7 and every `expect...` call in those tests to `tmp/test-driver-inventory-before.txt` (add `tmp/` to `.gitignore` if it is not there). After step 8, compare against the same files. Every test name is still present (renamed only where the wording named the driver or a function instead of `psi`), and every value each old test asserted is still asserted by its replacement, as exactly as before. Any assertion with no equivalent is a stop-and-ask, not a removal.
- The grep in step 8 finds nothing in `apps/cli-zig`, `apps/cli` or `packages-zig` outside `docs/plans`.
- `mise exec -- bun run tev` (no `--force`) passes.
- `psi dbs send --timeout 0` and `psi dbs send --timeout abc` exit 1 with the `--timeout` error in both CLIs; `psi dbs receive --yes --code 1234 --timeout 1` prints "No device connected within 1 ..." and exits 0 in both CLIs.

## Notes

- Decided with the human: the LAN share discovery wait becomes a real `--timeout <seconds>` option in both CLIs, rather than tests waiting the full 60 seconds or being moved into the shell suite.
- Requirement from the human: no coverage is lost. Every test and every asserted value that the driver-based tests had must survive the move to `psi`, on every platform those tests run on.
- Decided with the human: the `psi bug` opener becomes a shell script the test writes, on Linux and macOS. Windows cannot use a script because `psi` starts `powershell.exe` by full path, so there a minimal recorder program (`opener-recorder.zig`, importing only `std`) takes the driver's place as the opener. It calls nothing in the CLI, so it is not a test driver: it only stands in for the system program `psi` launches. A fake program on the PATH in place of the system opener is the usual way CLIs that launch a browser are tested. The other common approach is a `BROWSER` environment variable that the CLI honours (as `gh` and Python's `webbrowser` do); the TypeScript CLI opens URLs through the `open` package, which does not read it, so adopting it would mean changing both CLIs' behaviour and was not chosen.
- On Windows the `psi bug` opener arguments are checked exactly as now: whenever the record exists. The race behind that (the opener is killed when `psi` exits) is described by the existing TODO in `expectOpened` and is a separate fix, not part of this plan.
- The rewritten tests check observable effects of `psi` (files created, vault entries, output, exit code) in addition to, not instead of, each value the old test asserted. Where a returned value such as `pickDirectory`'s `"./photos"` is not visible through `psi`, the executing agent stops and asks rather than dropping it.
- Any test whose function cannot be reached from `psi` once read closely must not be deleted or faked: stop and ask the human, per the repository rules.
- `src/test/drivers/coverage-wrapper.zig` stays: it wraps `psi` for kcov and is not the test driver. With the driver gone it is the only file left in `src/test/drivers/`; leave the directory name as it is unless the human asks.
- Not related: `packages/user-interface/src/lib/test-driver.ts` and `test-driver-ws.ts` are the UI's test control bridge and are outside this plan.
