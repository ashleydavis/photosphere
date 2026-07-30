# Git hooks

The local test gate. Two hooks stop a commit that does not compile and stop a push whose tests fail. They are checked in, but they are **not** active until you install them once per clone.

## How git hooks work, in general

A git hook is just an executable script that git runs at a particular moment. If the script exits non-zero, git abandons the operation. There is no configuration language and no plugin system: the name of the file decides when it runs.

Three things about them are worth knowing up front, because they explain the whole setup here.

- **Hooks are not version controlled.** Git only ever runs hooks from one directory, and by default that is `.git/hooks`, which is not part of the repository. So you cannot commit a hook and have it work for everyone. A fresh clone of this repository has git's stock `*.sample` files there and nothing else, which means nothing runs at any point.
- **`core.hooksPath` is the way round that.** Setting it tells git to look somewhere else, so the scripts can live in the repository as ordinary tracked files. That setting is per clone and is not itself committed, which is why installing is a manual step and why anyone who already cloned has to run it too.
- **`--no-verify` always wins.** `git commit --no-verify` and `git push --no-verify` skip the hook entirely. That is git's own behaviour, not something these scripts implement, and it cannot be disabled. A hook is a convenience for the person running it, never a security control.

## Installing them

Once per clone:

```
bash scripts/install-hooks.sh
```

That runs `git config core.hooksPath .githooks`. Nothing runs it for you, and cloning does not.

Confirm they are active:

```
git config core.hooksPath
```

It should print `.githooks`. Anything else, including no output, means the hooks are doing nothing.

The path is set relative rather than absolute so it resolves against whichever working tree git is running in. That matters because a git worktree shares one config file with the main clone, and a relative path lets both use their own checked-in copy.

## What each hook runs

Both hooks delegate to `bun run test:everything`, so what they run is the same set you can run by hand.

**`.githooks/pre-commit`** runs two things:

```
bun run compile
bun run test
```

That is all. It is meant to be quick enough that you never want to skip it.

**`.githooks/pre-push`** runs the full set for your platform:

| | Linux | macOS |
| --- | --- | --- |
| Unit tests | `bun run test` | `bun run test` |
| CLI smoke tests | `bun run test:cli` | `bun run test:cli` |
| Electron smoke tests | `bun run test:electron` | `bun run test:electron` |
| Mobile smoke tests | `bun run test:and` | `bun run test:ios` |
| Mobile native unit tests | `bun run test:and:unit` | `bun run test:ios:unit` |

The platform is detected with `uname`. The mobile toolchains do not exist on the other platform, so there is no way to run both sets from one machine.

## Why the split

The full set is far too slow to run on every commit, and the mobile suites need a device or emulator attached. A gate slow enough to be bypassed as a matter of routine is worse than no gate, because the repository then looks guarded when it is not. So the cheap checks guard every commit and the expensive ones guard the push, which happens far less often.

## Why everything runs in parallel

`bun run test:everything` (which runs `scripts/test-everything-parallel.sh`) starts every script at once, waits for all of them, and reports each result separately. Run one after another the same set takes around eleven minutes; started together it takes about as long as the slowest one, roughly three and a half. That difference is the difference between a hook people leave switched on and a hook people bypass.

You can run it yourself, which is the fastest way to see where you stand before pushing:

```
bun run test:everything                 # the whole set for this platform
bun run tev                             # the same thing, shorter
bun run test:everything compile test    # just those two, still in parallel
```

With no arguments it runs the whole platform set. With script names it runs exactly those. Every script's output is captured separately, and only the failures are printed at the end, each followed by the single command to re-run on its own. Working on one failure at a time beats re-running the whole set.

**It stops as soon as anything fails.** The remaining scripts are killed rather than left to finish, along with everything they started, so a failure comes back in seconds instead of after the slowest suite has run its course. There is no point waiting for an answer that is already "no", and one failure is enough to stop a commit or a push. The trade is that a run tells you about the first failure rather than all of them: anything still running is reported as cancelled with its result unknown, so a second failure elsewhere only surfaces once the first is fixed.

Two things to be aware of when running everything at once:

- `test:and` and `test:and:unit` both run `bun run sync` and Gradle against the same `apps/android-frontend/android` project, so in parallel they are two builds in one project directory. The same applies to `test:ios` and `test:ios:unit`.
- `compile` writes `dist` while the test suites read the source tree.

Neither has caused a failure in practice, but if you see a build error that makes no sense, re-run the one script on its own before believing it.

## The mobile rule

**Changes to mobile code cannot be pushed without running the mobile suites.** If the push touches any of these paths, `pre-push` runs them, and refuses the push if no device is attached rather than skipping them:

```
packages/mobile-frontend/
packages/mobile-worker/
apps/android-frontend/
apps/ios-frontend/
apps/smoke-tests/
```

The reason is specific. Unit tests cannot see embedded-worker task ordering or the on-device config file, and those are exactly what commit `61ac4cee` broke: it moved the mobile database list into `databases.toml` and broke 8 of 37 Android smoke tests, and it was committed and pushed without the mobile suite ever being run. `bun run test:all` would not have caught it either, because `test:all` covers no mobile suite at all.

For a push touching no mobile code, an absent device drops the mobile suites with a printed notice instead of failing.

A push that creates a new remote branch has no previous remote state to compare against, so its changed paths cannot be worked out. That case is treated as touching mobile code, gating harder rather than softer.

## Bypassing

```
git commit --no-verify
git push --no-verify
```

Legitimate reasons: a docs-only commit, or a work-in-progress push to your own branch.

Not a legitimate reason: "the emulator was not running". That is the case the mobile rule exists to catch.

## Where this sits

These hooks are the fast local gate. `.github/workflows/release.yml` is the slow authoritative one, and it is what decides whether a change is actually good. The hooks exist to tell you in minutes what CI would have told you later.

Neither hook fixes anything, stages anything, or amends anything. They report and refuse, and leave your working copy exactly as it was.
