# Development

How to set up, run, and work on Photosphere, and where to find the detailed guides.

Photosphere is a Bun-workspaces monorepo with web, desktop (Electron), mobile (iOS/Android), and CLI frontends over a shared React UI (`packages/user-interface`).

The Photosphere App (`apps/photosphere`) is the app for Windows, macOS, Linux, Android and iOS. It is built on Ziggy, an application shell that shows the shared UI in each platform's web view and runs everything else in Zig. It replaces the Electron and Capacitor apps, and the TypeScript CLI and packages that have a Zig port are replaced by the Zig ones. Everything that is replaced is marked "(deprecated)" in the project layout below. Start with [Ziggy architecture](ziggy-architecture.md) and the [Photosphere App README](../apps/photosphere/README.md).

## Project layout

- photosphere/
    - apps/
        - android-frontend (deprecated) - Capacitor Android app
        - bdb-cli (deprecated) - BSON database CLI tool (for testing and debugging)
        - cli (deprecated) - Main CLI tool (psi)
        - cli-zig - Zig port of the main CLI tool (psi)
        - desktop (deprecated) - Electron desktop application
        - desktop-frontend (deprecated) - React UI for the Electron app
        - dev-frontend (deprecated) - Development web frontend
        - dev-server (deprecated) - WebSocket development server
        - ios-frontend (deprecated) - Capacitor iOS app
        - mk-cli (deprecated) - Merkle tree CLI tool (for testing and debugging)
        - photosphere - Photosphere App: the Ziggy shells for each platform and the scripts that build and run them
        - photosphere-frontend - The web view UI of the Photosphere App
        - photosphere-smoke-tests - Smoke tests for the Photosphere App on every platform
        - smoke-tests (deprecated) - Host-driven UI smoke tests for the mobile apps
    - packages/
        - api (deprecated) - Core API for database operations
        - bdb (deprecated) - BSON database implementation
        - config (deprecated) - Shared configuration values such as the application version
        - encryption (deprecated) - Encryption primitives (AES-256-CBC + RSA hybrid, key management, streaming)
        - fuzzy-match (deprecated) - Fuzzy string matching based on Levenshtein edit distance
        - lan-share-core (deprecated) - Local-network sharing of database configs and secrets between devices: the core
        - lan-share-network (deprecated) - Local-network sharing of database configs and secrets between devices: discovery and transport
        - merkle-tree (deprecated) - Merkle tree data structure
        - mobile-frontend (deprecated) - Shared mobile TypeScript (queue backend, JsEngine plugin, platform provider)
        - mobile-worker (deprecated) - Embedded mobile worker runtime and its bundle
        - node-api (deprecated) - Node.js API for database operations
        - node-utils (deprecated) - Node.js utility functions
        - rest-api (deprecated) - REST API server (used by the desktop app to serve local photos)
        - serialization (deprecated) - Serialization utilities
        - storage (deprecated) - Storage abstraction layer
        - task-queue (deprecated) - Task queue system
        - tools (deprecated) - Tool management and media processing (ffmpeg, ffprobe, ImageMagick)
        - user-interface - Shared React UI components
        - utils (deprecated) - General utility functions
        - vault (deprecated) - Cross-platform secrets management with multiple vault backends
    - packages-zig/
        - api-zig - Zig port of api
        - bdb-zig - Zig port of bdb
        - encryption-zig - Zig port of encryption
        - fuzzy-match-zig - Zig port of fuzzy-match
        - lan-share-core-zig - Zig port of the core of lan-share
        - lan-share-network-zig - Zig port of the network side of lan-share
        - merkle-tree-zig - Zig port of merkle-tree
        - node-api-zig - Zig port of node-api
        - node-utils-zig - Zig port of node-utils
        - serialization-zig - Zig port of serialization
        - storage-zig - Zig port of storage
        - task-queue-zig - Zig port of task-queue
        - tools-zig - Zig port of tools
        - utils-zig - Zig port of utils
        - vault-zig - Zig port of vault
        - photosphere-core - The Zig library the Photosphere App shells link: Photosphere's channel handlers, task handlers and asset server, built on ziggy-core
        - ziggy-core - Ziggy's Zig library: the C interface, message dispatcher, task runner and test hooks, with no Photosphere code
    - test - Data for testing.

"(deprecated)" marks an app or package that is going to be superseded by the Zig port (the Zig packages in `packages-zig`, the Zig CLI, and the Photosphere App on Ziggy) and removed once the port fully replaces it.
## Setup

