# Extract what-changed into its own repo and npm package

## Overview

`tools/what-changed` is already a self-contained tool: no runtime dependencies, no Photosphere-specific code, its own README, HOW_IT_WORKS doc, unit tests, smoke tests and perf tests. Everything project-specific already lives in `what-changed.json` at the repo root. This plan lifts it out of the monorepo into a standalone open-source repository published to npm, and rewires Photosphere to consume the published package instead of the local directory.

Two hard constraints shape the plan. First, the AI agent executing it must not run any git operation that creates or changes repository state (no `git init`, `git add`, `git commit`, `git remote`, `git push`), and must not run `npm publish`. The agent prepares the new repository's contents on disk as a plain directory and stops; the human creates the GitHub repo, makes the first commit, and publishes. Second, `scripts/test-everything-parallel.sh` and `.githooks/pre-commit` are frozen. Neither references what-changed (the frozen runner's default script set is `compile test test:cli test:electron` plus the platform mobile scripts), so nothing in this plan needs to touch them.

## Issues

## Steps

1. **Pick the package name and record it.** `what-changed` is taken on npm (someone else's package, currently 2.3.1). The scope `@ashleydavis/what-changed` is free, as is `what-changed-cli`. Default to `@ashleydavis/what-changed` unless the human says otherwise. Every step below uses `<pkg>` for whichever is chosen.

2. **Create the staging directory for the new repo.** Copy the whole of `tools/what-changed/` to a sibling directory of the monorepo checkout, e.g. `../what-changed/`, preserving `src/`, `docs/`, `perf-tests/`, `README.md`, `smoke-tests.sh`, `jest.config.js`, `tsconfig.json`. Do not delete the monorepo copy yet; it is removed in step 12 once the package works. Copy `LICENSE` from the monorepo root into the new directory (both are MIT and the author is the same).

3. **Confirm the code is runtime-agnostic.** Grep `../what-changed/src/` for `Bun.`, `from "bun"`, `bun:` and `import.meta`. There are currently no hits, so the tool runs on plain Node. If any appear during the port, replace them with the Node equivalent rather than adding a Bun dependency. The published package must run under `node` with no assumption about Bun.

4. **Rewrite `../what-changed/package.json`.** Set `name` to `<pkg>`, `version` to `0.1.0`, a real `description`, `license: "MIT"`, `author`, and `repository`/`bugs`/`homepage` pointing at the new GitHub repo. Add `"bin": { "what-changed": "./dist/cli.js" }`, `"main": "./dist/index.js"`, `"types": "./dist/index.d.ts"`, `"files": ["dist", "README.md", "LICENSE", "docs"]`, `"engines": { "node": ">=18" }`, and for a scoped name `"publishConfig": { "access": "public" }`. Keep the existing devDependencies and the `test`, `test:coverage`, `test:watch`, `perf`, `clean` scripts. Change `compile` to emit (see next step) and add `"prepublishOnly": "npm run compile && npm test"`.

5. **Make `tsconfig.json` emit a build.** In `../what-changed/tsconfig.json`, set `noEmit` to `false`, keep `outDir` as `./dist` (change from `./build` so it matches `main`/`bin`), keep `declaration` and `declarationMap`, drop `"jsx"` and `"experimentalDecorators"` (no JSX or decorators in this codebase), and set `"module"`/`"moduleResolution"` to a pair that produces runnable Node output for the chosen module format. Exclude `src/test` from the emitted build via an `exclude` entry so tests are not shipped. Verify `npx tsc` produces `dist/cli.js` and `dist/index.js` with no errors.

6. **Give the CLI a shebang and verify it runs as a binary.** Add `#!/usr/bin/env node` as the first line of `../what-changed/src/cli.ts` (TypeScript passes a leading shebang through to the emitted JS). After compiling, `chmod +x dist/cli.js` is not needed because npm sets the bit for `bin` entries on install, but verify by running `node dist/cli.js --help` and confirming the usage text and exit code 0.

7. **Verify the package installs and runs from a tarball.** Run `npm pack` in `../what-changed/`, then in a throwaway directory (`mktemp -d`) run `npm install <path-to-tarball>` and `./node_modules/.bin/what-changed --help`. This catches a missing `files` entry, a wrong `bin` path or a missing shebang before anything is published. Do not run `npm publish`.

8. **Update the README for a standalone package.** In `../what-changed/README.md`, replace the "Getting started" step 1 ("Copy the what-changed directory into your project") with `npm install --save-dev <pkg>`, change the invocation examples from `bun what-changed/src/cli.ts` to the `what-changed` binary, and update the "Running it directly" heading and its usage line. Add an install/badge line at the top with the package name. Leave the behaviour documentation as is; it is accurate.

9. **Update `docs/HOW_IT_WORKS.md` and `docs/testing-gaps.md` in the new repo** for any path references that assume the tool sits inside a host project (e.g. `tools/what-changed/...`). Keep the honest statement in `testing-gaps.md` that the end-to-end gating flow is not covered by an automated test because covering it would require creating a git repository.

10. **Add repo hygiene files to `../what-changed/`.** A `.gitignore` covering `node_modules/`, `dist/`, `build/`, `coverage/`, `*.tsbuildinfo` and `.cache/`. A `.github/workflows/ci.yml` that on push and pull request runs `npm ci`, `npm run compile`, `npm test` and `./smoke-tests.sh` on `ubuntu-latest` (and `macos-latest` if cheap). The workflow must not run `npm publish`.

11. **Run the full test set in the new repo.** `npm run compile`, `npm test`, `npm run test:coverage`, `npm run perf`, `./smoke-tests.sh`. All must pass. `smoke-tests.sh` invokes the CLI by path (`$SCRIPT_DIR/src/cli.ts` under Bun); change it to invoke the built `dist/cli.js` under `node` so the smoke suite exercises the thing that actually ships, and re-run it. Confirm the scenario count and pass count are unchanged from before the move.

12. **Remove the tool from the monorepo.** Delete `tools/what-changed/` from the Photosphere checkout. Check whether `tools/` still contains anything; if it is now empty, leave the `"tools/*"` workspace glob in the root `package.json` alone (an empty glob is harmless) unless the directory itself is gone.

13. **Add the published package as a devDependency of the monorepo.** Add `<pkg>` at the published version to `devDependencies` in the root `package.json` and run `bun install`. Until the human has published, this step is blocked; the agent should stop here and say so rather than faking it with a `file:` or `link:` dependency.

14. **Rewire the root `package.json` scripts** to the installed binary instead of the source path:
    - `test:everything`: `what-changed`
    - `test:everything:plan`: `what-changed --plan`
    - `what-changed`: `what-changed --files`
    - `what-changed:baseline`: `what-changed --baseline`
    - `test:what-changed`: delete it. The tool's own smoke suite now lives in its own repo's CI and is not Photosphere's to run.
    Leave `test:everything:force` pointing at `./scripts/test-everything-parallel.sh`.

15. **Update `what-changed.json`.** Remove the `test:what-changed` target entirely (its `paths` were `tools/what-changed`, which no longer exists). Leave `runnerCommand`, `alwaysPaths` and every other target unchanged. Removing a target is safe with the frozen parallel runner because its default script set never included `test:what-changed`.

16. **Update the monorepo docs** that reference the tool's location or its smoke script: `CLAUDE.md` (the `test:what-changed` bullet, the `what-changed` and `what-changed:baseline` bullets, and the mention of "the what-changed smoke tests" in the `test:everything` description), `docs/git-hooks.md` (the `test:what-changed` row in the target table, the "There is also `bun run test:what-changed`" paragraph, and the closing paragraph pointing at `tools/what-changed` and its README, which should now link the GitHub repo and npm package), `docs/development.md` (the `tools/` tree entry at line ~42), and `docs/testing/README.md` if it names the tool's path. Do not touch `.githooks/pre-commit` or `scripts/test-everything-parallel.sh`.

17. **Verify the monorepo still gates correctly.** Run `bun run test:everything:plan` and confirm it prints one line per remaining target with no error, then `bun run what-changed` and confirm it lists changed files. Then run `bun run tev -- --force` and confirm the whole suite runs and passes through the installed binary.

## Unit Tests

The tool's existing unit tests (`src/test/cache-store.test.ts`, `changed-files.test.ts`, `cli-args.test.ts`, `config.test.ts`, `file-hash.test.ts`, `gate.test.ts`, `list-files.test.ts`, `merkle.test.ts`, `plan.test.ts`, `run-command.test.ts`) move with the code unchanged. No function is being added or changed by this plan, so no new unit test is required. If step 3 forces any Bun-to-Node substitution, that changed function gets a unit test covering the new call.

## Smoke Tests

- `smoke-tests.sh` in the new repo, retargeted at `node dist/cli.js` (step 11). It must still cover all nineteen existing scenarios and pass with the same counts.
- The tarball install check in step 7: `npm pack`, install into a temp directory, run `what-changed --help`. Add this as a shell script `verify-package.sh` in the new repo so it is repeatable, and wire it into the CI workflow after `npm run compile`.
- On the monorepo side, `bun run test:everything:plan` and `bun run tev -- --force` (step 17) are the end-to-end check that the published binary drives the real suite.

## Verify

- `npm run compile` in the new repo exits 0 and produces `dist/cli.js`, `dist/index.js` and their `.d.ts` files.
- `npm test` in the new repo passes with the same test count as before the move.
- `npm run test:coverage` still reports 100% statements, functions and lines.
- `./smoke-tests.sh` in the new repo passes every scenario against the built `dist/cli.js`.
- `./verify-package.sh` installs the packed tarball into a temp directory and `what-changed --help` prints usage and exits 0.
- `npm run perf` passes its budgets.
- In the monorepo: `bun run compile` passes, `bun run test:everything:plan` prints the plan without error, and `bun run tev -- --force` runs and passes the whole suite.
- `grep -rn "tools/what-changed" --exclude-dir=node_modules .` in the monorepo returns nothing.

## Notes

- **npm name.** `what-changed` is already published by someone else. `@ashleydavis/what-changed` and `what-changed-cli` are both free. The scoped name is the recommendation. This is the human's call and blocks step 4.
- **The agent must not run git or publish.** Creating the GitHub repository, the initial commit, the push, and `npm publish` are all the human's to do. The agent's output is a directory that is ready to become a repo. Step 13 onwards cannot complete until the package exists on npm.
- **Steps 12 to 17 are a separate landing.** Steps 1 to 11 produce the new repo and change nothing in Photosphere. Steps 12 to 17 change Photosphere and depend on a published version. Do not start step 12 before the package is on npm, or the monorepo is left with no working gate.
- **Frozen files are untouched.** `.githooks/pre-commit` and `scripts/test-everything-parallel.sh` do not mention what-changed and must not be edited. The only frozen-adjacent risk is the `test:what-changed` script name, which the runner never asks for by default, so removing it is safe.
- **The `--files` and gating end-to-end paths stay untested** in the new repo for the same reason they are untested now: exercising them needs a real git repository, and a test that creates one can land on the wrong repository. `docs/testing-gaps.md` states this and should keep stating it.
- **Bun vs Node.** Photosphere currently runs the tool with `bun`. The published package targets Node so it is usable outside Bun projects. Photosphere will invoke it through `node_modules/.bin/what-changed`, which `bun run` puts on `PATH`, so nothing about the monorepo's use of Bun changes.
