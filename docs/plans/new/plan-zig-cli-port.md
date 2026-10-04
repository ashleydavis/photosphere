# Plan: port every psi CLI command to Zig

Branch `zig-2`, worktree `.claude/worktrees/zig-mobile`. `replicate` and `verify` are already ported.

The end goal: every psi command runs in the Zig CLI (`apps/cli-zig`), and the whole TypeScript CLI smoke
suite has a Zig counterpart that passes.

## How each command is done

1. Read the TypeScript command (`apps/cli/src/cmd/<name>.ts`) and everything it calls.
2. Port only the code that command needs, into the matching `packages-zig/<package>-zig` or `apps/cli-zig`
   file. Code already ported is reused, not duplicated.
3. Register the command in `apps/cli-zig/index.zig` with the Zig commander, so it stops being delegated to
   TypeScript. Help text, errors and exit codes match the TypeScript CLI exactly.
4. Unit tests for every new or changed Zig function, porting the matching TypeScript tests by name.
5. Zig smoke tests in `apps/cli/smoke-tests-zig/` matching every TypeScript smoke test that exercises the
   command, with the Zig CLI running the command in place of TypeScript.
6. Every Zig smoke test ends with one check that runs the compiled TypeScript CLI (`psi verify` on the
   database the Zig CLI created or changed) and expects it to pass.
7. Local checks before the commit, all passing:
   - `cd apps/cli-zig && zig build test-all --test-timeout 20m`
   - `bun run build:zig` equivalent: `bun run --cwd apps/cli-zig build-all` (Linux x64, Linux arm64, Windows)
   - `bun run test:cli:zig`
8. One commit per completed command. Then push and watch the Release workflow until it is green in about
   30 minutes (macOS is only built and tested on CI).

## Recipe for doing one command quickly

One command at a time, never in parallel. The time goes on builds, so build less often and smaller:

1. Map first: list every TypeScript function the command reaches, grep `packages-zig` and `apps/cli-zig` for
   each, and write down only what is missing. Port nothing that already exists.
2. Port bottom-up, one file with its tests at a time, and run only that file's tests while working:
   `zig build test -Dtest-file=<file>.test.zig` in the package (add the option to a package's build.zig when
   it lacks it). Watch each new test fail once by breaking the code, then restore it.
3. Register the command, then run only the Zig smoke tests that use it (`bun run test:cli:zig -- <number>`).
4. Only at the end run the full local checks of step 7 once, then commit and push.
5. Start the next command while CI runs. Fix a CI failure as soon as it is reported, in its own commit.
6. Before pushing, run the changed packages' tests for Windows under wine
   (`zig build test -Dtarget=x86_64-windows -fwine`); macOS is only checked on CI.
7. Keep the build caches: never clear them and never delete single files out of them (a cache entry with a
   missing file breaks later builds). Check free disk before a full run.

## Rules

- The Zig code is a faithful port of the TypeScript: same file and function names, same order, readable side
  by side. No additions, no embellishments, no overreach. TypeScript quirks are reproduced. A TypeScript bug is
  reproduced too, with a `// TODO:` at each place in the Zig code saying it mirrors the TypeScript until both are
  fixed.
- Port the minimum code needed for the command being ported, nothing for later commands.
- Banned from changing TypeScript code and TypeScript tests.
- DO NOT USE BUN. No Zig code, Zig test or Zig build step runs bun or any TypeScript. The Zig CLI never hands a
  command to the TypeScript CLI: a command that is not ported yet is an unknown command. Expected values are
  written into the Zig tests, ported from the TypeScript tests.
- Data written to a database is byte-identical to what the TypeScript CLI writes.
- No hand-rolled replacements for third-party libraries. Use the real library (as with the AWS SDK for C,
  built by the Zig build system from unmodified upstream sources). No vendoring or patching. If a library
  cannot be used, find the standard way from its documentation and carry on.