You need [Bun](https://bun.sh/docs/installation) installed. Tested against Bun v1.3.14 on Ubuntu Linux, Windows 10/11, and macOS.

Clone the repository and install all dependencies from the root of the monorepo:

```bash
git clone git@github.com:ashleydavis/photosphere.git
cd photosphere
bun install
```

Then run the one-time, per-platform environment setup:

```bash
bun run setup
```

This fans out to each package's own `setup` script (`bun --filter '*' setup`): it installs the Android SDK toolchain on Linux/macOS (`apps/android-frontend`) and the iOS CocoaPods on macOS (`apps/ios-frontend`), each skipping cleanly on a platform it does not apply to, so the command succeeds everywhere. The Android step installs a JDK 17 when none is found, which prompts once for sudo.

Install the git hooks, which stop a commit that does not compile and a push whose tests fail:

```bash
bash scripts/install-hooks.sh
```

This is once per clone and nothing does it for you, because git will not run a hook out of the repository until it is told where to look. See [Git hooks](git-hooks.md) for what each hook runs, how to bypass one, and how to check they are active.

Install the pinned toolchain (`bun`, `node`, `jq`, `what-changed`) with [mise](https://mise.jdx.dev/):

```bash
mise install
```

Everything below is run from the repo root.

## Common commands

| Command | What it does |
|---|---|
| `bun run build:ziggy:<platform>` / `bun run run:ziggy:<platform>` | Build, or build and launch, the Photosphere App on `linux`, `windows`, `macos`, `android` or `ios`. See the [Photosphere App README](../apps/photosphere/README.md) for every command and where each runs. |
| `bun run test:ziggy` / `bun run test:ziggy:and` / `bun run test:ziggy:ios` | Photosphere App smoke tests, on the host operating system, the Android emulator/device or the iOS simulator. |
| `bun run dev` (deprecated) | Start the Electron desktop app in dev mode, with hot reload. |
| `bun run dev:web` | Start the dev server and web frontend together (no Electron). |
| `bun run compile` | Compile all TypeScript. Optional, but the way to check a change still compiles. |
| `bun run test` | Unit tests. |
| `bun run test:all` | Unit tests plus the CLI and Electron smoke tests, one after another. **Covers no mobile suite**, so it can pass while the mobile app is broken. Not the full set despite the name. |
| `bun run test:everything` (or `bun run tev`) | The actual full set for your platform, all at once: compile, unit, every CLI suite (plain, encrypted, LAN share, sync, write lock, hash cache), Electron, the CLI to desktop LAN share suite, the mobile test harness, and both mobile suites. It stops the moment anything fails. This is what the git hooks run. It covers every Release workflow test job for this platform bar three: the stories runs, the packaging builds, and `perf-tests`. Only the scripts whose watched paths changed since they last passed actually run, so a docs-only change runs nothing; add `-- --force` to run everything, `-- --plan` to see the decision. Pass script names to consider only those, still in parallel. Needs the `what-changed` executable on your PATH, from [its releases page](https://github.com/ashleydavis/what-changed/releases). |
| `bun run test:everything:force` | The whole set for this platform, changed or not. The same as `-- --force`. |
| `bun run test:and` / `bun run test:ios` (deprecated) | Mobile smoke tests, on the Android emulator/device or iOS simulator. `bun run test:and <n>` runs a single test by number, `bun run test:and <name>` by name. |
| `bun run build` (deprecated) | Production build of the Electron app for distribution. |
| `bun run clean` | Remove build artifacts. |

The commands that run the app rebuild it first, so what you are running is always built from the current source.

To run the CLI, the dev-server, or the dev-frontend on their own, see [apps/cli](../apps/cli/README.md), [apps/dev-server](../apps/dev-server/README.md), and [apps/dev-frontend](../apps/dev-frontend/README.md).

## Automatic import

`psi add --watch` watches folders for new media and imports it on its own. `psi sync --watch` pushes what is there to a remote. `psi consolidate` joins a standalone database to a remote, creating it, consolidating into it, or simply recording it as the origin.

```bash
psi add --db ./photos --watch            # watch this machine's photo folders
psi add --db ./photos                    # import what is there now, then exit
psi sync --db ./photos --watch           # push to the remote as the database changes
psi consolidate --db ./photos ./backup   # join this database to a remote
```

The desktop and mobile apps do the same thing from a toggle in the settings, watching this machine's photo folders or the device's photo library. All of them run one `import-assets` task fed by a scanner that watches; only the media source underneath differs. See [Automatic photo backup](automatic-photo-backup.md) for the two import lanes, how re-importing is avoided, the retention policies and how to switch the active one, what consolidation does, and what each platform supports, and [Syncing](syncing.md) for the other half: what a sync moves, how it knows whether there is anything to do, and when each platform runs one.

## Checking how the UI looks

The [stories browser](../packages/user-interface/src/stories/README.md) mounts every page, modal, dialog, and component in isolation with mock data, so you can look at a UI surface without seeding a real database.

In the **web** build, run `bun run dev:web` and open `http://localhost:8080/#/stories`. Browse from the ☰ menu, or click **▶ Play on automatic** to cycle every story. In the **desktop** app, open it from the Developer menu; on **Android/iOS**, from the Developer screen.

On the Photosphere App, and on the deprecated Electron and Capacitor apps, the story player does it from the command line: it cycles the live app through every story in light and dark, captures a screenshot of each, and fails if a story crashes while rendering:

```bash
bun run stories:ziggy      # Photosphere App on the host operating system
bun run stories:ziggy:and  # Photosphere App on the Android emulator or attached device
bun run stories:ziggy:ios  # Photosphere App on the iOS simulator
bun run stories            # Electron desktop (deprecated)
bun run stories:and        # Capacitor Android app (deprecated)
bun run stories:ios        # Capacitor iOS app (deprecated)
```

Screenshots land in `stories-screenshots/<platform>/` with an `index.html` pairing each story's light and dark shots. **The Android and iOS runs render every page at phone resolution, so this is the way to check that pages fit on a small screen.** The same shared UI ships on every platform, so a layout that overflows on a phone is a bug in the shared UI, not a mobile-only concern.

## Testing

[docs/testing/](testing/README.md) covers the unit tests, the CLI/Electron/mobile smoke tests, the manual end-to-end scripts, and the UI stories. Add unit tests for new code. React components, contexts, and hooks are not unit tested: extract any real logic into a `lib/` function and test that.

## Platform notes

The shared UI in `packages/user-interface` must stay platform-neutral: no Electron IPC, no Capacitor, no iOS/Android specifics. Keep platform code in the relevant app (for example `apps/desktop-frontend`) and pass it into the shared UI through props or an existing platform abstraction.

The local iOS environment is pinned to macOS 12.7.6 / Xcode 14.2, which is why the Capacitor app stays on Capacitor 5 and why the Photosphere App's iOS project must build with that Xcode. Do not raise those versions.

## Guides

- [Ziggy architecture](ziggy-architecture.md) - The Photosphere App's parts, message protocol, how to add a channel or a task type, and the test hooks.
- [Photosphere App](../apps/photosphere/README.md) - Building and running the app on each platform.
- [UI stories](../packages/user-interface/src/stories/README.md) - The stories browser and the cross-platform story player.
- [Testing](testing/README.md) - Running the tests, the manual e2e scripts, and the stories.
- [Git hooks](git-hooks.md) - The local checks that run before a commit or push, and how to install them.
- [Storage paths](storage-paths.md) - What a valid `fs:` and `s3:` path looks like, and where S3 credentials and the endpoint come from.
- [Automatic photo backup](automatic-photo-backup.md) - Watching for new photos, importing them, and keeping a remote copy.
- [Syncing](syncing.md) - What a sync moves, when each platform runs one, and how it keeps working while the app is not on screen.
- [Background tasks](background-tasks.md) - Adding a new background task type.
- [Mobile background tasks](mobile-background-tasks.md) - The mobile engine pool: what a slot is, what holds one, and why running out hangs the app.
- [Delivering the Android app to testers](android-tester-distribution.md) - Getting a build to Android testers through Firebase App Distribution.
- [Setting up Photosphere on Android](android-onboarding.md) - What a user does after installing the app: automatic import, and a private encrypted remote copy to back up to.
- [Mobile native media tools](mobile-native-media.md) - How the bundled mobile ImageMagick/ffmpeg are wired up.
- [Updating mobile ImageMagick/ffmpeg](updating-mobile-imagemagick-ffmpeg.md) - Updating the bundled versions.
- [Theme override](theme-override.md) - Forcing the startup theme with `PHOTOSPHERE_THEME`.
