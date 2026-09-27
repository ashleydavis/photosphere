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

## Rules

- The Zig code is a faithful port of the TypeScript: same file and function names, same order, readable side
  by side. No additions, no embellishments, no overreach. TypeScript quirks are reproduced.
- Port the minimum code needed for the command being ported, nothing for later commands.
- Never change TypeScript code.
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
- Zig packages live in `packages-zig/`, the Zig CLI in `apps/cli-zig/`, the Zig smoke tests in
  `apps/cli/smoke-tests-zig/`. Original files (TypeScript, existing smoke tests, hooks) are not touched.
- CI must stay green on Linux, Windows and macOS, and the Release workflow should finish in about 30 minutes.
- Messages to the user are short. No essays. No narrating: one progress message per command committed, nothing else.
- Every CLI command is ticked off in this plan as it is committed.

## Commands

Done:

- [x] replicate
- [x] verify

To do, in order (each one uses what the earlier ones ported):

- [x] version
- [ ] init
- [ ] add (including `--watch`)
- [ ] summary
- [ ] list
- [ ] info
- [ ] root-hash
- [ ] database-id
- [ ] origin
- [ ] set-origin
- [ ] export
- [ ] compare
- [ ] remove
- [ ] repair
- [ ] find-orphans
- [ ] remove-orphans
- [ ] upgrade
- [ ] sync
- [ ] consolidate
- [ ] encrypt
- [ ] decrypt
- [ ] hash
- [ ] hash-cache (show, clear, hash-file, add, set, set-source, get, get-asset-id, remove, list, count, dir)
- [ ] debug (merkle-tree, find-collisions, find-duplicates, remove-duplicates, build-sort-index, build-files-tree)
- [ ] check
- [ ] tools
- [ ] examples
- [ ] help
- [ ] news
- [ ] bug
- [ ] dbs (all subcommands, including LAN share send and receive)
- [ ] secrets (all subcommands, including LAN share send and receive)
- [ ] mcp

## Smoke suites to match

Each TypeScript suite gets a Zig counterpart covering every test, ticked off as its commands are ported:

- [ ] `apps/cli/smoke-tests.sh` (tests 01 to 89)
- [ ] `apps/cli/smoke-tests-encrypted.sh`
- [ ] `apps/cli/smoke-tests-lan-share.sh`
- [ ] `apps/cli/sync-smoke-test.sh`
- [ ] `apps/cli/write-lock-smoke-test.sh`
- [ ] `apps/cli/hash-cache-smoke-test.sh`

## Never stop

- Work does not stop, ask questions or wait for approval until every command and every smoke suite above
  is 100% complete and CI is green. Stopping means failure.
- Every decision is made from the TypeScript reference and library documentation, then work continues.
- An hourly `send_later` check-in keeps work going if the session dies. Each check-in resumes the next
  unticked item immediately.
- The Zig smoke-test job is capped at 30 minutes in the Release workflow, with step timeouts, so an overrun
  fails fast.
