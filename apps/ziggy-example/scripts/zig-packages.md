# zig-packages.sh

Builds, cross-builds or tests the Zig packages of the Ziggy example: Ziggy's core (`packages/ziggy/core`), the example's core (`apps/ziggy-example/core`, which depends on it) and the Windows shell package.

## Usage

`bash apps/ziggy-example/scripts/zig-packages.sh <build|cross|test>`

Run through the `compile:zig` and `test:zig` scripts of `apps/ziggy-example`, not directly. They are separate from the TypeScript `compile` and `test` scripts, so a change to one side never waits on the other. The root `compile:zig` and `test:zig` scripts, which `bun run test:everything` runs as lanes of their own, call them. `compile:zig` runs `build` and `cross`, and `test:zig` runs `test`.

## Arguments

- `build`: builds the example's core library for the host, which builds Ziggy's core with it.
- `cross`: builds the example's core library for every other platform's target, with and without the test hooks: MacOS and the iOS device and simulators with their oldest supported OS versions, Windows and Linux on both architectures. Then fetches the pinned WebView2 SDK if it is not there and builds the Windows shell for both Windows architectures. The Android libraries are built, with the NDK, by the Android build and smoke test (`bun run test:ziggy-example:and`), because they need the Android SDK. The Swift and Xcode parts cannot be built here and are only built on a Mac.
- `test`: runs the unit tests of Ziggy's core, the example's core and the Windows shell package and the Linux shell package (the parts of those shells that do not need Windows or GTK).
