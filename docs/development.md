# Development

How to set up, run, and work on Photosphere, and where to find the detailed guides.

Photosphere is a Bun-workspaces monorepo with web, desktop (Electron), mobile (iOS/Android), and CLI frontends over a shared React UI (`packages/user-interface`).

## Project layout

- photosphere/
    - apps/
        - android-frontend - Capacitor Android app
        - bdb-cli - BSON database CLI tool (for testing and debugging)
        - cli - Main CLI tool (psi)
        - desktop - Electron desktop application
        - desktop-frontend - React UI for the Electron app
        - dev-frontend - Development web frontend
        - dev-server - WebSocket development server
        - ios-frontend - Capacitor iOS app
        - mk-cli - Merkle tree CLI tool (for testing and debugging)
        - smoke-tests - Host-driven UI smoke tests for the mobile apps
    - packages/
        - api - Core API for database operations
        - bdb - BSON database implementation
        - config - Shared configuration values such as the application version
        - encryption - Encryption primitives (AES-256-CBC + RSA hybrid, key management, streaming)
        - fuzzy-match - Fuzzy string matching based on Levenshtein edit distance
        - lan-share - Local-network sharing of database configs and secrets between devices
        - merkle-tree - Merkle tree data structure
        - mobile-frontend - Shared mobile TypeScript (queue backend, JsEngine plugin, platform provider)
        - mobile-worker - Embedded mobile worker runtime and its bundle
        - node-api - Node.js API for database operations
        - node-utils - Node.js utility functions
        - rest-api - REST API server (used by the desktop app to serve local photos)
        - serialization - Serialization utilities
        - storage - Storage abstraction layer
        - task-queue - Task queue system
        - tools - Tool management and media processing (ffmpeg, ffprobe, ImageMagick)
        - user-interface - Shared React UI components
        - utils - General utility functions
        - vault - Cross-platform secrets management with multiple vault backends
    - test - Data for testing.

## Setup

You need [Bun](https://bun.sh/docs/installation) installed. Tested against Bun v1.3.14 on Ubuntu Linux, Windows 10/11, and macOS.

Clone the repository and install all dependencies from the root of the monorepo:

```bash
git clone git@github.com:ashleydavis/photosphere.git
cd photosphere
bun install
```

Everything below is run from the repo root.

## Common commands

| Command | What it does |
|---|---|
| `bun run dev` | Start the Electron desktop app in dev mode, with hot reload. |
| `bun run dev:web` | Start the dev server and web frontend together (no Electron). |
| `bun run compile` | Compile all TypeScript. Optional, but the way to check a change still compiles. |
| `bun run test` | Unit tests. |
| `bun run test:all` | Unit tests plus the CLI and Electron smoke tests. |
| `bun run test:and` / `bun run test:ios` | Mobile smoke tests, on the Android emulator/device or iOS simulator. `bun run test:and <n>` runs a single test by number, `bun run test:and <name>` by name. |
| `bun run build` | Production build of the Electron app for distribution. |
| `bun run clean` | Remove build artifacts. |

The commands that run the app rebuild it first, so what you are running is always built from the current source.

To run the CLI, the dev-server, or the dev-frontend on their own, see [apps/cli](../apps/cli/README.md), [apps/dev-server](../apps/dev-server/README.md), and [apps/dev-frontend](../apps/dev-frontend/README.md).

## Checking how the UI looks

The [stories browser](../packages/user-interface/src/stories/README.md) mounts every page, modal, dialog, and component in isolation with mock data, so you can look at a UI surface without seeding a real database.

In the **web** build, run `bun run dev:web` and open `http://localhost:3000/#/stories`. Browse from the ☰ menu, or click **▶ Play on automatic** to cycle every story. In the **desktop** app, open it from the Developer menu; on **Android/iOS**, from the Developer screen.

On Electron, Android, and iOS the story player does it from the command line: it cycles the live app through every story in light and dark, captures a screenshot of each, and fails if a story crashes while rendering:

```bash
bun run stories            # Electron desktop
bun run stories:and    # Android emulator or attached device
bun run stories:ios        # iOS simulator
```

Screenshots land in `stories-screenshots/<platform>/` with an `index.html` pairing each story's light and dark shots. **The Android and iOS runs render every page at phone resolution, so this is the way to check that pages fit on a small screen.** The same shared UI ships on every platform, so a layout that overflows on a phone is a bug in the shared UI, not a mobile-only concern.

## Testing

[docs/testing/](testing/README.md) covers the unit tests, the CLI/Electron/mobile smoke tests, the manual end-to-end scripts, and the UI stories. Add unit tests for new code. React components, contexts, and hooks are not unit tested: extract any real logic into a `lib/` function and test that.

## Platform notes

The shared UI in `packages/user-interface` must stay platform-neutral: no Electron IPC, no Capacitor, no iOS/Android specifics. Keep platform code in the relevant app (for example `apps/desktop-frontend`) and pass it into the shared UI through props or an existing platform abstraction.

The local iOS environment is pinned to macOS 12.7.6 / Xcode 14.2, which is why the project stays on Capacitor 5. Do not raise those versions.

## Guides

- [UI stories](../packages/user-interface/src/stories/README.md) - The stories browser and the cross-platform story player.
- [Testing](testing/README.md) - Running the tests, the manual e2e scripts, and the stories.
- [Background tasks](background-tasks.md) - Adding a new background task type.
- [Mobile native media tools](mobile-native-media.md) - How the bundled mobile ImageMagick/ffmpeg are wired up.
- [Updating mobile ImageMagick/ffmpeg](updating-mobile-imagemagick-ffmpeg.md) - Updating the bundled versions.
- [Theme override](theme-override.md) - Forcing the startup theme with `PHOTOSPHERE_THEME`.
