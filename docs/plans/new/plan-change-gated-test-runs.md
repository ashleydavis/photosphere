# Change-gated test runs

## Overview

`bun run test:everything` runs the whole platform test set on every invocation, including when nothing has changed since the last time it passed. That is about three and a half minutes on every commit, even for a docs-only change, and it is the main reason the pre-commit hook gets bypassed. This plan adds a small, reusable TypeScript package (`packages/change-gate`) that hashes the working tree, keeps the hashes in a `.cache/` directory, and only asks the existing parallel runner for the test scripts whose watched paths have actually changed since that script last passed. A `--force` flag runs everything regardless. The gate is driven entirely by a JSON config file, so the package itself contains nothing specific to Photosphere and can be dropped into another project by writing a new config.

Two hard constraints shape the design. First, `scripts/test-everything-parallel.sh`, `.githooks/pre-commit` and `scripts/install-hooks.sh` are frozen by `CLAUDE.md` and must not be edited, so the gate wraps the parallel runner from outside and passes it explicit script names. Second, the parallel runner already handles serial grouping of the mobile suites for whatever subset of names it is given, so passing a subset is already supported behaviour and needs no change there.

The design borrows its shape from the hashing code in the separate `claude-tools-runner` project: a per-file hash cache keyed by modification time and size so unchanged files are never re-read, and a gate that compares a stored hash against a freshly computed one to decide whether work should run at all.

## Issues

## Steps

Each step must leave the repository compiling (`mise exec -- bun run compile`) and the unit tests passing (`mise exec -- bun run test`) before it is considered complete. Every new function gets a unit test in the same step that introduces it. Run all commands through `mise exec --`.

### 1. Scaffold the `change-gate` package

- Create `packages/change-gate/package.json`: name `change-gate`, version `1.0.0`, `"main": "src/index.ts"`, `"type": "module"`, no runtime dependencies (the package must stay dependency-free so it is portable), and the same script block as `packages/node-utils/package.json` (`test`, `test:watch`, `test:coverage`, `compile`, `compile:watch`, `clean`, plus the `t`/`tw`/`c`/`cw` aliases). Use `jest` for `test` (not `--passWithNoTests`, this package will always have tests). Dev dependencies: `@types/jest`, `@types/node`, `jest`, `ts-jest`, `typescript`, matching the versions in `packages/node-utils/package.json`.
- Create `packages/change-gate/tsconfig.json` by copying `packages/node-utils/tsconfig.json` verbatim.
- Create `packages/change-gate/jest.config.js` by copying `packages/node-utils/jest.config.js` verbatim.
- Create `packages/change-gate/src/index.ts` re-exporting the modules added in later steps (start empty, add exports as each module lands).
- Add `.cache/` to the repository `.gitignore`. This is required before anything else works: the file list comes from git and includes untracked files, so an un-ignored cache directory would make every run see itself as a change.
- Run `mise exec -- bun install` from the repo root so the new workspace is registered.

### 2. `src/lib/file-hash.ts`: per-file content hashing with an mtime/size cache

- Export `const MISSING_FILE_HASH: string` with the literal value `"<missing>"`, used in place of a digest when a file disappears between listing and hashing.
- Export `interface FileHashEntry` with fields `mtimeMs` (number), `size` (number) and `hash` (string, SHA-256 hex of the file content).
- Export `interface FileHashCache` with a string index signature mapping a repository-relative path to a `FileHashEntry`. Paths are relative so the cache stays valid if the checkout moves.
- Export `async function hashFile(rootDir: string, relativePath: string, cache: FileHashCache): Promise<string>`. Stats the file; on `ENOENT` returns `MISSING_FILE_HASH` and leaves the cache untouched; on a cache entry whose `mtimeMs` and `size` both match, returns the cached hash without reading the file; otherwise reads the file, computes the SHA-256 hex digest, writes the entry back into `cache` and returns it. All other stat and read errors propagate.
- Export `async function hashFiles(rootDir: string, relativePaths: string[], cache: FileHashCache): Promise<Map<string, string>>`. Calls `hashFile` for each path in order and returns a map of relative path to hash. Sequential on purpose: the steady-state cost is one `stat` per file, and sequential code has no file-descriptor ceiling to reason about.
- Unit tests as listed in the Unit Tests section.

### 3. `src/lib/list-files.ts`: enumerate the files that matter

