# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Rules

- Never stash code or use Git without permission.

## Project Overview

Photosphere is a self-hosted, cross-platform photo and video management application built as a monorepo using Bun workspaces. It includes web, desktop (Electron), mobile (iOS/Android), and CLI interfaces.

## Commands

### Root (run from repo root):
- `bun run compile` - Compile all TypeScript
- `bun run test` - Run all tests
- `bun run clean` - Clean all build artifacts
- `bun run dev` - Start Electron desktop app in dev mode
- `bun run dev:web` - Start dev-server and frontend concurrently (no Electron)
- `bun run test:cli` - Run CLI smoke tests
- `bun run test:electron` - Build and run Electron smoke tests

### CLI (in apps/cli/):
- `bun run start -- <command> [db-path]` - Run CLI commands locally
- `bun run test` (alias: `t`) - Run tests

### Running a single test:
- Jest: `cd apps/cli && bun run test -- path/to/test.test.ts`
- Playwright: `cd apps/dev-frontend && bun run test-e2e path/to/test.test.ts`

## Architecture

- **Storage**: `packages/storage` abstracts filesystem (`fs:path`), S3-compatible (`s3:bucket:/path`), and encrypted storage.
- **Frontend**: React 18 + TypeScript, Vite, shared UI in `packages/user-interface`.
- **Mobile**: Capacitor wraps the frontend for iOS/Android.
- **Desktop**: Electron embeds the frontend via `apps/desktop`.

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
