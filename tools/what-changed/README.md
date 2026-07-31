# what-changed

Runs a project's test scripts only when the paths they watch have actually changed.

It sits in front of whatever runner the project already has. It hashes the working tree, compares each script's watched paths against the hashes recorded the last time that script passed, and hands the runner the names of only the scripts that need to run. A run where nothing relevant changed asks the runner for nothing at all.

The package has no runtime dependencies and nothing specific to any project in it. Everything project-specific lives in a JSON config file, so dropping it into another repository means writing a new config.

For the internals (what runs when, what state is kept, why each rule is the way round it is) see [docs/HOW_IT_WORKS.md](docs/HOW_IT_WORKS.md). **Read [docs/testing-gaps.md](docs/testing-gaps.md) before trusting the test results**: the end-to-end flow is deliberately untested, because covering it would need a test that creates a git repository. For what it costs, see [docs/performance.md](docs/performance.md): a warm check of a 2189-file repository is about 0.11s.

## Getting started

1. Copy the `what-changed` directory into your project. It has no runtime dependencies.
2. Add its cache directory to `.gitignore`:
   ```
   .cache/
   ```
3. Write a `what-changed.json` at the repository root. Point `runnerCommand` at the test runner you already have, and add one target per script that runner can be asked for:
   ```json
   {
       "runnerCommand": ["./run-tests.sh"],
       "alwaysPaths": ["package.json", "package-lock.json"],
       "ignoreExtensions": [".md", ".txt", ".log"],
       "targets": [
           { "name": "lint", "paths": ["src"] },
           { "name": "unit", "paths": ["src", "test"] },
           { "name": "e2e", "paths": ["src", "e2e"] }
       ]
   }
   ```
4. Point your project's "run the tests" script at the CLI, and keep the ungated runner reachable under its own name for when you need it:
   ```json
   "scripts": {
       "check": "bun what-changed/src/cli.ts",
       "check:all": "./run-tests.sh"
   }
   ```
5. Run it. The first run has nothing recorded, so everything runs. The second runs nothing.

The only requirement it imposes is that the project is a git repository and that `git` is on `PATH`.

## Seeing why something did or did not run

**When a target does not run and you expected it to, use `--plan`.** It prints one line per target with the reason, and names the watched paths that changed:

```
What changed:
  RUN   lint  (changed): src
  RUN   unit  (changed): src
  SKIP  e2e  (unchanged)
  SKIP  release  (wrong-platform)
```

