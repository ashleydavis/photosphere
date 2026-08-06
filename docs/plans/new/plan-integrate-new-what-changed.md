# Integrate the published what-changed into Photosphere and delete the old one

## Overview

what-changed is now its own published project at https://github.com/ashleydavis/what-changed, released as a single-file executable per platform. It is no longer the same kind of tool as `tools/what-changed`: the old one was a gate that decided which test scripts to run and then spawned a runner to run them, and the new one only reports. It answers what changed since a recorded baseline and which targets those changes fall under, and stops. This plan replaces Photosphere's copy with the published executable, moves the "decide, then run, then record" logic into a Photosphere-owned script, and deletes `tools/what-changed`.

The consequence that shapes everything: nothing in the new tool spawns `scripts/test-everything-parallel.sh`. Photosphere must own that step. The frozen files (`scripts/test-everything-parallel.sh`, `.githooks/pre-commit`, `scripts/install-hooks.sh`) must not be edited, and none of them needs to be: `pre-commit` already calls `bun run test:everything`, and `package.json` is free to change.

## Issues

- [ ] **Platform filtering is missing from the published tool and must be added there first.** `ITargetConfig.platforms` is parsed and validated in `src/lib/config.ts`, but nothing reads it: `categorizeChanges` in `src/lib/categorize.ts` ignores it entirely. Photosphere depends on it, because `test:and` and `test:and:unit` are linux-only and `test:ios` and `test:ios:unit` are darwin-only. Without it, a Linux machine is told `test:ios` is affected and the runner is asked for a script whose toolchain is not installed. Step 1 covers the fix, in the what-changed repository, followed by a new release. The rest of this plan is blocked until that release exists.

- [ ] **Decide how the executable reaches a developer machine and CI.** The plan assumes a `scripts/install-what-changed.sh` that downloads the release asset for the host platform into a gitignored `tools/bin/`, pinned to a version. The alternatives are requiring every developer to install it on their PATH by hand, or committing the binary (roughly 90MB, so not that). This is the human's call and it changes steps 3 and 4.

## Steps

1. **Add platform filtering to the what-changed project** (in the what-changed repository, not Photosphere). In `src/lib/categorize.ts`, add a `platform: string` parameter to `categorizeChanges` and skip any target whose `platforms` array is non-empty and does not include that platform. Give `ITargetChanges` an `applies: boolean` so a filtered-out target can be shown as "not on this platform" rather than silently vanishing. Thread `platform` through `report` in `src/lib/run.ts` alongside the existing `cwd` and `listFiles` arguments, supplied by `process.platform` from each command in `src/cmd/`. `reportCategorizedChanges` prints those targets as wrong-platform; `reportTargetNames` and `structuredReport` omit them. Compiles, unit tests pass, smoke tests pass, then cut a release so a versioned executable exists.

2. **Convert `what-changed.json` to `what-changed.yaml`** at the Photosphere repo root. YAML is the format the published tool leads with; JSON also still works, so this step is optional and could instead be a small edit of the existing JSON. Keep every target name exactly as it is (`compile`, `test`, `test:cli`, `test:electron`, `test:and`, `test:and:unit`, `test:ios`, `test:ios:unit`), because those names are passed straight to the frozen `scripts/test-everything-parallel.sh` as script names. Rename `alwaysPaths` to `always` and `ignoreExtensions` to `ignore`, which is what the published tool now calls them. Drop `runnerCommand`, which no longer exists. Drop the `test:what-changed` target. Keep `platforms` on the four mobile targets. Delete `what-changed.json` once the new file works.

3. **Write `scripts/install-what-changed.sh`.** It downloads the release asset matching the host platform and architecture from https://github.com/ashleydavis/what-changed/releases into `tools/bin/what-changed`, `chmod +x` it, and verifies it by running `what-changed version` and checking the output names the expected version. Pin the version in a single variable at the top of the script so upgrading is a one-line edit. Skip the download when the binary is already present and already reports the pinned version. It must fail loudly on an unrecognised platform rather than downloading the wrong asset.

