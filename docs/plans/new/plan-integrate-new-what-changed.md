# Integrate the new what-changed into Photosphere and delete the old one

## Overview

`tools/what-changed` has been rewritten as a standalone Bun project at `../what-changed` (sibling of the Photosphere checkout, its own git repository). The rewrite changed what the tool *is*: the old one was a gate that spawned a runner, the new one is a reporter that runs nothing. It also gained subcommands, TOML/YAML/JSON configs, `--output text|json|yaml`, and a baseline stored separately from the speed cache. This plan replaces Photosphere's copy with the new tool, moves the "decide then run" logic into a Photosphere-owned script, and deletes `tools/what-changed`.

The central consequence: nothing in the new tool spawns `scripts/test-everything-parallel.sh`. Photosphere must own that step itself. The frozen files (`scripts/test-everything-parallel.sh`, `.githooks/pre-commit`, `scripts/install-hooks.sh`) must not be edited, and neither needs to be: `pre-commit` already calls `bun run test:everything`, and `package.json` is free to change.

## Issues

- [ ] **Platform filtering is missing from the new tool and must be restored before this plan can start.** `ITargetConfig.platforms` is still parsed and validated in `../what-changed/src/lib/config.ts`, but nothing reads it: `categorizeChanges` in `src/lib/categorize.ts` ignores it entirely. Photosphere depends on it (`test:and`/`test:and:unit` are `linux`, `test:ios`/`test:ios:unit` are `darwin`). Without it, a Linux machine would be told `test:ios` is affected and the runner would be asked for a script whose toolchain is not installed. Step 1 covers the fix; the rest of the plan is blocked until it is done.

- [ ] **Decide how Photosphere consumes the tool.** The new project publishes a single-file executable to GitHub releases and is no longer an npm package (`bin`, `main`, `files` and `publishConfig` were all removed). Three options, and the plan assumes the first: (a) a Bun git dependency, `"@codecapers/what-changed": "github:codecapers/what-changed"`, run as `bun node_modules/@codecapers/what-changed/src/cli.ts`; (b) the released binary downloaded into `tools/bin/` by a setup script, which adds a 91MB artefact and a download step; (c) re-add npm packaging to the new project. This is the human's call and it changes step 3.

## Steps

1. **Restore platform filtering in the new what-changed project** (`../what-changed`, not the Photosphere checkout). In `src/lib/categorize.ts`, add a `platform: string` parameter to `categorizeChanges` and skip any target whose `platforms` array is non-empty and does not include the platform. Give `ITargetChanges` an `applies: boolean` field so a filtered-out target can still be listed as "not on this platform" rather than vanishing. Thread `platform` through `report` in `src/lib/run.ts` (it already takes `cwd` and `listFiles` as arguments for the same reason; add `platform` alongside them, supplied by `process.platform` from each command in `src/cmd/`). `reportCategorizedChanges` prints `wrong-platform` for those targets; `reportTargetNames` and `structuredReport` omit them. Compiles, unit tests pass, smoke tests pass.

2. **Convert `what-changed.json` to `what-changed.toml`** at the Photosphere repo root. Keep every target name exactly as it is (`compile`, `test`, `test:cli`, `test:electron`, `test:and`, `test:and:unit`, `test:ios`, `test:ios:unit`) because those names are passed straight to the frozen `scripts/test-everything-parallel.sh` as script names. Drop the `runnerCommand` field, which the new tool does not have. Keep `platforms` on the four mobile targets. Delete the `test:what-changed` target: the tool's smoke suite now lives in its own repository. Add `baselinePath` only if the default `.what-changed/baseline.json` is not wanted. Delete `what-changed.json`.

3. **Add the dependency.** Add `"@codecapers/what-changed": "github:codecapers/what-changed"` to `devDependencies` in the root `package.json` and run `bun install`. Confirm `bun node_modules/@codecapers/what-changed/src/cli.ts --help` prints the usage text. (Blocked on issue 2 above; if option (b) is chosen instead, this step becomes a download step and the invocation becomes a path under `tools/bin/`.)

