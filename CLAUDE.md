# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Rules

- When writing plans, do not add any steps for "Human Verification" or "Human Testing", plans you write should be automatically tested by unit tests and smoke tests. No human will be testing your work.
- YOU ARE RESPONSIBLE FOR THE CODE IN THIS REPO. IT DOESN'T MATTER "IF IT WAS ALREADY LIKE THAT" - YOU ARE EXPECTED TO FIX IT.
- IF YOU DON'T KNOW WHO WROTE THE CODE, IT MEANS YOU (CLAUDE) WROTE THE CODE.
- IT IS ALWAYS YOUR RESPONSIBILTY TO FIX COMPILE ERRORS AND FAILING TESTS. NEVER USE THE "PREEXISTING" EXCUSE.
- NEVER USE EM DASHES.
- Never use memory.
- All Claude configuration goes in this repository only, not in the home directory.
- Never stash code unless asked.
- Never use `cd` to permanently change directories within the repo. Use it on case-by-case and temporary basis as part of a command to run the command from a particular directory. Use of `cd` by itself will leave you in the wrong directory meaning other commands won't work.
- Never invoke shell scripts directly (e.g. `./apps/desktop/smoke-tests.sh`). Use the `bun run` equivalent from `package.json` (e.g. `bun run test:electron`, `bun run test:cli`).
- When running smoke tests, do not manually `rm -rf` the test's `tmp/` directory — the runner already cleans it before each test.
- When creating a new worktree, never use `EnterWorktree` with a `name` parameter. Instead: (1) run `git branch --show-current` to get the current branch, (2) run `git worktree add -b <new-branch> .claude/worktrees/<name> <current-branch>` to create the worktree explicitly branching from the current branch, (3) then use `EnterWorktree` with the `path` parameter to enter it.
- The commands I use to run the software always rebuild it automatically, so the running app is always built from current source. A code change that does not show up is never caused by a stale build or a missing rebuild. Never tell me to rebuild and never blame a missing change on the build being out of date. Find the real cause (a responsive breakpoint, caching, the wrong code path, a logic bug).
- Never say something was "intentionally done" unless I explicitly asked for that exact behaviour. Describing a behaviour as intentional when I never asked for it is an excuse for getting it wrong, especially when I am reporting that something does not work right. Do not decide to "intentionally" do something I did not request; if you did, you got it wrong. State plainly what the code does and own the mistake.
- Avoid an explosion of Electron IPC channels. Do not add new, action-specific IPC channels (for example a dedicated `toggle-devtools` channel). Reuse an existing channel, or use the generic `main-command` channel that dispatches named actions from the renderer to the main process. If you add new, specific IPC channels I will generally revert those changes.
- The `packages/user-interface` package is shared across all platforms (web, desktop/Electron, iOS, Android). It is not acceptable to put platform-specific code in that package: no Electron IPC or `window.electronAPI`, no Capacitor, no iOS/Android specifics. Keep platform-specific code in the relevant app/frontend (for example `apps/desktop-frontend`) and pass it into the shared UI via props or an existing platform abstraction.
- You are not to commit, stage, push, revert, or perform any other dangerous or hard-to-reverse Git operation (including `git add`, `git commit`, `git push`, `git reset`, `git restore`, `git checkout` of changes, `git rebase`, `git merge`, force-push, branch creation/deletion) without an explicit direction to do so in that message. An earlier instruction to do one of these is a one-time direction; it does not authorise repeating the operation after later edits. When in doubt, leave the Git state alone and ask.

## Project Overview

Photosphere is a self-hosted, cross-platform photo and video management application built as a monorepo using Bun workspaces. It includes web, desktop (Electron), mobile (iOS/Android), and CLI interfaces.

## Commands

### Setup
- `bun install` (from repo root) - You must do this before you can run any other scripts.

### Run from repo root:
- `bun run compile` - Compile all TypeScript
- `bun run test:all` - Run ALL tests (unit tests + all smoke tests). Use this when asked to run "all tests".
- `bun run test` - Run unit tests only
- `bun run test -- <test-name-or-pattern>` - Run a single test by name or pattern.
- `bun run clean` - Clean all build artifacts
- `bun run dev` - Start Electron desktop app in dev mode
- `bun run dev:web` - Start dev-server and frontend concurrently (no Electron)
- `bun run test:cli` - Run CLI smoke tests
- `bun run test:cli -- <number|name>` - Run a single CLI smoke test by number or name
- `bun run test:electron` - Build and run Electron smoke tests
- `bun run test:stories` - Run the long-running Electron cycle-stories smoke test (excluded from `test:all`)
- `bun run start -- <command> [db-path]` - Run CLI commands locally (from `apps/cli`)
- `bun run perf` - Run performance benchmarks for all packages

## Architecture

- **Storage**: `packages/storage` abstracts filesystem (`fs:path`), S3-compatible (`s3:bucket:/path`), and encrypted storage.
- **Frontend**: React 18 + TypeScript, Vite, shared UI in `packages/user-interface`.
- **Mobile**: Capacitor wraps the frontend for iOS/Android. Background tasks run in an embedded JS engine (JavaScriptCore on iOS, QuickJS on Android) driven by the native `JsEngine` Capacitor plugin via a `host.*` bridge, off the WebView. Shared TypeScript lives in `packages/mobile-frontend` (the `EmbeddedJsQueueBackend`, the `JsEngine` plugin interface, the mobile platform provider) and `packages/mobile-worker` (the embedded worker runtime, host-bridge machinery, and `worker.bundle.js` build). Node.js APIs are not implemented for the engine: a background task that calls one reports NOT IMPLEMENTED until a later layer supplies the native implementation.
- **Desktop**: Electron embeds the frontend via `apps/desktop`.

## Guides

- [Background tasks](docs/background-tasks.md) - How to add a new background task type (worker handler, registration, frontend consumption)
- [Mobile native media tools](docs/mobile-native-media.md) - How the bundled mobile ImageMagick/ffmpeg are wired and activated (iOS/Android)
- [Updating mobile ImageMagick/ffmpeg](docs/updating-mobile-imagemagick-ffmpeg.md) - How to update the bundled versions (see also `scripts/update-mobile-media-tools.sh`)

## Code Style
- **Types**: Use interfaces with PascalCase (`IStorage`) for types, explicit return types
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
- Add new tests for new code. Every function that is new, that you edit, or that the user asks you about should have unit tests.
- Backward compatibility is not required.
- Use imports instead of requires.
- All imports should be at the top of the file and not inside any functions.
- Don't use dynamic imports.
- Don't add exception handling unless I ask for it.
- Don't use default or optional parameter values unless specifically asked to.
- Never reformat or rewrite entire files. Only edit the specific lines that need to change.
