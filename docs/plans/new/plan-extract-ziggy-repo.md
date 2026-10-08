# Extract Ziggy and the Ziggy example into their own repository

## Overview

Ziggy (the Zig core, the native shells and the TypeScript bridge in `packages/ziggy`) and the Ziggy example (`apps/ziggy-example`) are to live in a repository of their own, so that Photosphere and a new app share one copy. It is undecided whether an app takes Ziggy as an installable package, or copies a template and builds on it. The plan starts with documentation that lays the options side by side and recommends one, and stops for the human to choose before any file moves. The recommendation drafted here is a hybrid: the framework is consumed as a package that each app pins to a version, and the example is the template an app is started from, so that a new app copies the app's own part once and receives framework updates by bumping a version.

## Issues

## Steps

1. Write the documentation, then STOP. Create `docs/ziggy-repository.md` as a draft of what the new repository's README and docs will say, for the human to read before anything moves. It has to cover: what the repository contains and what it deliberately leaves to apps; the two ways an app can use it (package, template) with what each means for an app's `build.zig`, `build.zig.zon`, Xcode project, Gradle project and `package.json`, and for how updates reach an app; the recommended hybrid and why; how Photosphere is wired to it; how a new app is started (copy the `apps/ziggy-example` folder, change its name and identifiers, and point its dependencies at the pinned versions, with no script); how versions are cut and pinned; the commands to build, test and release it; and the decisions the human has to make (listed in Notes). Do not continue to step 2. Wait for the human to review and approve the draft. If they revise it, or choose package-only or template-only, revise steps 2 to 11 to match before implementing anything.

2. Create the new repository from a fresh clone of this repository, never from this working tree. In a fresh clone, rewrite history to keep only `packages/ziggy` and `apps/ziggy-example` (use `git filter-repo --path packages/ziggy --path apps/ziggy-example`, or `git subtree split` for each folder if `git filter-repo` is not installed), keeping both folders at the same paths so the scripts that name `packages/ziggy` keep working. The repository's name, host and location come from the human at the step 1 stop. Run no history-rewriting command in this repository.

3. Give the new repository its own tool setup. Create `mise.toml` pinning the same Zig, Bun and Node versions as this repository's `mise.toml` (read it for the versions, do not copy a number into the plan). Create a root `package.json` with Bun workspaces for `packages/ziggy/bridge` and `apps/ziggy-example`, carrying the scripts this repository's `package.json` has for them (the `sync:ziggy-example:*`, `build:ziggy-example:*`, `run:ziggy-example:*`, `open:ziggy-example:*`, `test:ziggy-example*` and `compile:zig` scripts, renamed without the `ziggy-example` prefix where the prefix no longer says anything). Create `.gitignore`, `LICENSE` (the same license as this repository) and `bun.lock` (by running `bun install`).

4. Move the Ziggy parts of this repository's `build.zig` into the new repository's `build.zig`, together with the parts of `build.zig.zon` they need. The functions to move are `addZiggyCore`, `embedPage`, `addZiggy`, `addZiggyExampleLinux` and `addZiggyExampleWindows`, the `IZiggyCore` type, `linux_runtime_libraries`, and the helpers they call (`addDirectoryTests`, `internalStep`, and anything else found by compiling). Make the framework consumable by another build: register the core as a named module (`b.addModule("ziggy-core", ...)` with the `build_options` module attached), export `embedPage` and a function that builds the core for a target as `pub fn`, and export `addFrameworkTests`, which registers Ziggy's own unit tests on a step the caller passes in, so that an app's build can run the framework tests as part of its own `test` step. Keep the build options (`test-hooks`, `optimize`) working through the dependency.

5. Copy the shell libraries the example's scripts and smoke tests source from this repository's `scripts/lib/` (`test-timeout.sh`, `test-lib.sh`, `process-control.sh`, `allocate-test-temp-dir.sh` and whatever else the example's scripts name) into the new repository's `scripts/lib/`, each with its markdown file. Edit every `$REPO_ROOT/scripts/lib/...` reference in `apps/ziggy-example/scripts` and `apps/ziggy-example/smoke-tests` so it resolves in the new repository. Do not change this repository's copies.

6. Move continuous integration. Copy `.github/workflows/ziggy-example.yml` into the new repository as `.github/workflows/ci.yml`, keep its path filters accurate for the new layout, and keep its Zig cache steps. Nothing is published: a version is a git tag on the repository, and the tag is what an app pins. Add no release, registry or package-publishing workflow. Make the continuous integration also run on a version tag, so a tag is known to be good.

7. Make the native and bridge halves consumable. In `packages/ziggy/native/macos/Package.swift` and `packages/ziggy/native/ios/Package.swift`, keep the packages buildable from a git URL and a tag, and record in the docs the exact lines an app adds. In `packages/ziggy/native/android/build.gradle`, make the Android shell an installed dependency of an app's Gradle project, pinned to the tag, with no source copied into the app: declare it as a Gradle source dependency (`sourceControl { gitRepository(...) { producesModule(...) } }` in the app's `settings.gradle`) so Gradle builds it from the repository at the tag, and record the exact lines. If that does not build, stop and report it; do not publish a library and do not copy source. In `packages/ziggy/bridge/package.json`, make `ziggy-bridge` installable from a git URL and a tag. Check each by building the example against it.