4. **Write `scripts/test-everything.sh`**, a new Photosphere-owned script modelled on `../what-changed/scripts/test-everything.sh`. It must: parse `--force` and `--plan` and pass any other arguments through as explicit target names; ask the tool for the affected targets via `what-changed targets`; exit 0 with a "nothing to run" message when the list is empty; otherwise invoke `bash ./scripts/test-everything-parallel.sh "${TARGETS[@]}"`; and only after that exits 0, run `what-changed baseline capture`. Route the tool through `mise exec --` when `mise` is on `PATH`, matching `.githooks/pre-commit`. With `--force`, skip the query and pass no names to the parallel runner so it picks its own platform-appropriate default set. With `--plan`, print the target list and exit without running anything.

5. **Rewire the root `package.json` scripts.** `test:everything` becomes `bash ./scripts/test-everything.sh`. `everything:plan` becomes `bash ./scripts/test-everything.sh --plan`. `what-changed` becomes the tool's `changes` subcommand. `what-changed:baseline` becomes `baseline capture`. Add `what-changed:targets` for the raw target list and `what-changed:reset` for `baseline reset`. Delete `test:what-changed`. Leave `test:everything:all` and `tev` alone.

6. **Delete `tools/what-changed/`** from the Photosphere checkout. Check whether `tools/` still holds anything; if it is now empty, remove the `"tools/*"` entry from the `workspaces` array in the root `package.json` and run `bun install` again so the lockfile drops the workspace.

7. **Add `.what-changed/` to the root `.gitignore`**, next to the existing `.cache/` entry. Without it the tool lists its own baseline as an untracked file and reports it as a change to itself on every run.

8. **Update `docs/git-hooks.md`.** The target table loses its `test:what-changed` row and gains a note that platform-specific targets are filtered by the tool rather than by `uname`. The paragraph beginning "There is also `bun run test:what-changed`" goes. The section describing the gate must be rewritten around the new split: what-changed reports, `scripts/test-everything.sh` decides what to do about it, `scripts/test-everything-parallel.sh` runs it. Update the cache paragraph to describe both `.cache/what-changed/` and `.what-changed/baseline.json` and what clearing each one costs. Update the closing paragraph's links to point at the new GitHub repository rather than `tools/what-changed`.

9. **Update `CLAUDE.md`.** The `test:everything` bullet must describe the new arrangement and stop mentioning "the what-changed smoke tests" as part of the set. The `what-changed` and `what-changed:baseline` bullets change to the new subcommands. Delete the `test:what-changed` bullet. Add a bullet for `what-changed:targets`.

10. **Update `docs/development.md`.** Remove the `tools/ - what-changed` tree entry at line ~42. Update the `test:everything` and `test:everything:all` rows in the command table to describe the reporter plus runner split.

11. **Check `scripts/find-flakey-tests.sh` still works.** It drives `bun run test:everything -- --force` in a loop and its comments describe `--force` as defeating "the what-changed gate". The new `scripts/test-everything.sh` must accept `--force` with the same meaning. Update the two comments (around lines 14 and 120) to describe the new arrangement. Do not change the command itself.

## Unit Tests

All in `../what-changed/src/test/`, since step 1 is the only code change and it is in that project. Photosphere's own changes are shell and config, which are covered by the smoke tests below.

- `categorize.test.ts`: `categorizeChanges` omits a target whose `platforms` excludes the given platform.
- `categorize.test.ts`: `categorizeChanges` keeps a target whose `platforms` includes the given platform.
- `categorize.test.ts`: `categorizeChanges` keeps a target whose `platforms` is empty, on every platform.
- `categorize.test.ts`: a file watched only by a filtered-out target is reported as unwatched rather than silently dropped.
- `categorize.test.ts`: `applies` is false for a filtered-out target and true otherwise.
- `run.test.ts`: `structuredReport` omits filtered-out targets from `targets` in every mode.
- `run.test.ts`: `reportTargetNames` never receives a wrong-platform target name.
- `run.test.ts`: `reportCategorizedChanges` prints a wrong-platform target as such rather than as unchanged.

## Smoke Tests