The five reasons: `changed` (a watched path differs from the recorded hash), `never-passed` (no record yet, including after the cache is deleted), `unchanged`, `forced`, and `wrong-platform` (the target's `platforms` excludes this machine, which beats `--force`).

**To see the individual files rather than the decision, use `--files`.** It compares the working tree against the snapshot taken at the last passing run:

```
Changed since the last passing run:
  M  a5e4d212f14f3cc1  docs/development.md
  A  0f15384d18789b1e  src/parser/new.ts
  D  3b1f90ac77e21d04  src/parser/old.ts

2 changed, 2196 file(s) checked.
```

`M` is modified, `A` added, `D` deleted. A deleted file shows the hash it used to have. Neither `--plan` nor `--files` records anything, so inspecting is always free.

## Updating the baseline by hand

A passing run records the baseline automatically. `--baseline` does the same thing without running anything, for when you already know the tree is good:

```
Recorded the current tree as the baseline for 2 target(s): lint, unit.
```

It records exactly what a passing run would have recorded, through the same function, so the two cannot drift apart. It records the targets that *would* have run, so a target that was already up to date is left alone.

This is an assertion, not a check. Nothing is tested. Use it when you have verified the tree some other way, or to accept a change you know is irrelevant to the tests.

If the decision still looks wrong, `rm -rf .cache/what-changed` forces the next run to be a full one.

## Running it directly

```
bun what-changed/src/cli.ts [options] [target names]
```

| Option | What it does |
| --- | --- |
| `--force` | Run every eligible target even if nothing changed. |
| `--plan` | Print what would run and exit without running anything. |
| `--files` | List the files that changed since the last passing run, with their hashes, and exit without running anything. |
| `--baseline` | Record the current tree as the baseline, as if the tests had just passed, without running anything. `--plan` wins if both are given. |
| `--config <path>` | The config file to read. Defaults to `what-changed.json` in the working directory. |
| `--help` | Print the usage text. |

Positional arguments name the targets to consider. With none, every target in the config is considered. An unknown name is an error naming the offending target, not a silent skip.

The config file's directory is the project root: every watched path, and the cache directory, is resolved against it, and the file list is enumerated from there. Put the config at the repository root unless you deliberately want only a subtree watched.

A bare `--` is ignored wherever it appears, because a package runner such as `bun run` or `npm run` only strips one that comes before the first positional argument.

### Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Nothing needed to run, or `--plan` was given, or the runner ran and exited 0 |
| the runner's own code | The runner ran and failed. Passed through unchanged. |
| 128 + signal | The runner was killed by a signal, so a Ctrl-C is never read as success |
| 1 | The tool itself failed: bad config, unknown target, unknown option, git missing or failing |

## The config file

```json
{
    "cacheDir": ".cache/what-changed",
    "runnerCommand": ["./run-tests.sh"],
    "alwaysPaths": ["package.json", "package-lock.json"],
    "ignoreExtensions": [".md", ".txt", ".log"],
    "targets": [
        { "name": "lint", "paths": ["src"] },
        { "name": "unit", "paths": ["src", "test"] },
        { "name": "e2e", "paths": ["src", "e2e"], "platforms": ["linux", "darwin"] }
    ]
}
```

| Field | Meaning |
| --- | --- |
| `cacheDir` | Where the recorded hashes are kept, relative to the config file. Defaults to `.cache/what-changed`. Must be gitignored. |
| `runnerCommand` | The command and its fixed arguments. The names of the targets that need to run are appended to it, and it is run from the project root with its output going straight to the terminal. |
| `alwaysPaths` | Paths watched by every target, for things that change how every suite runs. Defaults to empty. |
| `ignoreExtensions` | File extensions left out of the file list entirely, each with its leading dot, matched case-insensitively. A file of an ignored type can never make any target run and never appears in `--files`. Defaults to empty. |
| `targets` | One entry per script the gate can ask for. |
| `targets[].name` | The script name handed to the runner. Must be unique. |
| `targets[].paths` | Project-relative files or directories whose content decides whether this target runs. Must be non-empty. Absolute paths and `..` segments are rejected. |
| `targets[].platforms` | The `process.platform` values this target can run on. Empty (the default) means every platform. |

`ignoreExtensions` is applied before anything is hashed, so an ignored file is invisible to the hash tree, to every target's decision, and to the changed-file listing alike. The leading dot is required rather than added for you: `ts` could mean an extension or a directory, and guessing wrong would quietly stop a suite from running. Changing this list changes the hash of every directory that held such a file, so the run after an edit to it re-verifies everything.

A malformed config is an error naming the offending field and its value. It never falls back to a default, because a config that quietly half-applies means a suite that quietly stops running.

## The cache

`cacheDir` holds three files, each written through a temporary sibling and a rename so a crash mid-write cannot leave a half-written file:

- `file-hashes.json`: one entry per file, holding its modification time, size and content hash. Purely an optimisation, so it is saved on every run whatever the tests do. A file whose mtime and size both match its entry is never read again, which is what keeps the steady-state cost to one `stat` per file.
- `target-hashes.json`: what each target's watched paths hashed to the last time that target passed.
- `passed-file-hashes.json`: every file's content hash as of the last run that passed. This is the baseline `--files` compares against, and it is separate from `file-hashes.json` because that one is refreshed on every run, including runs that failed.

All three are read defensively. A missing directory, a missing file, or JSON that will not parse or is the wrong shape all produce empty structures rather than an error, so a damaged cache costs a slow run and never blocks one.

Deleting `cacheDir` makes the next run a full one.

## What decides whether a target runs

The file list comes from `git ls-files --cached --others --exclude-standard`, so it is tracked files plus untracked files no ignore rule matches. That gives exact `.gitignore` semantics for free and picks up new untracked files, at the cost of requiring the project to be a git repository. **The cache directory must be gitignored**: the gate enumerates untracked files, so an un-ignored cache would make every run see its own last run as a change.

Those files are hashed and built into a directory hash tree, so a single lookup answers "has anything under this directory changed", and the answer can be named back to the user.

A target runs when:

- `--force` was given, or
- it has never passed, or
- any of its watched paths (its own `paths` plus `alwaysPaths`) hashes differently from the recorded value. A watched path that does not exist hashes to a stable `<missing>` marker, so creating the first file under it counts as a change.

A target never runs when its `platforms` list is non-empty and does not include the host platform. That beats `--force`: a suite whose toolchain is not on this machine cannot be made to run by asking harder.

## Two rules worth knowing

**Recording is all-or-nothing on the runner's overall exit code.** A runner that stops at the first failure has no trustworthy per-script result to report, so nothing is recorded unless the whole run passes. A target that passed inside a failing run will run again next time. That wastes some time and cannot produce a wrong answer, which is the right way round.

**The recorded hashes are the ones computed before the run, not a fresh read afterwards.** They describe the tree that was actually tested. Reading them again after the run would mark an edit made while the tests were running as tested.

**It cannot see anything outside the working tree.** If a suite passed and then the environment changed (a different emulator, a new SDK, a changed environment variable), it will still be skipped. Installed dependencies are invisible too, since `node_modules` is gitignored and never hashed; the lockfile is watched instead, as the tracked proxy for the installed tree. There is also no expiry: a suite that passed a month ago against an identical tree still counts as passed. `--force` is the answer to all of these.

**A branch switch or a pull is handled correctly**, because the whole tree is hashed rather than a diff against a commit. Checking out a branch changes the tree hash, so every affected target runs again. A tool that only looked at `git status` would see a clean tree after the switch and skip everything.

## Tests

Every function has a direct unit test. There are no mocks anywhere: the tests run against real temporary directories, real temporary git repositories, and real child processes.

```bash
npm test          # or: bun run test
npm run test:coverage
npm run perf      # benchmarks, fails if a stage blows its budget
./smoke-tests.sh
```

`test:coverage` reports 100% of statements, functions and lines. Two branches are uncovered, both unreachable rather than untested:

- the `code === null` fallback in `runCommand`, which Node only reaches for a child that closes with neither an exit code nor a signal. Covering it would mean faking `child_process`, a worse trade than one defensive branch.
- the equal case of the sort comparator in `diffFileHashes`. Paths come from a `Map`'s keys and an object's keys, and the added/modified and deleted sets are disjoint by construction, so two entries can never share a path.

`smoke-tests.sh` drives the real CLI end to end. It builds a throwaway git repository, points the tool at a fake runner that logs the script names it was asked for, and asserts on that log across nineteen scenarios: first run, unchanged run, a touched-but-unedited file, an edit under one target, an added untracked file, a deletion, an ignored file, an `alwaysPaths` change, a failing runner, `--force`, `--plan`, named targets, an unknown target name, a wrong-platform target, a corrupt cache, a missing git binary, a missing config file, a malformed config file, `--help`, and an unknown option.

Two cases live in the smoke suite rather than the unit tests because they cannot be tested honestly under jest. Jest gives each test file a sandboxed copy of `process.env`, so a `PATH` written inside a test never reaches a spawned child. A unit test for "git is not installed" would therefore pass while git ran normally, which is worse than no test. The shell script changes `PATH` for real.

Both suites are worth running as a CI job. Keep that job off the critical path of whatever the project releases: this tool only decides what gets run locally and ships in no artifact, so a failure in it is worth seeing but should never hold up a release.