- No fakes, mocks or stubs of real SDKs or servers unless the TypeScript tests do the same thing at the same
  seam (for example the S3 client's `send`). No fake tests: every new test is watched failing first.
- No optimising the Zig code. If tests run over 30 minutes, measure, find the cause and fix it (a harness or test mistake, or Zig code not matching the TypeScript), then carry on. Never raise timeouts, skip tests or parallelise to get under.
- No guessing: every choice comes from the TypeScript source, the library's own documentation or its build
  files. If something is undocumented, the TypeScript behaviour decides.
- Follow CLAUDE.md: code style, no em dashes, no `rm -r`, no python or other languages in the repository, no
  embedded languages in shell scripts, `bun run` scripts rather than invoking shell scripts directly.
- The Zig smoke tests follow the general structure of the TypeScript smoke tests exactly: the same suites, the
  same test files and numbering, the same shared helper libraries, the same functions and the same steps in the
  same order. The only differences are that the ported commands run in the Zig CLI and that each test ends with
  the TypeScript `psi verify` check. No new helper libraries, overrides or restructuring. Diverging is banned.
- Zig packages live in `packages-zig/`, the Zig CLI in `apps/cli-zig/`, the Zig smoke tests in
  `apps/cli/smoke-tests-zig/`. Original files (TypeScript, existing smoke tests, hooks) are not touched.
- CI must stay green on Linux, Windows and macOS, and the Release workflow should finish in about 30 minutes.
- Check the latest Release run after every push. When it fails, all focus goes on fixing it: no command work
  until the latest run is green again. Never let it stay red.
- Never give times in UTC. Say how long from now instead (for example "in 15 minutes").
- DO NOT NARRATE YOUR WORK. ONE PROGRESS UPDATE PER COMMAND IS ENOUGH. Messages to the user are short. No essays.
- RULE: IMPLEMENT EVERYTHING IN A SUBAGENT. All porting, testing, fixing, committing and pushing is done by subagents, one command at a time. The main channel is kept for exactly two kinds of message: "<command> committed and pushed", and "Release workflow passing" once the run for that push is green. Nothing else is said to the user.
- RULE: WATCH EVERY SUBAGENT. While a subagent works, keep a background watchdog running that wakes the main session when a new commit lands on zig-2, or when 20 minutes pass with no file changes in the worktree and no zig build or smoke test running. A stalled or crashed subagent is relaunched at once. The 30-minute check-in stays armed on top of the watchdog as a backstop.
- Every CLI command is ticked off in this plan as it is committed.
- RULE: every command port includes Zig smoke tests that run the command end to end; a port is not done without them.

## Commands

Done:

- [x] replicate
- [x] verify

To do, in order (each one uses what the earlier ones ported):

- [x] version
- [x] restructure `apps/cli/smoke-tests-zig/` to mirror the TypeScript smoke suites (no interop.sh, zig-functions.sh or
  encrypted-functions.sh overrides)
- [x] init
- [x] add (including `--watch`)
- [x] summary
- [x] list
- [x] info
- [x] root-hash
- [x] database-id
- [x] origin
- [x] set-origin
- [x] export
- [x] compare
- [x] remove
- [x] repair
- [x] find-orphans
- [x] remove-orphans
- [x] upgrade
- [x] sync
- [x] consolidate
- [x] encrypt
- [x] decrypt
- [x] hash
- [x] hash-cache (show, clear, hash-file, add, set, set-source, get, get-asset-id, remove, list, count, dir)
- [x] debug (merkle-tree, find-collisions, find-duplicates, remove-duplicates, build-sort-index, build-files-tree)
- [x] check
- [x] tools
- [x] examples
- [x] help
- [x] news
- [x] bug
- [x] dbs (all subcommands, including LAN share send and receive)
- [x] secrets (all subcommands, including LAN share send and receive)
- [x] mcp

## Smoke suites to match

Each TypeScript suite gets a Zig counterpart covering every test, ticked off as its commands are ported:

- [x] `apps/cli/smoke-tests.sh` (tests 01 to 89)
- [x] `apps/cli/smoke-tests-encrypted.sh`
- [x] `apps/cli/smoke-tests-lan-share.sh`
- [x] `apps/cli/sync-smoke-test.sh`
- [x] `apps/cli/write-lock-smoke-test.sh`
- [x] `apps/cli/hash-cache-smoke-test.sh`

## Final audit (starts automatically when the main work is complete)

The audit begins without being asked, once every command and every smoke suite above is ticked and the
Release workflow is green. Each point is ticked off as it is confirmed:

- [ ] All Zig code is completely covered by unit tests.
- [x] Every TypeScript smoke test is implemented for the Zig commands, with a similar structure, plus a
  TypeScript `psi verify` that checks the integrity of each database the Zig CLI creates.
- [ ] All Zig code is a faithful port of the TypeScript code and can be compared side by side with it, so that
  the Zig logic can be verified to be the same as the TypeScript logic.
- [x] The Zig smoke tests complete more quickly than the TypeScript smoke tests. If necessary, exclude the cost
  of the TypeScript verify calls from the comparison.
- [ ] The Zig smoke tests are shown, test by test, to match the TypeScript smoke tests, in a written comparison.
- [ ] The Zig CLI is shown not to be faked: it never calls, embeds or links the TypeScript CLI or a JavaScript runtime, holds no canned output, no test-only branches and no stub that reports success.
- [ ] The Zig CLI writes databases byte-identical to the TypeScript CLI for the same commands.
- [ ] Every Zig test is shown able to fail: breaking the Zig code it covers turns it red.

### What the audit has done so far

- Side by side comparison of every package and of `apps/cli`, with each divergence fixed under a unit test.
- Coverage pass recorded in `docs/zig-test-coverage.md`, then further coverage branches (`audit/audit-*`, `audit/cli-a` to `audit/cli-d`) merged in `90158286`.
- Smoke timings recorded in `docs/zig-smoke-timings.md`.

### Audit work remaining

Each item records its result for the final documentation item. A finding is fixed in the Zig code as a faithful port of the TypeScript, never hidden; one that needs a decision is reported to the human.

1. Run the Zig package unit tests locally: a root `test:zig` script running `zig build test-all --summary all --test-timeout 20m` in `apps/cli-zig`, a `test:zig` target in `what-changed.yaml` watching `apps/cli-zig` and `packages-zig`, and `test:zig` plus the five Zig smoke scripts missing from the `--force` list added to `SCRIPTS` in `scripts/test-everything-parallel.sh`.
2. Find and fix the cause of the kcov hang in the cli-zig MCP tests (`psi mcp` does not exit under ptrace), without excluding the MCP tests.
3. Re-measure kcov coverage of every `packages-zig` package (storage-zig with its MinIO integration tests) and of `apps/cli-zig`, reports under the project `tmp/`. The figures in `docs/zig-test-coverage.md` predate the coverage branches.
4. Cover every uncovered line with a unit test watched failing first, or record why it cannot be covered (other platform, `unreachable`, `@panic`).
5. Measure what the Zig smoke suites execute of the binary: a `PSI_ZIG_COVERAGE_DIR` option in `apps/cli/smoke-tests-zig/lib/common.sh` that runs the Debug LLVM binary under kcov, documented in an md beside it. Add the missing steps to Zig twins for handler code no smoke test reaches but a TypeScript smoke test does.
6. Write `apps/cli/smoke-tests-zig/comparison.md`, laid out like `apps/cli/smoke-tests/comparison.md`, diffing every TypeScript smoke test, helper library and top level suite with its Zig twin, classifying each difference as the CLI swapped, an added `ts_verify`, or substantive. Restore any TypeScript step or assertion a Zig twin dropped or weakened. List the Zig-only tests (`90` onward) and the command each covers.
7. Byte-for-byte differential test `apps/cli/smoke-tests-zig/103-byte-identical-database/test.sh`: the same command sequence (`init`, `add` of the PNG, JPG and MP4 fixtures, a duplicate `add`, `remove`, `set-origin`, `repair`, `debug build-sort-index`) run by the TypeScript CLI and by the Zig CLI into separate directories, each with its own `TEST_TMP_DIR` UUID counter, compared file by file with `cmp`, unencrypted and encrypted. First list every database field that can differ between runs; if one depends on wall clock time with no deterministic test value in both CLIs, stop and report it rather than excluding it. Watch the test fail with one byte of Zig output changed.
8. Not-faked audit:
    1. Every non-test Zig call that starts a process or loads code (`std.process.Child`, `spawn`, `node-utils-zig` `exec` and its callers, `std.DynLib`, `dlopen`, `LoadLibrary`) starts or loads only what the TypeScript CLI also uses. The worker pool (`apps/cli-zig/src/lib/worker-pool.zig`) starts the Zig `psi`, not `worker.ts` or the TypeScript binary. Every string literal containing `bun`, `node`, `.ts`, `.js`, `apps/cli/`, `worker.ts`, `index.js` or `bin/x64` is accounted for.
    2. No `@embedFile` of a `.ts`, `.js` or `.map` file or of the TypeScript binary, no JavaScript engine (QuickJS, JavaScriptCore, V8, Bun) in any `build.zig` or `build.zig.zon`, and no build step that runs bun or node or copies from `apps/cli/bin`.
    3. The binary links no JavaScript runtime: `ldd` on Linux, and `otool -L` on macOS and `objdump -p` on Windows read from the Release workflow logs after the human pushes.
    4. No canned output: no text in non-test Zig source copied from smoke test expectations or `apps/cli-zig/src/test/fixtures` that the TypeScript computes rather than holds as a literal.
    5. No test-only branches: every non-test Zig read of `NODE_ENV`, `TEST_TMP_DIR` or another variable the tests set (today `worker-pool.zig` and `init-cmd.zig` read `NODE_ENV`) matches the same read in the TypeScript.
    6. No stub that reports success: no non-test Zig function that returns without the work its TypeScript twin does (empty body, argument returned, empty result, swallowed error, `TODO` saying work is missing). The mirrored TypeScript bugs marked `// TODO:` are listed separately with the TypeScript line each mirrors.
    7. Every Zig smoke test runs the command it tests through `get_zig_cli_command`; `get_cli_command` appears only in `ts_verify` and in steps comparing TypeScript output with Zig output.
    8. One `strace -f -e trace=execve` run of each Zig smoke suite on Linux (by editing `get_zig_cli_command` with the Edit tool for the run and restoring it afterwards, trace under the project `tmp/`) lists no bun, node or TypeScript entry point started by the Zig binary. One-time audit, not a committed test.
    9. Smoke test `apps/cli/smoke-tests-zig/104-no-typescript-runtime/test.sh`: the Zig binary copied alone into a test directory, run with a `PATH` holding only the directories of `magick`, `ffmpeg` and `ffprobe` (the test fails if `bun` or `node` is reachable), runs `init`, `add`, `summary`, `list`, `export` and `verify` with asserted output and exit codes, then `ts_verify` with the normal `PATH`. It also asserts the binary is not a bun-compiled executable, the check chosen from bun's documentation of `bun build --compile` output. Watch it fail pointed at the TypeScript binary `apps/cli/bin/x64/linux/psi`. Runs on Windows and macOS too.
9. Mutation run: for each command in `apps/cli-zig/index.zig`, break one line of its Zig handler and of the `packages-zig` function doing its core read or write with the Edit tool, run that command's Zig smoke tests and the changed file's unit tests, require red, restore with the Edit tool (never `git restore` or `git checkout`). Strengthen any test that stayed green and repeat the break.
10. Fake test review of the Zig unit tests: list any `test "` block with no assertion or one that cannot fail, and fix each, watched failing first. List every `error.SkipZigTest` with its platform condition.
11. Side by side review of the third party ports (commander, picocolors, open, readline, string-width, wrap-ansi, sisteransi, the MCP SDK) against the npm package versions in `node_modules` the TypeScript CLI uses, with each divergence fixed under a unit test that fails before the fix.
12. Re-compare the touched functions of every `apps/cli-zig` and `packages-zig` source change since `0172d27a` with their TypeScript originals.
13. Documentation: update `docs/zig-test-coverage.md` (MCP hang fixed, binary coverage under the smoke suites, new dated figures, uncovered lines with reasons); add `docs/zig-port-verification.md` covering how the Zig psi is shown to be real and faithful (the results of item 8 and the mutation run as dated events, `ts_verify` after every write, the byte-for-byte test, the no-TypeScript-runtime test, smoke coverage of the binary); link it from `docs/testing/README.md`, and add `test:zig` to `CLAUDE.md`'s command list. Do not reference this plan from any of them.

### Audit verification

- `bun run compile`, `zig build` for every `build-all` target, `bun run test:zig`, `bun run test`, all six Zig smoke suites and `bun run tev` pass; `bun run tev -- --plan` lists `test:zig`; `bun run test:parallel` reports no failure in company for the new tests.
- kcov runs finish without hanging, and every uncovered line is gone or listed with its reason.
- `103-byte-identical-database` and `104-no-typescript-runtime` were each watched red then green.
- Every mutation turned at least one test red.
- Every not-faked check has a recorded result with nothing left in the code.
- Windows and macOS results are unverified until the human pushes and a Release run passes.

## Never stop

- Work does not stop, ask questions or wait for approval until every command and every smoke suite above
  is 100% complete and CI is green. Stopping means failure.
- Every decision is made from the TypeScript reference and library documentation, then work continues.
- A `send_later` check-in every 30 minutes, always re-armed before a turn ends, keeps work going until every
  item is 100% complete.
- An hourly `send_later` check-in keeps work going if the session dies. Each check-in resumes the next
  unticked item immediately.
- The Zig smoke-test job is capped at 30 minutes in the Release workflow, with step timeouts, so an overrun
  fails fast.