8. Switch Photosphere to the new repository, once the new repository's continuous integration passes. In this repository: add `ziggy` to `build.zig.zon` (a `.path` dependency while developing, then the tag's archive URL (the repository's `archive/refs/tags/<tag>.tar.gz` address) and its hash); change `build.zig` to take the core module and the shells from `b.dependency("ziggy", ...)`; delete the Ziggy functions the new repository now has; call the dependency's `addFrameworkTests` so this repository's `test` step still runs the framework tests; and delete `packages/ziggy` and `apps/ziggy-example`. Keep `packages-zig/photosphere-core` importing `ziggy-core` by the same name.

9. Clean up the references left behind in this repository: remove the `ziggy-example` scripts and the `packages/ziggy` workspace entries from the root `package.json`; remove the targets and watched paths for the example and for `packages/ziggy` from `what-changed.yaml`; delete `.github/workflows/ziggy-example.yml`; remove the Ziggy lines from `.gitignore`; and update `CLAUDE.md`, `README.md`, `docs/development.md`, `docs/testing/README.md`, `apps/photosphere/README.md` and `apps/photosphere-smoke-tests/README.md` so each links to the new repository by its git URL instead of a relative path. Search the whole tree for `packages/ziggy` and `ziggy-example` and resolve every remaining hit.

10. Prove both repositories build and test on their own. In the new repository run the whole build and test set. In this repository run `bun run compile`, `zig build test` and the Zig CLI smoke tests, and confirm the Photosphere app folder still builds against the dependency. Fix every failure found, whatever its cause.

11. Update the documentation. Move `docs/ziggy-repository.md` into the new repository as its README and `docs/` pages, revised to match what was built (the real dependency lines, the real tag name, the real command names), and delete the draft from this repository. Keep this repository's `docs/` pointing at the new repository's README for everything about Ziggy.

## Unit Tests

- The Zig tests of `packages/ziggy/core`, `packages/ziggy/native/linux` and `packages/ziggy/native/windows`, and of `apps/ziggy-example/core`, move with the code and must pass unchanged in the new repository.
- The bridge's tests in `packages/ziggy/bridge/src/test` move with it and must pass in the new repository.
- The example page's tests under `apps/ziggy-example/page` move with it and must pass in the new repository.
- Add a test for each function in the new `build.zig` that is new rather than moved (the exported `addFrameworkTests` and the module export), written as a Zig build test that registers the step against a throwaway `std.Build` and checks the step exists with the dependencies it needs.

## Smoke Tests

- The example's smoke tests under `apps/ziggy-example/smoke-tests` run in the new repository's continuous integration on every platform they ran on before.
- In this repository, a build of the Photosphere app folder and `zig build test` run against the dependency, in continuous integration on every platform the Release workflow already covers.

## Verify

- In the new repository: the code compiles, the unit tests pass, the smoke tests pass, and its continuous integration is green on every platform.
- In this repository: `bun run compile` passes, `zig build test` passes and includes Ziggy's framework tests (read the test summary for the `ziggy-core` and shell test programs), the Zig CLI smoke tests pass, and the Release workflow is green.
- `grep -r "packages/ziggy" .` and `grep -r "ziggy-example" .` in this repository (excluding `node_modules`, `.zig-cache`, `zig-out` and `docs/plans`) find only intended links to the new repository.

## Notes

- Decisions for the human at the step 1 stop: the new repository's name, host and location; package, template or the recommended hybrid; whether history is kept (the plan assumes yes); and the tag naming scheme. Decided already: nothing is published to npm or any registry, an app takes a version as a git tag, the TypeScript bridge is installed from the git URL and tag, and no source is ever copied into an app.
- Why the hybrid is recommended: an app is two kinds of thing. The framework (core, shells, bridge) is code every app wants to receive fixes for, which a package gives and a template cannot, since a copy drifts. The example app (page, handlers, shell projects, scripts) is code each app owns and edits, which a template gives and a package cannot. A package-only approach forces apps to override pieces that were never meant to be configured. A template-only approach leaves Photosphere and the new app with their own diverging copies of the framework.
- Photosphere must still run Ziggy's framework tests, and the example's workflow must run the framework tests and the example's tests. After the move the framework tests run in the new repository's continuous integration and, through the dependency's `addFrameworkTests`, in Photosphere's own `test` step. The example's tests run only in the new repository.
- The example's smoke tests depend on this repository's `scripts/lib/` helpers. They are copied, not shared, so the two copies can drift; this is accepted to keep the repositories independent, and the copies are small.
- `packages-zig/photosphere-core` stays in this repository: it is Photosphere's code and only depends on Ziggy's core.
- The shells and the Android library name `dev.ziggy.shell`, `ZiggyShell` and similar identifiers; nothing here renames them.
- Every history-rewriting git command runs in a fresh clone of this repository and never here.
- Zig dependencies are fetched by hash. A `.path` dependency is for development only, because it ties the build to a sibling checkout on one machine; the committed `build.zig.zon` points at the tag archive URL and hash.