4. **Add `tools/bin/` to the root `.gitignore`**, along with `.what-changed/`. The tool keeps both its baseline and its cache under `.what-changed/` now, so that one line covers both. Without it, the tool lists its own baseline as an untracked file and reports it as a change to itself on every run.

5. **Write `scripts/test-everything.sh`**, a new Photosphere-owned script modelled on `scripts/test-everything.sh` in the what-changed repository. It must: accept `--force` and `--plan` and pass any other arguments through as explicit target names; run `scripts/install-what-changed.sh` first so the binary is present; ask `tools/bin/what-changed targets` for the affected targets; exit 0 with a "nothing to run" message when that list is empty; otherwise invoke `bash ./scripts/test-everything-parallel.sh "${TARGETS[@]}"`; and only after that exits 0, run `tools/bin/what-changed baseline capture`. With `--force`, skip the query and pass no names to the parallel runner so it picks its own platform-appropriate default set. With `--plan`, print the target list and run nothing.

6. **Rewire the root `package.json` scripts.** `test:everything` becomes `bash ./scripts/test-everything.sh`. `everything:plan` becomes `bash ./scripts/test-everything.sh --plan`. `what-changed` becomes the tool's `changes` subcommand. `what-changed:baseline` becomes `baseline capture`. Add `what-changed:targets` for the raw list and `what-changed:reset` for `baseline reset`. Delete `test:what-changed`. Leave `test:everything:all` and `tev` alone.

7. **Delete `tools/what-changed/`.** Check whether `tools/` still holds anything other than the new `bin/`; if the workspace glob `"tools/*"` in the root `package.json` now matches nothing that is a package, remove it and run `bun install` so the lockfile drops the workspace.

8. **Update `docs/git-hooks.md`.** Remove the `test:what-changed` row from the target table and the paragraph beginning "There is also `bun run test:what-changed`". Rewrite the section describing the gate around the new split: what-changed reports, `scripts/test-everything.sh` decides what to do about it, `scripts/test-everything-parallel.sh` runs it. Replace the cache paragraph: the state now lives in `.what-changed/`, holding `baseline.json` and `cache/`, and clearing each one costs something different. Point the closing links at https://github.com/ashleydavis/what-changed rather than `tools/what-changed`.

9. **Update `CLAUDE.md`.** The `test:everything` bullet must describe the new arrangement and stop listing "the what-changed smoke tests" as part of the set. Change the `what-changed` and `what-changed:baseline` bullets to the new subcommands, add one for `what-changed:targets`, and delete the `test:what-changed` bullet.

10. **Update `docs/development.md`.** Remove the `tools/ - what-changed` tree entry at line ~42 and update the `test:everything` and `test:everything:all` rows in the command table.

11. **Check `scripts/find-flakey-tests.sh` still works.** It drives `bun run test:everything -- --force` in a loop, and the new script must accept `--force` with the same meaning. Update the two comments around lines 14 and 120 that describe `--force` as defeating "the what-changed gate". Do not change the command itself.

## Unit Tests

Step 1 is the only code change and it is in the what-changed repository, so its unit tests live there, in `src/test/`. Photosphere's own changes are shell and config, covered by the smoke tests below.

- `categorize.test.ts`: `categorizeChanges` omits a target whose `platforms` excludes the given platform.
- `categorize.test.ts`: `categorizeChanges` keeps a target whose `platforms` includes the given platform.
- `categorize.test.ts`: `categorizeChanges` keeps a target whose `platforms` is empty, on every platform.
- `categorize.test.ts`: a file watched only by a filtered-out target is reported as unwatched rather than dropped.
- `categorize.test.ts`: `applies` is false for a filtered-out target and true otherwise.
- `run.test.ts`: `structuredReport` omits filtered-out targets in every mode.
- `run.test.ts`: `reportTargetNames` never receives a wrong-platform target name.
- `run.test.ts`: `reportCategorizedChanges` prints a wrong-platform target as such rather than as unchanged.

## Smoke Tests