- `../what-changed/scripts/smoke-tests.sh`: a new scenario in the real-repository section giving a target `platforms = ["nosuchplatform"]` and asserting it appears in neither `targets` nor the affected part of `summary`, even when a file it watches has changed.
- A new `scripts/what-changed-smoke-tests.sh` in Photosphere, driving `scripts/test-everything.sh` against a **fake** parallel runner rather than the real one. It must cover: `--plan` prints the target list and runs nothing; an empty target list exits 0 without invoking the runner; a non-empty list invokes the runner with exactly those names; a failing runner leaves the baseline unmoved so the same targets come back next time; a passing runner moves the baseline so the next run reports nothing; and `--force` invokes the runner with no names at all. The fake runner must be a script the test writes into a throwaway directory that records its arguments to a log, and the test asserts on that log. **This script must create no git repository and run no state-changing git command.**
- Add the new script to `what-changed.toml` as its own target so it is itself gated, and to `scripts/test-everything-parallel.sh`'s default set. **The parallel runner is frozen**, so if the new target cannot be added without editing it, leave the target out of the default set and note that in the plan's Notes rather than editing the frozen file.

## Verify

- `../what-changed`: `bun run compile` exits 0, `bun run test` passes, `./scripts/smoke-tests.sh` passes, `./scripts/smoke-tests.sh --binary` passes.
- Photosphere: `bun run compile` exits 0.
- `bun run everything:plan` prints a target list with no error, and on Linux never names `test:ios` or `test:ios:unit`.
- `bun run what-changed` lists changed files.
- `bun run what-changed:targets` prints only target names, one per line, and nothing when the tree is unchanged.
- `bun run tev -- --force` runs the whole platform set through `scripts/test-everything-parallel.sh` and passes.
- `bun run tev` immediately afterwards reports nothing to run and exits 0.
- Touching a file under `apps/cli/` and running `bun run everything:plan` names `test:cli` and does not name `test:electron`.
- Editing only a `.md` file and running `bun run everything:plan` names no targets.
- `bash ./scripts/what-changed-smoke-tests.sh` passes.
- `grep -rn "tools/what-changed" --exclude-dir=node_modules .` returns nothing outside `docs/plans/`.
- `grep -rn "test:what-changed" --exclude-dir=node_modules .` returns nothing outside `docs/plans/`.
- `git status` shows `.what-changed/` is not listed as untracked.

## Notes

- **The frozen files stay frozen.** `scripts/test-everything-parallel.sh`, `.githooks/pre-commit` and `scripts/install-hooks.sh` must not be edited. Nothing here requires it: `pre-commit` calls `bun run test:everything`, and that script name is redefined in `package.json`, which is not frozen. The parallel runner already accepts explicit script names as arguments, which is exactly the interface the new `scripts/test-everything.sh` needs.

- **The old tool spawned; the new one does not.** This is the whole reason a new Photosphere script is needed. The old `runnerCommand` pointed at `scripts/test-everything-parallel.sh` and the tool ran it. The new tool reports and stops, so the "run it, then record the baseline only on success" logic moves into `scripts/test-everything.sh` and becomes Photosphere's to own and test.

- **Recording only on success is the rule that matters.** If `scripts/test-everything.sh` captures the baseline after a failing run, a broken tree is marked as tested and the next run reports nothing to do. The smoke test covering this is the most important one in the list.

- **`--force` bypasses the query entirely** rather than asking for every target name. Passing no names to the parallel runner lets it choose its own platform-appropriate default set, which is the behaviour `scripts/find-flakey-tests.sh` already depends on.

- **Config format.** TOML is the new tool's lead format, so `what-changed.toml` is the recommendation. The tool still reads JSON, so keeping `what-changed.json` would also work and would make step 2 a two-line edit instead of a rewrite. TOML was chosen for consistency with the new project's own config and examples.

- **The baseline moved out of the cache.** Photosphere previously had one gitignored directory to think about, `.cache/what-changed/`. It now has two, and they behave differently: clearing the cache costs a slow run, clearing the baseline makes everything read as changed. `docs/git-hooks.md` must say so, because "delete the cache to force a full run" is no longer the whole story.

- **`test:what-changed` disappears from Photosphere entirely.** The tool's own suites run in its own repository's CI. Removing the target is safe with the frozen runner because its default script set never included it.

- **Watch for the tool reporting its own state as a change.** Both `.cache/` and `.what-changed/` must be gitignored. This was caught during the rewrite: the baseline file was listed as an untracked file and so reported as a change to itself on every run.
