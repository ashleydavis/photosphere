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
  by side. No additions, no embellishments, no overreach. TypeScript quirks are reproduced.
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