- Export `async function listRepoFiles(rootDir: string): Promise<string[]>`. Spawns `git ls-files -z --cached --others --exclude-standard` in `rootDir` using `node:child_process`, splits the output on NUL, drops empty entries, de-duplicates, and returns the paths sorted. Rejects with a clear error naming the exit code and stderr if git fails.
- Using git for enumeration is deliberate: it gives exact `.gitignore` semantics for free, includes new untracked files, and avoids hand-writing an ignore matcher. It means the gate requires the project to be a git repository, which is stated in the package README.
- Unit tests as listed in the Unit Tests section.

### 4. `src/lib/merkle.ts`: directory hash tree

- Export `const MISSING_PATH_HASH: string` with the literal value `"<missing>"`, returned when a looked-up path is not in the tree.
- Export `interface TreeNode` with fields `hash` (string, the node's SHA-256 hex digest) and `children` (a `Map<string, TreeNode>`, empty for a file node).
- Export `function buildTree(fileHashes: Map<string, string>): TreeNode`. Splits each relative path on `/`, builds the nested node structure, and computes each directory's hash bottom-up as the SHA-256 over its entries sorted by name, each contributing `name`, a NUL byte, the child hash, and a newline. A file node's hash is its content hash. The result is order-independent.
- Export `function hashForPath(root: TreeNode, relativePath: string): string`. Walks the path segments and returns that node's hash, whether it names a file or a directory. Returns `MISSING_PATH_HASH` when any segment is absent. An empty string returns the root hash.
- The tree is what makes per-target gating cheap and readable: one lookup answers "has anything under `packages/mobile-frontend` changed", and the changed paths can be named back to the user.
- Unit tests as listed in the Unit Tests section.

### 5. `src/lib/cache-store.ts`: read and write the `.cache` directory

- Export `interface PathHashes` with a string index signature mapping a watched relative path to its hash at the time a target last passed.
- Export `interface TargetHashes` with a string index signature mapping a target name to a `PathHashes`.
- Export `interface GateCache` with fields `fileHashes` (`FileHashCache`) and `targetHashes` (`TargetHashes`).
- Export `async function loadCache(cacheDir: string): Promise<GateCache>`. Reads `file-hashes.json` and `target-hashes.json` from `cacheDir`. A missing directory, a missing file, or unparseable/wrong-shaped JSON yields empty objects rather than an error, so a damaged cache costs a slow run and never blocks one.
- Export `async function saveFileHashes(cacheDir: string, fileHashes: FileHashCache): Promise<void>` and `async function saveTargetHashes(cacheDir: string, targetHashes: TargetHashes): Promise<void>`. Both create `cacheDir` recursively, write to a `.tmp` sibling and rename over the target so a crash mid-write cannot leave a half-written file.
- Export `function pruneFileHashes(fileHashes: FileHashCache, currentPaths: string[]): FileHashCache`. Returns a new cache holding only entries whose path is in `currentPaths`, so deleted files do not accumulate forever.
- Unit tests as listed in the Unit Tests section.

### 6. `src/lib/config.ts`: the project-specific part, as data

- Export `interface TargetConfig` with fields `name` (string, the script name handed to the runner), `paths` (string array, repository-relative files or directories whose content decides whether this target runs) and `platforms` (string array of `process.platform` values; empty means every platform).
- Export `interface GateConfig` with fields `cacheDir` (string, relative to the config file's directory), `runnerCommand` (string array, the command and fixed arguments that the target names are appended to), `alwaysPaths` (string array, watched by every target) and `targets` (`TargetConfig[]`).
- Export `function parseGateConfig(rawJson: string): GateConfig`. Parses and validates: `runnerCommand` must be a non-empty array of non-empty strings; `targets` must be a non-empty array; every target name must be a non-empty string and unique; every `paths` entry must be a non-empty array of relative paths (reject anything absolute or containing a `..` segment); `platforms` defaults to an empty array; `cacheDir` defaults to `.cache/change-gate`; `alwaysPaths` defaults to an empty array. Every rejection throws an `Error` naming the offending field and value.
- Export `async function loadGateConfig(configPath: string): Promise<GateConfig>`. Reads the file and delegates to `parseGateConfig`, throwing an error naming the path when the file cannot be read.
- Unit tests as listed in the Unit Tests section.

### 7. `src/lib/plan.ts`: decide what runs

- Export `type PlanReason = "forced" | "never-passed" | "changed" | "unchanged" | "wrong-platform"`.
- Export `interface TargetPlan` with fields `name` (string), `pathHashes` (`PathHashes`, the freshly computed hash of every path this target watches), `shouldRun` (boolean), `reason` (`PlanReason`) and `changedPaths` (string array, the watched paths whose hash differs from the recorded one; empty unless `reason` is `"changed"`).
- Export `function watchedPathsFor(config: GateConfig, target: TargetConfig): string[]`. Returns `target.paths` merged with `config.alwaysPaths`, de-duplicated and sorted.
- Export `function planTargets(config: GateConfig, tree: TreeNode, previous: TargetHashes, platform: string, requestedNames: string[], force: boolean): TargetPlan[]`. When `requestedNames` is non-empty, only those targets are considered. For each considered target: compute `pathHashes` by looking up every watched path in the tree; if `platforms` is non-empty and does not include `platform`, return `shouldRun: false` with reason `"wrong-platform"`; else if `force`, return `shouldRun: true` with reason `"forced"`; else if there is no recorded entry for the target, return `shouldRun: true` with reason `"never-passed"`; else compare each watched path against the recorded hash, and return `shouldRun: true` with reason `"changed"` and the differing paths when any differ, otherwise `shouldRun: false` with reason `"unchanged"`.
- The function is pure, which is what makes the whole gating rule testable without touching a disk or a clock.
- Unit tests as listed in the Unit Tests section.

### 8. `src/lib/cli-args.ts`: argument parsing, separated so it is testable

- Export `interface CliOptions` with fields `configPath` (string, defaulting to `change-gate.json`), `force` (boolean), `planOnly` (boolean) and `targetNames` (string array, empty means every target in the config).
- Export `function parseCliArgs(argv: string[]): CliOptions`. Accepts `--force`, `--plan` (report the decision and exit without running anything), `--config <path>`, `--help`, and positional target names. Throws an `Error` on an unknown flag or a `--config` with no value.
- Export `function helpText(): string` returning the usage text, so the CLI entry point holds no prose.
- Unit tests as listed in the Unit Tests section.

### 9. `src/lib/run-command.ts`: run the underlying runner

- Export `async function runCommand(command: string[], cwd: string): Promise<number>`. Spawns `command[0]` with the remaining elements as arguments, `cwd` as the working directory and `stdio: "inherit"` so the runner's own output reaches the terminal unchanged. Resolves with the exit code, or `128 + signal` when the child is killed by a signal, so a Ctrl-C is never mistaken for success.
- Unit tests as listed in the Unit Tests section.

### 10. `src/cli.ts`: the entry point

- Export `async function runGate(argv: string[]): Promise<number>` holding the whole flow, so the entry point itself is two lines and the flow could be exercised from a test harness later if wanted.
- Flow: parse the arguments; resolve `configPath` against the current working directory and take its directory as the root; load the config; error out naming the offending name if any requested target name is not in the config; load the cache from `cacheDir` resolved against the root; list the files; hash them; prune and save the file hashes immediately (the file hash cache is an optimisation and is saved whatever the test outcome); build the tree; plan.
- Print one line per considered target: whether it will run, and why, naming the changed paths when the reason is `"changed"`. This is the output that tells the user why their commit is or is not running the Android suite.
- If `--plan` was given, return 0 without running anything.
- If nothing is to run, print a line saying so and return 0.
- Otherwise run `[...config.runnerCommand, ...namesToRun]` from the root directory. On exit code 0, merge the plan-time `pathHashes` of the targets that ran into `targetHashes`, save it, and return 0. On any non-zero code, save nothing and return that code.
- Record the hashes computed at plan time, not recomputed after the run. Those are the hashes of the tree that was actually tested, so an edit made while the tests were running correctly shows as a change on the next run instead of being silently marked as tested.
- Record all-or-nothing on the runner's overall exit code. The parallel runner kills the remaining lanes on the first failure, so there is no reliable per-script result to record; recording nothing on failure is the conservative choice and is stated in the README.
- At the bottom of the file, call `runGate(process.argv.slice(2))` and `process.exit` with the result. Nothing else may import `cli.ts`.
- Add the module exports to `src/index.ts`.

### 11. `packages/change-gate/smoke-tests.sh` and the `test:gate` script

- Create `packages/change-gate/smoke-tests.sh` (executable, `set -e`, colour output following the style of `apps/cli/hash-cache-smoke-test.sh`) covering the scenarios in the Smoke Tests section. It builds a throwaway git repository under `packages/change-gate/tmp/` (already covered by the `tmp/` entry in `.gitignore`), writes a config whose `runnerCommand` points at a fake runner script that appends its arguments to a log and exits with a code read from a file, and drives the CLI with `bun packages/change-gate/src/cli.ts`. The runner clears its own `tmp/` directory at the start.
- Add `"test:gate": "cd ./packages/change-gate && ./smoke-tests.sh"` to the root `package.json` scripts.
- This smoke test is fast (a second or two) because the runner it drives is a stub, so it can be a target in the gate's own config without slowing anything down.

### 12. `change-gate.json` and the `package.json` wiring

- Create `change-gate.json` at the repository root with `cacheDir` of `.cache/change-gate`, `runnerCommand` of `["./scripts/test-everything-parallel.sh"]`, and `alwaysPaths` of `package.json`, `bun.lock`, `mise.toml`, `change-gate.json`, `scripts` and `.githooks` (anything that changes how every suite runs).
- Targets, chosen so that the current default set is reproduced exactly and nothing that used to run can silently stop running:
  - `compile`: paths `packages`, `apps`.
  - `test`: paths `packages`, `apps`.
  - `test:cli`: paths `apps/cli`, `packages`.
  - `test:electron`: paths `apps/desktop`, `apps/desktop-frontend`, `packages`.
  - `test:and` and `test:and:unit`: paths `apps/android-frontend`, `apps/smoke-tests`, `packages`; platforms `["linux"]`.
  - `test:ios` and `test:ios:unit`: paths `apps/ios-frontend`, `apps/smoke-tests`, `packages`; platforms `["darwin"]`.
  - `test:gate`: paths `packages/change-gate`.
- The umbrella `packages` entry is deliberate and conservative. Narrowing a target to the specific packages it depends on is a config edit with no code change, but a wrong narrowing silently skips a suite that should have run, so the first version does not guess. What this already buys is real: a change confined to `docs/`, `apps/cli/`, `apps/desktop/` or `.claude/` no longer runs the mobile suites, and a docs-only or plan-only change runs nothing at all.
- Change the root `package.json` `test:everything` script to `bun packages/change-gate/src/cli.ts`.
- Add `"test:everything:all": "./scripts/test-everything-parallel.sh"` as the ungated escape hatch, so the frozen runner still has a `bun run` entry point (invoking it directly is against the repository rules).
- Verify `bun run test:everything -- --force` and `bun run tev -- --force` both reach the CLI as `--force`, and fix the wiring if they do not.

### 13. Documentation

- Update `docs/git-hooks.md`: the "What it runs" section gains the fact that the set is now filtered by changed paths and that `--force` overrides it; the "Why the mobile suites are always included" section is rewritten to describe the path rules in `change-gate.json`, why a suite can be skipped, and why a failing run records nothing.
- Update the `test:everything` and `tev` entries in the root `CLAUDE.md` Commands section to say that runs are gated on changed paths and that `--force` runs everything.
- Add `packages/change-gate/README.md` covering: what the package does, the config file format with a worked example, the `.cache` layout, the git requirement, the all-or-nothing recording rule, and how to reuse the package in another project.

## Unit Tests

All tests live under `packages/change-gate/src/test/`, use `test(` rather than `it(`, and create any temporary directories with `fs.mkdtemp` under `os.tmpdir()`, removing them afterwards. No mocks: the git and filesystem behaviour is exercised for real against throwaway directories.

`file-hash.test.ts`
- `hashFile` returns the SHA-256 of the file content on a cold cache and populates the cache entry with the file's mtime and size.
- `hashFile` returns the cached hash without reading the file when mtime and size match (proved by writing a deliberately wrong hash into the cache entry and asserting it comes back).
- `hashFile` re-reads and overwrites the entry when the size differs from the cached entry.
- `hashFile` re-reads and overwrites the entry when the mtime differs but the size does not.
- `hashFile` returns `MISSING_FILE_HASH` and leaves the cache untouched for a path that does not exist.
- `hashFiles` returns a map covering every requested path and shares one cache across the calls.

`list-files.test.ts`
- `listRepoFiles` returns tracked files from a temporary git repository.
- `listRepoFiles` includes an untracked file that is not ignored.
- `listRepoFiles` excludes a file matched by `.gitignore`.
- `listRepoFiles` returns paths sorted and free of duplicates.
- `listRepoFiles` rejects with an error mentioning git when run in a directory that is not a git repository.

`merkle.test.ts`
- `buildTree` produces the same root hash for the same file set regardless of insertion order.
- `buildTree` produces a different root hash when one file's content hash changes.
- `buildTree` produces a different root hash when a file is added, and again when one is removed.
- `buildTree` nests directories correctly for multi-segment paths.
- `hashForPath` returns a file's own hash for a file path.
- `hashForPath` returns the directory hash for a directory path, and that hash changes when a file below it changes but not when an unrelated file changes.
- `hashForPath` returns `MISSING_PATH_HASH` for an absent path.
- `hashForPath` returns the root hash for an empty path.

`cache-store.test.ts`
- `loadCache` returns empty structures for a directory that does not exist.
- `loadCache` returns empty structures when either JSON file is corrupt.
- `saveFileHashes` then `loadCache` round-trips the file hashes, creating the directory when absent.
- `saveTargetHashes` then `loadCache` round-trips the target hashes.
- `saveTargetHashes` leaves no `.tmp` file behind.
- `pruneFileHashes` keeps entries whose path is still present and drops the rest, without mutating the input.

`config.test.ts`
- `parseGateConfig` accepts a full valid config and returns every field.
- `parseGateConfig` applies the defaults for `cacheDir`, `alwaysPaths` and a target's `platforms`.
- `parseGateConfig` throws when `runnerCommand` is missing or empty.
- `parseGateConfig` throws when `targets` is missing or empty.
- `parseGateConfig` throws on a duplicate target name.
- `parseGateConfig` throws on a target with an empty `paths` array.
- `parseGateConfig` throws on an absolute path and on a path containing `..`.
- `parseGateConfig` throws on malformed JSON with a message naming the problem.
- `loadGateConfig` reads and parses a config file from disk.
- `loadGateConfig` throws an error naming the path when the file does not exist.

`plan.test.ts`
- `watchedPathsFor` merges the target paths with `alwaysPaths`, de-duplicates and sorts.
- `planTargets` returns `shouldRun` with reason `never-passed` when there is no recorded entry.
- `planTargets` returns `shouldRun: false` with reason `unchanged` when every watched path matches the recorded hash.
- `planTargets` returns `shouldRun` with reason `changed` and names only the paths that differ.
- `planTargets` treats a watched path missing from the recorded entry as changed.
- `planTargets` returns reason `forced` for every target when `force` is true, including ones that are unchanged.
- `planTargets` returns `shouldRun: false` with reason `wrong-platform` for a target whose `platforms` excludes the given platform, even when its paths changed, and even when `force` is true.
- `planTargets` considers only the named targets when `requestedNames` is non-empty.
- `planTargets` marks every target as changed when a path in `alwaysPaths` changed.
- `planTargets` still computes `pathHashes` on the skip paths so the caller never has to recompute.

`cli-args.test.ts`
- `parseCliArgs` returns the defaults for an empty argument list.
- `parseCliArgs` sets `force` for `--force` and `planOnly` for `--plan`.
- `parseCliArgs` reads the value of `--config`.
- `parseCliArgs` collects positional target names, in order and alongside flags.
- `parseCliArgs` throws on an unknown flag, naming it.
- `parseCliArgs` throws when `--config` has no value.
- `helpText` mentions `--force`, `--plan` and `--config`.

`run-command.test.ts`
- `runCommand` resolves 0 for a command that succeeds.
- `runCommand` resolves the child's non-zero exit code.
- `runCommand` rejects with a clear error when the command does not exist.

## Smoke Tests

`packages/change-gate/smoke-tests.sh`, run by `bun run test:gate`. Each case asserts on the fake runner's argument log, so the assertions are about which targets were actually asked for.

1. First run against a fresh repository: both targets run, the runner is called once with both names, and `.cache/change-gate/file-hashes.json` and `target-hashes.json` are created.
2. Immediate second run with nothing changed: the runner is not invoked at all and the exit code is 0.
3. `touch` a watched file without changing its content: the runner is still not invoked, proving the gate is content-based and not mtime-based.
4. Edit a file under target A's paths only: the runner is invoked with target A's name and not target B's.
5. Add a new untracked file under target B's paths: target B runs, proving untracked files count.
6. Delete a file under target B's paths: target B runs, proving deletions count.
7. Add a file that `.gitignore` matches: nothing runs, proving ignored files are excluded.
8. Change a file listed in `alwaysPaths`: every target runs.
9. Fake runner exits 1: the CLI exits 1, and the immediately following run asks for the same targets again, proving a failure records nothing.
10. `--force` with nothing changed: every eligible target runs.
11. `--plan` with something changed: the plan is printed, the runner is never invoked, and the recorded hashes are unchanged so the next real run still runs the target.
12. A named target argument restricts the run to that target, and an unknown name fails with a non-zero exit and an error naming it.
13. A target whose `platforms` excludes the host never runs, even with `--force`.
14. A corrupt `target-hashes.json` causes a full run rather than an error.

## Verify

Run every command through `mise exec --` from the repository root.

- `mise exec -- bun install` completes and registers the new workspace.
- `mise exec -- bun run compile` succeeds with no TypeScript errors.
- `mise exec -- bun run test` passes, including the new `change-gate` unit tests.
- `mise exec -- bun run test:gate` passes.
- `mise exec -- bun run test:everything compile test` runs both scripts the first time (its output names them), and a second immediate invocation of the same command reports both as unchanged, invokes no test script, and exits 0.
- Touch nothing, edit one line in a file under `packages/user-interface/src/`, and run `mise exec -- bun run test:everything compile test --plan`: the output must name `compile` and `test` as changed, and name the changed watched path.
- `mise exec -- bun run test:everything compile --force` runs `compile` even though it is unchanged.
- Edit only a file under `docs/` and run `mise exec -- bun run test:everything --plan`: no target is reported as needing a run.
- `git status --porcelain` shows no entry for `.cache`, confirming the ignore rule.
- The three frozen files (`.githooks/pre-commit`, `scripts/install-hooks.sh`, `scripts/test-everything-parallel.sh`) are unmodified: `git diff --stat` must not list them.

## Notes

- The parallel runner, the pre-commit hook and the hook installer are frozen by `CLAUDE.md` and are not touched. The gate sits in front of the runner and hands it explicit script names, which the runner already supports (`build_lanes` groups whatever subset it is given, so the mobile serial-group rule keeps working).
- Because the gate always passes explicit names, `change-gate.json` becomes the source of truth for which scripts the default run covers, replacing the runner's own `uname`-based default list. Step 12 reproduces that list exactly. A target left out of the config would silently stop running, which is why the config lists the platform split explicitly and why the docs step calls this out.
- Recording happens only on the runner's overall success. The runner kills the remaining lanes on the first failure, so there is no trustworthy per-script result to record, and a target that passed inside a failing run will run again next time. This wastes some time and cannot produce a wrong answer, which is the right way round.
- The plan-time hashes are what get recorded, not a post-run recomputation. Recording after the run would mark an edit made during the run as tested.
- The existing `packages/merkle-tree` package is not reused: it is the storage-backed tree for the asset database, with a different shape and different dependencies. The new tree is about forty lines and stays inside `change-gate` so the package remains dependency-free and portable.
- File enumeration goes through `git ls-files`, which gives exact `.gitignore` behaviour and includes untracked files. The trade is that the gate requires a git repository. Writing an ignore matcher instead would be more code and would drift from what git actually ignores.
- Hashing runs sequentially. After the first run it is one `stat` per file, so parallelism would buy little and would add a concurrency limit to reason about. The first run reads every tracked file once and is expected to take a few seconds.
- `excludePaths` per target (for example, excluding the mobile packages from the CLI suite's watched set) is deliberately not implemented. It is a small addition later if the umbrella `packages` entry proves too coarse, but a wrong exclusion silently skips a suite, so it should be added only with a concrete case behind it.
- The gate cannot see changes outside the working tree. If a suite passed and then the environment changed (a different emulator, a new SDK, a changed environment variable), the gate will still skip it. That is what `--force` is for, and it is stated in the README and in `docs/git-hooks.md`.
- Open question for the user, not blocking: whether the pre-commit hook should be gated at all, or only interactive `bun run tev` runs. This plan gates both, since the hook calls `bun run test:everything`, and the hook cannot be edited to opt out. If gating the hook is unwanted, the alternative is to leave `test:everything` pointing at the parallel runner and put the gate behind a new script name, at the cost of the hook staying slow.
