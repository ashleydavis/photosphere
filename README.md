# Photosphere

Photosphere is a cross-platform application for managing your database of digital media files (photos and videos). I like to think of it as the spiritual successor to [Picasa](https://en.wikipedia.org/wiki/Picasa) but with a UI more like modern Google Photos and backed by a Git-style database for immutable binary assets like photos and videos that have editable metadata.

Important features:
- Build a corruption resistant database of your digital media files.
- Backup your database and keep your backup updated.
- Bidirectional synchronization between devices.
- Detect and repair corrupt files.
- Securely encrypt files that you store in the cloud.
- Use the UI to search, view and edit your photos and videos.

Photosphere is a local-first application available as:
- A CLI tool (build and manage databases from the command line).
- A desktop application (Electron-based app for Windows, macOS, and Linux).
- A mobile application (Android and iOS apps).

Note: The self-hosted server option has been discontinued for now, but may be reinstated later if there's demand for it.

Contained herein are the code for Photosphere's:
- Dev-server (for faster dev outside Electron)
- Dev-frontend (for faster dev outside Electron)
- CLI tool
- Desktop app (Electron)
- Desktop frontend (React UI for Electron)
- Android and iOS apps

Early development of Photosphere was covered in the book [The Feedback-Driven Developer](https://www.manning.com/books/the-feedback-driven-developer).

See the [wiki](https://github.com/ashleydavis/photosphere/wiki) for installation and getting started.

## Ingesting assets

Use the CLI tool `psi add` to scan a directory and do bulk uploads. Use `psi summary` to view database statistics, `psi verify` to check integrity, `psi replicate` to create backups, `psi sync` to synchronize databases between devices, and `psi compare` to verify backup consistency.

To move assets from Google Photos:
- Use Google Takeout to export all your assets to a series of large zip files.
- Then use `psi add` on the directory containing the zip files (it can unpack zip files for you).

## Project layout

- photosphere/
    - apps/
        - bdb-cli - BSON database CLI tool
        - cli - Main CLI tool (psi)
        - desktop - Electron desktop application
        - desktop-frontend - React UI for Electron app
        - dev-frontend - Development web frontend
        - dev-server - WebSocket development server
        - mk-cli - Merkle tree CLI tool
    - packages/
        - api - Core API for media file database operations
        - bdb - BSON database implementation
        - debug-server - Debug server utilities
        - defs - Type definitions
        - electron-defs - Electron-specific type definitions
        - merkle-tree - Merkle tree data structure
        - node-utils - Node.js utility functions
        - rest-api - REST API server
        - serialization - Serialization utilities
        - storage - Storage abstraction layer
        - task-queue - Task queue system
        - tools - Development tools
        - user-interface - Shared React UI components
        - utils - General utility functions
    - test - Data for testing.

## Running Photosphere locally for development

### Pre-reqs

You need [Bun](https://bun.sh/docs/installation) installed to run this code. Tested against Bun v1.3.3 on Ubuntu Linux, Windows 10/11 and MacOS.

### Setup

First, clone a local copy of the code repository:

```bash
git clone git@github.com:ashleydavis/photosphere.git
```

Then install all dependencies at the root of the monorepo:

```bash
cd photosphere
bun install
```

### Compile the project

THIS STEP IS OPTIONAL

You don't have to compile the project before doing a build. You only should do this step if you change the code and want to make sure the TypeScript code still compiles after your change.

```bash
bun run compile
```

### Running tests

You can run tests for all packages and apps from the root of the monorepo:

**Run all tests**

```bash
bun run test
```

**Run tests in watch mode**

```bash
bun run test:watch
```

**Run smoke tests for the Electron app**

```bash
bun run test:smoke
```

This will build the Electron app and run Playwright smoke tests.

**Run tests using the shell script**

Using the shell script doesn't run the tests in parallel and that makes it easier to see where a failure originates.


```bash
./run-tests.sh
```

This script runs all tests across the monorepo and provides a summary of results.

### Building and running the Electron app

You can build and run the Electron desktop application directly from the root of the monorepo:

**Development mode:**
```bash
bun run dev
```

This will bundle the renderer process and start the Electron app in development mode with hot reload.

**Production build:**
```bash
bun run build
```

This will bundle the renderer process and build the Electron app for distribution.

### Other instructions

To run the CLI tool, follow the instructions in [./apps/cli/README.md](./apps/cli/README.md).

To start the dev-server, follow the instructions in [./apps/dev-server/README.md](./apps/dev-server/README.md).

To start the dev-frontend, follow the instructions in [./apps/dev-frontend/README.md](./apps/dev-frontend/README.md).


