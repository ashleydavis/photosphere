# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Platforms

This is crass platform app. Developed on Linux, but delivered and tested on Windows, Linux, MacOS, Android and iOS. All tests and smoke tests be cross platform to work on the platforms where they are delivered, here is the list of apps and where they run:

- CLI tool: Windows, Linux and MacOS.
- Desktop app: Windows, Linux and MacOS.
- Mobile app: Android and iOS.

## Rules

- When writing plans, do not add any steps for "Human Verification" or "Human Testing", plans you write should be automatically tested by unit tests and smoke tests. No human will be testing your work.
- YOU ARE RESPONSIBLE FOR THE CODE IN THIS REPO. IT DOESN'T MATTER "IF IT WAS ALREADY LIKE THAT" - YOU ARE EXPECTED TO FIX IT.
- IF YOU DON'T KNOW WHO WROTE THE CODE, IT MEANS YOU (CLAUDE) WROTE THE CODE.
- IT IS ALWAYS YOUR RESPONSIBILTY TO FIX COMPILE ERRORS AND FAILING TESTS. NEVER USE THE "PREEXISTING" EXCUSE.
- ANY addition of "test only" scaffolding to the app code must be approved by the human user first, or not added at all. That means anything shipped in the app that exists solely to let tests set up or inspect state: seeding functions, injection points, test-only commands, events or globals. If a test needs state, set it up from outside the app (write the config file, place the data on disk) the way the desktop tests do. If you believe there is no way to do that, stop and ask the user before writing any of it.
- NEVER WRITE A WORKAROUND, A FAKE, A MOCK, A STUB, OR A HAND-WRITTEN "REPLACEMENT" FOR A THIRD-PARTY SDK OR LIBRARY UNLESS THE HUMAN HAS SPECIFICALLY APPROVED THAT EXACT THING FIRST, IN THE MESSAGE YOU ARE ACTING ON. Approval must be explicit and asked for in advance. Silence is not approval. An earlier approval for one thing is not approval for another, and is not a standing permission. If you are unsure whether something counts, it counts: stop and ask. This bans, among other things: reimplementing a vendor SDK (AWS, Azure, Google Cloud, Dropbox, or any other), hand-writing a wire protocol, request signing, or response parsing that a maintained library already does, and aliasing a real package to your own substitute at build time. This repository cannot afford to maintain a copy of somebody else's SDK, and security-critical code such as request signing must come from upstream so it gets upstream fixes.
- If the real library will not work in an environment (for example the mobile embedded JS engine), STOP AND ASK THE HUMAN. Do not fill the gap yourself. Say plainly what does not work and what the options are, and wait for an answer. A shim that makes a build succeed while quietly reimplementing the library is worse than a build that fails, because the failure is visible and the shim is not.
- The same applies to tests: do not make a test pass by faking the thing under test, skipping it, or gating it behind an environment variable that is normally unset. A test that reports success without asserting anything is worse than no test. If a test needs real infrastructure, provision it (see `docs/plans/` for the local S3 server approach) or tell the human it cannot be done.
- NEVER WRITE A FAKE TEST. A fake test is any test that cannot fail when the thing it names is broken. This includes: a test written against a UI, API, element id, route, function or file that you have not verified exists; a test whose assertions you invented from what you imagined the code does rather than read from the code; a test that skips by default so its body has never executed; and a test you have never watched run. Every one of these reports success for work that was never checked, which is worse than having no test, because a green tick stops anyone looking. If you cannot run a test you have written, say so in that message and say plainly that it is unverified. Do not report it as passing, and do not count it toward "all tests green".
- RUN EVERY TEST YOU WRITE, AND WATCH IT FAIL FIRST. A new test that has only ever passed has not been shown to test anything. Break the thing it covers, or assert the wrong value, and confirm the test goes red before you accept it. If the test needs infrastructure you do not have, stop and tell the human rather than writing it blind.
- NEVER LIE ABOUT WHAT YOU HAVE DONE OR VERIFIED. Do not say a thing works, passes, is tested, is verified, or is complete unless you ran it and read the result in this session. Do not describe an intention as an outcome. Do not present a skipped test, a compile that merely succeeded, or a code reading as evidence that behaviour is correct. If you are inferring rather than observing, use words that say so, and say what you did not check. A confident summary that turns out to be unfounded costs more than saying "I have not verified this".
- NEVER SHIP A STUB THAT PRETENDS TO WORK. A function, class or method that silently does nothing (returns the argument, returns an empty result, swallows an event, or has an empty body) will be called by something eventually and will fail invisibly, often far from the cause. If you genuinely cannot implement something now, make it throw with a message naming what is missing, so the failure is loud and points at itself. Never leave a no-op in a code path that a caller will treat as success.
- ALL FAILURES MUST BE NOISY. Never write a path that discards an error, drops data, or returns a success value when the work did not happen. Unhandled errors get thrown, not swallowed. A missing capability throws and names itself. Prefer a loud crash over a quiet wrong answer, always.
- When you work around a bug instead of fixing it, you own that decision and must state it plainly to the human at the time, not bury it in a comment. Prefer fixing the cause. If you find yourself applying the same workaround in a second place, that is proof the cause needs fixing, not the workaround repeating.
- NEVER USE EM DASHES.
- Never use memory.
- All Claude configuration goes in this repository only, not in the home directory.
- Never stash code unless asked.
- Never use `cd` to permanently change directories within the repo. Use it on case-by-case and temporary basis as part of a command to run the command from a particular directory. Use of `cd` by itself will leave you in the wrong directory meaning other commands won't work.
- Never invoke shell scripts directly (e.g. `./apps/desktop/smoke-tests.sh`). Use the `bun run` equivalent from `package.json` (e.g. `bun run test:electron`, `bun run test:cli`).
- When running smoke tests, do not manually `rm -rf` the test's `tmp/` directory — the runner already cleans it before each test.
- When creating a new worktree, never use `EnterWorktree` with a `name` parameter. Instead: (1) run `git branch --show-current` to get the current branch, (2) run `git worktree add -b <new-branch> .claude/worktrees/<name> <current-branch>` to create the worktree explicitly branching from the current branch, (3) then use `EnterWorktree` with the `path` parameter to enter it.
- The commands I use to run the software always rebuild it automatically, so the running app is always built from current source. A code change that does not show up is never caused by a stale build or a missing rebuild. Never tell me to rebuild and never blame a missing change on the build being out of date. Find the real cause (a responsive breakpoint, caching, the wrong code path, a logic bug).
- Never assume whether the Android emulator pool is up or down. Run `bun run emu:and:pool:status` and read the exit code: 0 means at least one pool emulator is running and on the LAN bridge, 1 means none is. Add `-- --quiet` to use it directly in a condition. You have got this wrong every time you have guessed at it, and the way you get it wrong is always the same: a reading taken earlier in the session, never looked at again, and then stated later as a current fact. I start and stop emulators whenever I like and I do not announce it, so any reading is stale the moment after you take it. Run the check at the point you need the answer, not before. This applies just as much to saying the pool is up as to saying it is down, and to anything that follows from either, such as warning me that a command will fail for want of devices. If the check disagrees with what you expected, the check is right.
- Never say something was "intentionally done" unless I explicitly asked for that exact behaviour. Describing a behaviour as intentional when I never asked for it is an excuse for getting it wrong, especially when I am reporting that something does not work right. Do not decide to "intentionally" do something I did not request; if you did, you got it wrong. State plainly what the code does and own the mistake.
- Just because you (the AI) have previously written something in a plan does not mean that I approve of or accept that thing. Never use "it was in the plan" as the reason something was done. Whenever I ask "What is the reason for X?" I mean "Why was that change necessary?". If you think to answer with "because it was in the plan", know that it is the wrong answer. You may take my question to mean "Why did you plan to make that change?" and answer that question instead.
- Avoid an explosion of Electron IPC channels. Do not add new, action-specific IPC channels (for example a dedicated `toggle-devtools` channel). Reuse an existing channel, or use the generic `main-command` channel that dispatches named actions from the renderer to the main process. If you add new, specific IPC channels I will generally revert those changes.
- The `packages/user-interface` package is shared across all platforms (web, desktop/Electron, iOS, Android). It is not acceptable to put platform-specific code in that package: no Electron IPC or `window.electronAPI`, no Capacitor, no iOS/Android specifics. Keep platform-specific code in the relevant app/frontend (for example `apps/desktop-frontend`) and pass it into the shared UI via props or an existing platform abstraction.
- You are not to commit, stage, push, revert, or perform any other dangerous or hard-to-reverse Git operation (including `git add`, `git commit`, `git push`, `git reset`, `git restore`, `git checkout` of changes, `git rebase`, `git merge`, force-push, branch creation/deletion) without an explicit direction to do so in that message. An earlier instruction to do one of these is a one-time direction; it does not authorise repeating the operation after later edits. When in doubt, leave the Git state alone and ask.
- Expect the human to stage things. They often `git add` your work as they review it, and they commit whenever they choose, so the staging area and the working tree change under you without warning and without being mentioned. Finding your edits staged, or finding files you never touched appear, disappear or move between staged and unstaged, means the human has been working. It is never a mystery to investigate and never a sign that something has gone wrong. Deal with it: use `git status` and `git diff HEAD` (or `git diff --cached`) rather than a bare `git diff`, which shows only unstaged changes and will report nothing at all for work that has already been staged. Do not conclude your edit failed or was lost because `git diff` came back empty, do not go digging through the reflog over it, and above all do not "tidy it up" by unstaging, resetting, checking out or otherwise putting the Git state back how you remember it. The rule above still holds: leave the Git state exactly as you find it.
- NEVER COMMIT WITH VERIFICATION DISABLED. `git commit --no-verify` and its short form `git commit -n` are explicitly and emphatically banned for you, under all circumstances, with no exception. The same ban covers every other way of getting the same result: `git push --no-verify`, unsetting or repointing `core.hooksPath`, renaming, chmod-ing, emptying or deleting a hook, setting an environment variable that a hook checks, `git -c core.hooksPath=/dev/null`, an alias or wrapper that hides the flag, or asking a subagent or script to do any of it for you. There is no situation that justifies it: not a docs-only change, not "the tests are unrelated", not a failure you are certain is flaky, not a missing emulator, not a slow suite, not being told the tests already passed a moment ago, not being in a hurry. The hook is the only thing standing between a broken change and the history, and a commit that skipped it is indistinguishable afterwards from one that passed. If the hook refuses your commit, that is the system working: report the refusal and its output to me and stop. If you believe a bypass is genuinely warranted, say so plainly and wait. I may run `--no-verify` myself; that is my call and it is never yours, and my doing it once is not permission for you to do it ever.
- NEVER modify the git hook or the scripts it calls: `.githooks/pre-commit` and `scripts/install-hooks.sh`. These two are verified by hand and are frozen. They carry no automated tests, deliberately, so the only thing standing behind them is that a human ran them and watched them work. Any edit throws that away, and a broken gate fails silently: it simply stops refusing things, and nothing tells you, so the repository looks guarded when it is not. That is worse than having no gate at all. This holds for edits of every size, including a comment, a message, a rename, a "tidy up", or a fix to something you are certain is a bug. If you believe one of them needs to change, stop and say so, and leave the file alone until the human says otherwise.
- THIS REPOSITORY USES TYPESCRIPT AND SHELL SCRIPT. NOTHING ELSE. Do not introduce another language. `python3`, perl, Ruby, Go and friends are banned outright, including as an undeclared dependency: nothing here declares them, so every one is a thing that has to happen to exist on every developer machine and every CI runner. Java, Kotlin, Objective-C and Swift inside the native mobile projects are the sole exception, because iOS and Android require them, and that is not licence to add more of them than the platform forces.
- A SHELL SCRIPT CONTAINS SHELL. Do not embed another language inside one, in any form: not `python3 -c "..."`, not `bun -e "..."`, not a `node -e`, not a heredoc feeding an interpreter, not an awk program that is really a program. Embedded code is a string as far as the shell is concerned, so `$`, backticks and quotes inside it are live shell syntax waiting to bite; nothing type-checks it, nothing lints it, `bun run compile` never sees it, and a syntax error in it surfaces only when that one code path runs. This holds however short the snippet is. "It is only one line" is how every one of them starts.
- When a shell script needs something that looks beyond shell, find the shell answer first, because there usually is one: `stat` for a modification time, `cmp` for an exact file comparison, `uuidgen` for a UUID, `od` for a binary field, `jq` for anything JSON. Only when there is genuinely no shell answer (speaking a vendor's API through its SDK, running a long-lived server) does it become a TypeScript helper: a real `.ts` file under `scripts/`, with a comment block saying what it is for and a documented argument list, invoked as `bun scripts/thing.ts <args>`. See `scripts/seed-s3-bucket.ts` for the shape. That file gets type-checked, read and tested like the rest of the codebase. A string inside a shell script gets none of that.
- DO NOT WRITE TESTS FOR SHELL SCRIPTS, and do not create `*.test.sh` files. The rule elsewhere in this file requiring a test for every new or changed function does not apply to shell. Do not write one because a shell function "has logic", because it is shared by several callers, because a plan asked for one, or because an existing `*.test.sh` sets a precedent. The existing ones (`apps/smoke-tests/runner.test.sh`, `android-lock.test.sh`, `timeout.test.sh`) are not an invitation to add more; leave them alone and add nothing beside them. Shell in this repository is the test harness itself, and the thing that proves a harness works is running the real suite it drives, not a stub-driven test of its own branching. If you believe a piece of shell genuinely cannot be trusted without a test, stop and ask, and wait for an answer.
- Assume there IS a shell answer until you have tried it and watched it fail. Eight helpers were once written here on the judgement that shell could not do their job, and six of them were later replaced by shell that does exactly that: finding a free port, decoding a little-endian binary field, percent-encoding, escaping and reading JSON, resolving a package path, and rewriting a file. Every one of those had a comment asserting there was no shell answer, and the assertion was the only evidence behind it. If you are about to write that sentence in a new helper, that is the moment to go and try the shell version instead.
- The local iOS development environment is fixed: macOS 12.7.6 and Xcode 14.2. That is why the project is stuck on Capacitor 5 (later Capacitor requires a newer Xcode/macOS). Never bump tool or framework versions that would break this environment: do not upgrade Capacitor past 5, and do not require an Xcode or macOS version newer than Xcode 14.2 / macOS 12.7.6. When mobile code needs a newer API, prefer an availability guard or a compatible approach over raising a version. If a version bump seems unavoidable, stop and ask first.

## Project Overview

Photosphere is a self-hosted, cross-platform photo and video management application built as a monorepo using Bun workspaces. It includes web, desktop (Electron), mobile (iOS/Android), and CLI interfaces.

## Commands

### Setup
- `bun install` (from repo root) - You must do this before you can run any other scripts.

### Run from repo root:
- **`bun run test:everything` (alias `bun run tev`) IS THE CANONICAL WAY TO TEST A CHANGE.** Whenever you need to know whether a change is good, whether that is before a commit, after a rebase, at the end of a piece of work, or because you were asked to "run the tests", this is the command. Add `-- --force` to make every suite run regardless of what the change gate thinks changed, which is what to use after a rebase or whenever you want the whole set. Do not assemble your own sequence of `bun run compile`, `bun run test` and `bun run smoke` instead: that combination silently covers no mobile suite, so it passes while the mobile app is broken, and it is not what the git hook runs. The individual scripts below exist for narrowing down a failure once this one has told you there is one.
- `bun run compile` - Compile all TypeScript
- `bun run test:everything` (alias `bun run tev`) - Run the genuine full set for this platform, all at once (compile, unit, CLI, Electron, and both mobile suites). Use this when asked to run "all tests". Runs are gated on changed paths: a script is only run when the paths it watches (see `what-changed.yaml`) differ from what they were at the last passing run, so a docs-only change runs nothing. Pass `-- --force` to run everything regardless, `-- --plan` to print the decision without running anything. Pass script names to consider only those, still in parallel. This is what the git hooks run; see `docs/git-hooks.md`. It needs the `what-changed` executable on your PATH, from https://github.com/ashleydavis/what-changed/releases.
- `bun run test:everything:all` - The whole set for this platform, changed or not. The same as `-- --force`.
- `bun run test:all` - Unit tests plus the CLI and Electron smoke tests, one after another. Despite the name it covers NO mobile suite, so it can pass while the mobile app is broken. Any change under `packages/mobile-frontend/`, `packages/mobile-worker/`, `apps/android-frontend/`, `apps/ios-frontend/` or `apps/smoke-tests/` requires `bun run test:and` (or `bun run test:ios` on macOS) before it is committed.
- `bun run test` - Run unit tests only
- `bun run test -- <test-name-or-pattern>` - Run a single test by name or pattern.
- `bun run clean` - Clean all build artifacts
- `bun run dev` - Start Electron desktop app in dev mode
- `bun run dev:web` - Start dev-server and frontend concurrently (no Electron)
- `bun run test:cli` - Run CLI smoke tests
- `bun run test:cli -- <number|name>` - Run a single CLI smoke test by number or name
- `bun run test:electron` - Build and run Electron smoke tests
- `bun run everything:plan` - Print which test scripts would run and why, without running anything
- `what-changed changes` - List the files that changed since the last passing run, with their hashes
- `what-changed summary` - The same files, grouped under the targets they affect
- `what-changed targets` - Just the affected target names, one per line
- `what-changed baseline capture` - Record the current tree as the baseline without running anything (an assertion, not a check)
- `bun run find-flakey-tests` - Loop `test:everything --force` until a target number of consecutive green runs is reached (default 100), stopping at the first failure with a diagnosis report. Prints when the current run and the whole streak should finish, estimated from the most recent runs. `-- --target N` sets the streak, `-- --resume N` carries on from a previous session that banked N green runs. See [Testing](docs/testing/README.md)
- `bun run stories` - Cycle the Electron app through every UI story, capturing screenshots (long-running, excluded from `test:all`)
- `bun run stories:and` - Same stories cycle on the Android emulator/device. Renders every page at phone resolution, so this is how to check pages fit on mobile
- `bun run stories:ios` - Same stories cycle on the iOS simulator
- Story player options (pass after `--`): `--duration <ms>`, `--screenshots <dir>`, `--no-screenshots`, `--open`. Screenshots go to `stories-screenshots/<platform>/` with an `index.html` pairing light and dark. See `packages/user-interface/src/stories/README.md`
- `bun run start -- <command> [db-path]` - Run CLI commands locally (from `apps/cli`)
- `bun run perf` - Run performance benchmarks for all packages

## Architecture

- **Storage**: `packages/storage` abstracts filesystem (`fs:path`), S3-compatible (`s3:bucket:/path`), and encrypted storage.
- **Frontend**: React 18 + TypeScript, Vite, shared UI in `packages/user-interface`.
- **Mobile**: Capacitor wraps the frontend for iOS/Android. Background tasks run in an embedded JS engine (JavaScriptCore on iOS, QuickJS on Android) driven by the native `JsEngine` Capacitor plugin via a `host.*` bridge, off the WebView. Shared TypeScript lives in `packages/mobile-frontend` (the `EmbeddedJsQueueBackend`, the `JsEngine` plugin interface, the mobile platform provider) and `packages/mobile-worker` (the embedded worker runtime, host-bridge machinery, and `worker.bundle.js` build). All 30 host functions the task handlers need (storage `fs`, hashing, media tools, networking, crypto) are implemented on both platforms; the NOT IMPLEMENTED error is a safety net for any Node.js API a background task calls outside that set.
- **Desktop**: Electron embeds the frontend via `apps/desktop`.

## Guides

- [Development](docs/development.md) - The day-to-day dev loop and an index of the other guides
- [UI stories](packages/user-interface/src/stories/README.md) - The stories browser (every page/modal/dialog/component in isolation) and the cross-platform story player. Run the stories on Android/iOS to check pages fit on a phone screen
- [Testing](docs/testing/README.md) - How to run the automated tests, the manual e2e scripts, and the UI stories
- [Background tasks](docs/background-tasks.md) - How to add a new background task type (worker handler, registration, frontend consumption)
- [Mobile native media tools](docs/mobile-native-media.md) - How the bundled mobile ImageMagick/ffmpeg are wired and activated (iOS/Android)
- [Updating mobile ImageMagick/ffmpeg](docs/updating-mobile-imagemagick-ffmpeg.md) - How to update the bundled versions (see also `scripts/update-mobile-media-tools.sh`)

## Code Style
- **Types**: Use interfaces with PascalCase (`IStorage`) for types, explicit return types
- **Interface names always start with `I`** (`IStorage`, `IFileLister`, `IConfig`). This applies to every interface without exception, including ones that describe plain data and ones that describe a function. A new interface that does not start with `I` is wrong and must be renamed.
- **Naming**: camelCase for variables/methods, PascalCase for classes/interfaces
- **Imports**: Named imports for functions, default imports for modules
- **Functions**: Named functions for top-level methods, arrow functions for callbacks
- **Async**: Use async/await pattern for asynchronous code
- **Error Handling**: Try/catch blocks with specific error handling, custom error classes
- **Formatting**: 4-space indentation, braces on same line as control statements
- **Comments**: Line comments with `//` preceded by blank line, method docs above function. Use `//` comments for method docs.
- All global symbols (functions, types, interfaces, classes, constants) must have a `//` comment block above them explaining their intent.
- All fields in interfaces and classes must have a `//` comment explaining their purpose.
- Never use single-character variable names, including arrow function parameters (e.g. use `fileName => ...` not `f => ...`). Use long descriptive identifiers.
- Avoid single line if statements. All if statements should have curly brackets around the function body.
- Never put multiple statements on one line. Each statement should be on its own line.
- Use 4 space tabs for indentation.
- Put `else` and `catch` blocks on a new line.
- Tests should go under the directory src/test in each package.
- Use `test(` not `it(` in Jest test files.
- Do not write unit tests for React components, contexts, or hooks. Do not use `@testing-library/react`, `renderHook`, or any component/hook rendering in tests. A React component/context/hook must be a thin shell. Only significant logic is worth extracting and testing: if a component/context/hook contains non-trivial logic, factor that logic out into a plain function under a `lib/` directory and unit-test the plain function. Do not extract or test trivial logic (for example a one-line string or URL builder) just to gain a test; leave it inline in the component and untested.
- Refrain from using the `any` type in normal code, although it's ok sometimes in test code.
- Never use anonymous object types inline (e.g. `Promise<{ foo: number }>`). Always define a named interface instead, unless specifically asked to use an anonymous type.
- Never use IIFE async generator pattern (`(async function* () { ... })()`). Extract to a named `async function*` instead.
- Never use `ReturnType<typeof ...>`. Use the actual type directly (e.g. `NodeJS.Timeout` instead of `ReturnType<typeof setTimeout>`).
- Never use the `unknown` type. Use the actual type directly.

## Restrictions
- TypeScript code should always compile after making changes.
- All tests should pass after making changes.
- Prefer to minimize the size of code changes.
- Prefer not to update test code unless needed.
- Add new tests for new code. Every function that is new, that you edit, or that the user asks you about should have unit tests. The exception is React components, contexts, and hooks, which are not unit tested (extract any testable logic into a `lib/` function and test that instead).
- Backward compatibility is not required.
- Use imports instead of requires.
- All imports should be at the top of the file and not inside any functions.
- Don't use dynamic imports.
- Don't add exception handling unless I ask for it.
- Don't use default or optional parameter values unless specifically asked to.
- Never reformat or rewrite entire files. Only edit the specific lines that need to change.