- In the what-changed repository, a new scenario in `scripts/smoke-tests.sh` giving a target `platforms: ["nosuchplatform"]` and asserting it appears in neither `targets` nor the affected part of `summary`, even when a file it watches has changed.
- A new `scripts/what-changed-smoke-tests.sh` in Photosphere driving `scripts/test-everything.sh` against a **fake** parallel runner rather than the real one. It must cover: `--plan` prints the target list and runs nothing; an empty target list exits 0 without invoking the runner; a non-empty list invokes the runner with exactly those names; a failing runner leaves the baseline unmoved so the same targets come back next time; a passing runner moves the baseline so the next run reports nothing; and `--force` invokes the runner with no names at all. The fake runner is a script the test writes into a throwaway directory that records its arguments to a log, and the test asserts on that log. **This script must create no git repository and run no state-changing git command.**
- A scenario in that same script for `scripts/install-what-changed.sh`: with the binary already present and at the pinned version it downloads nothing, and it fails loudly rather than silently on an unrecognised platform.

## Verify

- In the what-changed repository: `bun run compile` exits 0, `bun run ta` passes, `./scripts/smoke-tests.sh --binary` passes, and a release exists whose `what-changed version` reports it.
- Photosphere: `bun run compile` exits 0.
- `bash ./scripts/install-what-changed.sh` puts a working binary at `tools/bin/what-changed` and `tools/bin/what-changed version` prints the pinned version.
- `bun run everything:plan` prints a target list with no error, and on Linux never names `test:ios` or `test:ios:unit`.
- `bun run what-changed` lists changed files.
- `bun run what-changed:targets` prints only target names, one per line, and nothing when the tree is unchanged.
- `bun run tev -- --force` runs the whole platform set through `scripts/test-everything-parallel.sh` and passes.
- `bun run tev` immediately afterwards reports nothing to run and exits 0.
- Touching a file under `apps/cli/` and running `bun run everything:plan` names `test:cli` and not `test:electron`.
- Editing only a `.md` file and running `bun run everything:plan` names no targets.
- `bash ./scripts/what-changed-smoke-tests.sh` passes.
- `grep -rn "tools/what-changed" --exclude-dir=node_modules .` returns nothing outside `docs/plans/`.
- `grep -rn "test:what-changed" --exclude-dir=node_modules .` returns nothing outside `docs/plans/`.
- `git status` shows neither `.what-changed/` nor `tools/bin/` as untracked.

## Notes

- **The frozen files stay frozen.** `scripts/test-everything-parallel.sh`, `.githooks/pre-commit` and `scripts/install-hooks.sh` must not be edited, and nothing here requires it. `pre-commit` calls `bun run test:everything`, and that script name is redefined in `package.json`. The parallel runner already accepts explicit script names as arguments, which is exactly the interface the new script needs.

- **The old tool spawned; the new one does not.** This is the whole reason a new Photosphere script is needed. The old `runnerCommand` pointed at `scripts/test-everything-parallel.sh` and the tool ran it. The new tool reports and stops, so "run it, then record the baseline only on success" becomes Photosphere's to own and test.

- **Recording only on success is the rule that matters.** If `scripts/test-everything.sh` captures the baseline after a failing run, a broken tree is marked as tested and the next run reports nothing to do. The smoke test covering that is the most important one in the list.

- **Distribution is a released executable, not a package.** The what-changed project is `private: true` and publishes nothing to npm. It ships a single-file Bun executable per platform on its releases page. That rules out a dependency in `package.json` and makes the download script the integration point.

- **Config format and field names changed.** TOML support was dropped: the published tool reads YAML (`.yaml`/`.yml`) and JSON only, and looks for them in that order. `alwaysPaths` is now `always` and `ignoreExtensions` is now `ignore`. Photosphere's existing `what-changed.json` uses the old names and would silently get empty lists for both, since unknown keys are not rejected and both fields are optional. That silence is the risk in step 2: check the converted config with `bun run everything:plan` and confirm an edit to `package.json` still marks every target.

- **All the tool's state is under one directory now.** `.what-changed/` holds `baseline.json` and `cache/`. One `.gitignore` line covers both. The two are still separate stores, and `cache reset` still cannot reach the baseline, but Photosphere only needs to ignore the one path.

- **`test:what-changed` disappears from Photosphere entirely.** The tool's suites run in its own repository's CI. Removing the target is safe with the frozen runner because its default script set never included it.
