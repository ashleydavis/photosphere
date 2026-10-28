# Development

How to set up, run, and work on Photosphere, and where to find the detailed guides.

Photosphere is a Bun-workspaces monorepo holding the Photosphere App for desktop and mobile, the `psi` CLI, and the shared React UI (`packages/user-interface`) the app shows.

The Photosphere App (`apps/photosphere`) is the app for Windows, macOS, Linux, Android and iOS. It is built on [Ziggy](https://github.com/ashleydavis/ziggy), an application framework in its own repository that shows the shared UI in each platform's web view and runs everything else in Zig. The TypeScript CLI and packages that have a Zig port are replaced by the Zig ones. Everything that is replaced is marked "(deprecated)" in the project layout below. Start with [Ziggy architecture](https://github.com/ashleydavis/ziggy/blob/main/docs/architecture.md), [Photosphere on Ziggy](photosphere-on-ziggy.md) and the [Photosphere App README](../apps/photosphere/README.md).

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
        - photosphere - Photosphere App: the Ziggy native apps for each platform and the scripts that build and run them
        - photosphere-frontend - The frontend of the Photosphere App
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
    - packages-zig/ - The Zig packages, built and tested by the `build.zig` at the root of the repository
        - api-zig - Zig port of api
        - bdb-zig - Zig port of bdb
        - config-zig - Zig port of config (the version and build metadata)
        - encryption-zig - Zig port of encryption
        - fuzzy-match-zig - Zig port of fuzzy-match
        - lan-share-core-zig - Zig port of the core of lan-share
        - lan-share-network-zig - Zig port of the network side of lan-share
        - mcp-zig - The MCP server (JSON-RPC protocol, tool input schemas and the Streamable HTTP transport) that the `psi mcp` command and the desktop app both run
        - mobile-worker-zig - The planning task handlers the phone runs
        - media-tools-zig - ImageMagick and FFmpeg (with their libjpeg, libpng, libwebp and zlib delegates), built from source and called in process by both the Photosphere App and the Zig CLI
        - merkle-tree-zig - Zig port of merkle-tree
        - node-api-zig - Zig port of node-api
        - node-utils-zig - Zig port of node-utils (also the HTTP server glue the asset server runs on). The helpers Ziggy's task queue shares with it are exported from Ziggy (see [Photosphere on Ziggy](photosphere-on-ziggy.md))
        - rest-api-zig - Zig port of rest-api (the asset server)
        - serialization-zig - Zig port of serialization
        - storage-zig - Zig port of storage
        - tools-zig - Zig port of tools
        - utils-zig - Zig port of utils. The helpers Ziggy's task queue shares with it are exported from Ziggy (see [Photosphere on Ziggy](photosphere-on-ziggy.md))
        - vault-zig - Zig port of vault
        - photosphere-core - The Zig library the Photosphere App's native apps link: Photosphere's message handler, task handlers and asset server, built on Ziggy's core (`@import("ziggy")`, from the `ziggy` dependency in `build.zig.zon`)
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

This fans out to each package's own `setup` script (`bun --filter '*' setup`), which for the Photosphere App installs the Android SDK and NDK on Linux and macOS, checks Xcode on macOS, and fetches the WebView2 SDK and the WiX Toolset and installs Microsoft's C++ toolchain on Windows, each skipping cleanly on a platform it does not apply to, so the command succeeds everywhere. The Android step installs a JDK 17 when none is found, which prompts once for sudo. See the [Photosphere App README](../apps/photosphere/README.md).

Install the git hooks, which stop a commit that does not compile and a push whose tests fail:

```bash
bash scripts/install-hooks.sh
```

This is once per clone and nothing does it for you, because git will not run a hook out of the repository until it is told where to look. See [Git hooks](git-hooks.md) for what each hook runs, how to bypass one, and how to check they are active.

Install the pinned toolchain (`bun`, `node`, `jq`, `what-changed`) with [mise](https://mise.jdx.dev/):

```bash
mise install
```

The Photosphere App and the Zig CLI need no ImageMagick or ffmpeg installed, because both are built into them. The tests still do: the smoke test scripts and some unit test helpers run installed `magick`, `ffmpeg` and `ffprobe` to make and check fixtures, so a developer machine that runs the tests needs ImageMagick and FFmpeg installed and on the PATH.

Everything below is run from the repo root.

## Common commands

| Command | What it does |
|---|---|
| `bun run build:ziggy:<platform>` / `bun run <platform>` | Build, or build and launch, the Photosphere App on `linux`, `windows`, `macos`, `android` or `ios`. See the [Photosphere App README](../apps/photosphere/README.md) for every command and where each runs. |
| `zig build` / `zig build test` | Build the Zig CLI (`zig-out/bin/psi`), or run every Zig test: the packages in `packages-zig` and the CLI. Both are steps of the one `build.zig` at the root of the repository, which also has `photosphere-backend`, `photosphere-linux` and `photosphere-windows`; `zig build --help` lists them. `bun run test:zig` runs the tests. |
| `bun run test:ziggy` / `bun run test:ziggy:and` / `bun run test:ziggy:ios` | Photosphere App smoke tests, on the host operating system, the Android emulator/device or the iOS simulator/device. `PHOTOSPHERE_SMOKE_SCENARIO=<number or name>` runs one scenario. |
| `bun run compile` | Compile all TypeScript. Optional, but the way to check a change still compiles. |
| `bun run test` | Unit tests. |
| `bun run test:everything` (or `bun run tev`) | The full set for your platform, all at once: compile, unit, the Zig tests, every CLI suite, and every Photosphere App suite this platform can run. It stops the moment anything fails. This is what the git hooks run. It covers every Release workflow test job for this platform bar three: the stories runs, the packaging builds, and `perf-tests`. Only the scripts whose watched paths changed since they last passed actually run, so a docs-only change runs nothing; add `-- --force` to run everything, `-- --plan` to see the decision. Pass script names to consider only those, still in parallel. Needs the `what-changed` executable on your PATH, from [its releases page](https://github.com/ashleydavis/what-changed/releases). |
| `bun run test:everything:force` | The whole set for this platform, changed or not. The same as `-- --force`. |
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

In the **desktop** app, open it from the Developer menu; on **Android/iOS**, from the Developer screen.

On the Photosphere App, the story player does it from the command line: it cycles the live app through every story in light and dark, captures a screenshot of each, and fails if a story crashes while rendering:

```bash
bun run stories:ziggy      # Photosphere App on the host operating system
bun run stories:ziggy:and  # Photosphere App on the Android emulator or attached device
bun run stories:ziggy:ios  # Photosphere App on the iOS simulator
```

Screenshots land in `stories-screenshots/<platform>/` with an `index.html` pairing each story's light and dark shots. **The Android and iOS runs render every page at phone resolution, so this is the way to check that pages fit on a small screen.** The same shared UI ships on every platform, so a layout that overflows on a phone is a bug in the shared UI, not a mobile-only concern.

## Testing

[docs/testing/](testing/README.md) covers the unit tests, the CLI and Photosphere App smoke tests, the manual end-to-end scripts, and the UI stories. Add unit tests for new code. React components, contexts, and hooks are not unit tested: extract any real logic into a `lib/` function and test that.

## Platform notes

The shared UI in `packages/user-interface` must stay platform-neutral: no `window.ziggy`, no native app code, no iOS/Android specifics. Keep platform code in the platform layer (`apps/photosphere-frontend`) or the native apps, and pass it into the shared UI through props or an existing platform abstraction. See [Photosphere on Ziggy](photosphere-on-ziggy.md).

The local iOS environment is pinned to macOS 12.7.6 / Xcode 14.2, which is why the Photosphere App's iOS project must build with that Xcode. Do not raise those versions.

## Guides

- [Ziggy architecture](https://github.com/ashleydavis/ziggy/blob/main/docs/architecture.md) - Ziggy's parts, message protocol, how to add a message type, a task type or a native host callback, and the test hooks.
- [Photosphere on Ziggy](photosphere-on-ziggy.md) - How Photosphere takes Ziggy, how to move to a released one, and how Photosphere is built on it.
- [Photosphere App](../apps/photosphere/README.md) - Building and running the app on each platform.
- [UI stories](../packages/user-interface/src/stories/README.md) - The stories browser and the cross-platform story player.
- [Testing](testing/README.md) - Running the tests, the manual e2e scripts, and the stories.
- [Git hooks](git-hooks.md) - The local checks that run before a commit or push, and how to install them.
- [Storage paths](storage-paths.md) - What a valid `fs:` and `s3:` path looks like, and where S3 credentials and the endpoint come from.
- [Automatic photo backup](automatic-photo-backup.md) - Watching for new photos, importing them, and keeping a remote copy.
- [Syncing](syncing.md) - What a sync moves, when each platform runs one, and how it keeps working while the app is not on screen.
- [Tasks](tasks.md) - Adding a new background task type.
- [Releasing](releasing.md) - The release workflow for each platform, the tag that starts each one and the GitHub release it creates.
- [Workflows](workflows.md) - The jobs of the CI and release workflows, what each one needs and where each one gets its input and puts its output.
- [Delivering the Android app to testers](android-tester-distribution.md) - Getting a Photosphere App build to Android testers through Firebase App Distribution, with `bun run distribute:ziggy:android`.
- [Setting up Photosphere on Android](android-onboarding.md) - What a user does after installing the app: automatic import, and a private encrypted remote copy to back up to.
- [Mobile native media tools](mobile-native-media.md) - How the bundled mobile ImageMagick/ffmpeg are wired up.
- [Updating mobile ImageMagick/ffmpeg](updating-mobile-imagemagick-ffmpeg.md) - Updating the bundled versions.
- [Theme override](theme-override.md) - Forcing the startup theme with `PHOTOSPHERE_THEME`.
