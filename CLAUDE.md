# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Photosphere is a self-hosted, cross-platform photo and video management application built as a monorepo using Bun workspaces. It includes web, desktop (Electron), mobile (iOS/Android), and CLI interfaces.

## Commands

### Monorepo-wide commands (run from root):
- `bun run compile` (alias: `bun run c`) - Compile all TypeScript across the monorepo
- `bun run test` (alias: `bun run t`) - Run all tests
- `bun run test:watch` (alias: `bun run tw`) - Run tests in watch mode
- `bun run clean` - Clean all build artifacts

### Backend development (in apps/backend/):
- `bun run start:dev` - Start with sample data (multi-set)
- `bun run start:dev-50-assets` - Start with 50 test assets
- `bun run start:dev-no-assets` - Start with empty database
- `bun run test` - Run backend tests
- `bun run compile:watch` - Watch mode compilation

### Frontend development (in apps/frontend/):
- `bun run start` - Start dev server on port 8080
- `bun run build` - Build production bundle
- `bun run test-e2e` - Run Playwright E2E tests
- `bun run test-e2e:debug` - Debug E2E tests with Playwright UI

### CLI tool (in apps/cli/):
- `bun run start -- <command> [db-path]` - Run CLI commands locally
- `bun run build-linux/win/mac` - Build standalone executables

### Running a single test:
- Backend: `cd apps/backend && bun test path/to/test.test.ts`
- Frontend E2E: `cd apps/frontend && bun run test-e2e path/to/test.test.ts`

## Architecture

### Storage Architecture
The application uses a flexible storage abstraction layer (`packages/storage`) that supports:
- **Filesystem storage**: `fs:path/to/directory`
- **S3-compatible storage**: `s3:bucket-name:/path`
- **Encrypted storage**: Wraps other storage types

Storage is divided into:
- **Asset Storage** (`ASSET_STORAGE_CONNECTION`): Stores photos/videos in collections
- **Database Storage** (`DB_STORAGE_CONNECTION`): Stores user records and metadata

### Asset Database (ADB)
Located in `packages/adb`, implements a content-addressable storage system with:
- Merkle tree-based indexing for efficient syncing
- BSON format for metadata storage
- Support for multiple asset types (original, display, thumbnail)
- Collection-based organization

### Authentication
Supports two modes via `AUTH_TYPE` environment variable:
- `auth0`: Full Auth0 integration with JWT tokens
- `no-auth`: Development mode without authentication

### Frontend Architecture
- React 18 with TypeScript
- Vite for bundling and development
- React Router for navigation
- Shared UI components in `packages/user-interface`
- Context providers for state management (scan context, gallery source context)

### Mobile/Desktop Apps
- Mobile apps use Capacitor to wrap the React frontend
- Electron app embeds the React frontend
- Both share the same frontend codebase with platform-specific wrappers

### Key Environment Variables
Backend:
- `PORT` (default: 3000)
- `AUTH_TYPE` (auth0, no-auth)
- `APP_MODE` (readonly, readwrite)
- `ASSET_STORAGE_CONNECTION`
- `DB_STORAGE_CONNECTION`

Frontend:
- `VITE_BASE_URL` - Backend API URL
- `VITE_AUTH0_REDIRECT_URL` - Auth0 callback URL

### Testing Infrastructure
- Jest for unit tests (configured per package)
- Playwright for E2E tests (frontend)
- Test fixtures in `/test/fixtures/` with various asset configurations
- HTTP test files (`.http`) for REST API testing with VS Code REST Client extension

## Code Style
- **Types**: Use interfaces with PascalCase (`IStorage`) for types, explicit return types
- **Naming**: camelCase for variables/methods, PascalCase for classes/interfaces
- **Imports**: Named imports for functions, default imports for modules
- **Functions**: Named functions for top-level methods, arrow functions for callbacks
- **Async**: Use async/await pattern for asynchronous code
- **Error Handling**: Try/catch blocks with specific error handling, custom error classes
- **Formatting**: 4-space indentation, braces on same line as control statements
- **Comments**: Line comments with `//` preceded by blank line, method docs above function
- Avoid single line if statements. All if statements should have curly brackets around the function body.
- Use 4 space tabs for indentation.

## Restrictions
- TypeScript code should always compile after making changes.
- All tests should pass after making changes.
- Prefer to minimized the size of code changes.
- Prefer not to update test code unless needed.
- Add new tests for new code.
- Backward compatibility is not required.

