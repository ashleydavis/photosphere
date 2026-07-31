# Testing gaps

This project has real, known holes in its test coverage. They exist for one reason, and it is not laziness: **no test here is allowed to create or modify a git repository**, and the parts that are untested cannot be exercised without one.

This document exists so nobody reads the passing test run as meaning more than it does.

## Why the rule exists

An earlier version of `smoke-tests.sh` built a throwaway repository inside `tools/what-changed/tmp/repo` and ran `git init`, `git add -A` and `git commit` in it. Those commands landed on the real repository instead of the throwaway one. The result was the real repository's branch pointer moved to a commit whose entire tree was the test's fixture, and its index was overwritten with `git add -A` of the fixture. No files were lost, but the branch and the staged work had to be recovered by hand from the reflog.

Two unit test files did the same thing in temporary directories, and the reflog shows their commits landed in the real repository too.

The lesson is not "add a guard". A test that is capable of rewriting the repository it runs inside is not worth whatever it was covering, because the failure mode is unbounded and silent until someone looks at `git log`. So the rule is absolute: no test creates, stages, commits, or otherwise mutates any repository. Read-only git (`git ls-files`, `git status`, `git rev-parse`) is fine, and is what the tool itself uses.

## What that costs

The tool enumerates files with `git ls-files`. `runGate` calls `listRepoFiles` directly, so **any test of the whole flow needs a git repository to point at**. Without one, `runGate` fails at the enumeration step before it can reach anything worth asserting on.

Current coverage:

| File | Statements | Functions | Branches |
| --- | --- | --- | --- |
| `cache-store.ts` | 97.2% | 85.7% | 100% |
| `changed-files.ts` | 100% | 100% | 93.3% |
| `cli-args.ts` | 100% | 100% | 100% |
| `config.ts` | 100% | 100% | 100% |
| `file-hash.ts` | 100% | 100% | 100% |
| **`gate.ts`** | **60.2%** | **60%** | **58.8%** |
| `list-files.ts` | 100% | 100% | 100% |
| `merkle.ts` | 100% | 100% | 100% |
| `plan.ts` | 100% | 100% | 100% |
| `run-command.ts` | 100% | 100% | 80% |
| **All files** | **90.6%** | **91.1%** | **93.4%** |

Every gap of consequence is in `gate.ts`, lines 35 to 97 and 107 to 112.

## What is not tested

None of the following has any automated coverage. All of it was covered before the rule, by tests that built a repository.

**The recording rules.** These are the two decisions the whole tool rests on, and both are now unverified:

- A run whose runner exits non-zero must record nothing, so the same targets run again next time.
- The hashes recorded on success must be the ones computed *before* the run, not a fresh read afterwards. Recording a post-run read would mark an edit made while the tests were running as already tested.

**The end-to-end flow.** First run against a fresh cache runs everything. An immediate second run runs nothing. A touched-but-unedited file runs nothing. An edit under one target's paths runs only that target. An added untracked file, a deleted file, and a change to an `alwaysPaths` entry each behave correctly. A gitignored file is invisible. A corrupt cache causes a full run rather than an error.

**The flags, past argument parsing.** `--force` overriding an unchanged tree. `--plan` printing the decision and writing nothing. `--files` listing changed files against the recorded baseline, including the added, modified and deleted cases. `--baseline` recording without running, and recording the same thing a passing run would.

**`recordPassingRun`.** No test at all. It is the function both the success path and `--baseline` call.

**`ignoreExtensions` end to end.** The pure filter (`isIgnoredFile`, `filterIgnoredFiles`) is fully tested. Nothing verifies that an ignored file actually fails to trigger a target, or that it stays out of the recorded baseline.

**Platform filtering in context.** `planTargets` is tested directly, but nothing checks that `runGate` refuses to run a wrong-platform target even under `--force`.

## What is tested

So the passing run is not mistaken for more than it is, here is what genuinely holds:

- Every pure function, exhaustively: content hashing and its mtime/size cache, the merkle tree and its framing, every branch of the plan decision, every config validation rule, the cache store's read and write paths, the changed-file diff, and argument parsing.
- `listRepoFiles`, `runGitLsFiles` and `parseGitFileList`, read-only against this package's own directory and against directories that are not repositories.
- CLI process behaviour in `smoke-tests.sh`: exit codes and messages for `--help`, an unknown option, `--config` with no value, a missing config, a malformed config, an invalid config field, an unknown target name, and running outside a git repository.

## How to close the gaps

One change closes all of them.

`runGate` calls `listRepoFiles(rootDir)` directly, which is the only reason the flow needs a real repository. If the file lister were passed in as an argument instead, with `src/cli.ts` supplying the real one, every test above could be written against a supplied file list and a throwaway directory, with no repository anywhere.

Concretely:

- Define an interface for the lister, taking a root directory and returning the relative paths.
- Add it as a parameter of `runGate`, alongside `cwd` and `platform`, which are already passed in for exactly this reason.
- `src/cli.ts` passes `listRepoFiles`. Nothing else changes: the production path is identical.
- Tests pass a function returning a fixed list, write the corresponding files into a temp directory so hashing is real, and drive the whole flow.

This restores every test listed above, and would take the suite back to roughly 100% of statements, functions and lines.

**It has not been done, because it needs a decision that is not mine to make.** The repository's `CLAUDE.md` requires human approval before adding an injection point to production code for the benefit of tests. The counter-argument is that this is not really test scaffolding: `cwd` and `platform` are already parameters for the same reason, and removing the git dependency from `gate.ts` is better design on its own terms. But it is still a change to shipped code motivated by testing, so it waits for an explicit decision.

## What not to do instead

- **Do not add a guard and put the repository-building tests back.** The guard is the thing that failed to exist last time, and a guard that is one bug away from wiping a branch is not a safe foundation for a test suite.
- **Do not point the tests at the real repository.** Running the flow against the checkout would write a config into the working tree and overwrite the developer's cache. Read-only enumeration of the real repository, as `list-files.test.ts` does, is fine. Anything that writes is not.
- **Do not fake `listRepoFiles` by mocking the module.** That tests the mock, and the repository's rules ban making a test pass by faking the thing under test.
- **Do not delete this document when the coverage numbers look good again.** Replace it with the reason they look good.
