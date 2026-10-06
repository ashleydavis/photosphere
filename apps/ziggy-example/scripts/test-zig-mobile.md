# test-zig-mobile.sh

Runs the unit tests of Ziggy's core (`packages/ziggy/core`) and the example's core (`apps/ziggy-example/core`) on a phone platform. The test program is built for the platform with the `test-binary` step of each package's `build.zig`, which installs it under `zig-out/test-bin` without running it, and is then run on the emulator or simulator, because this machine cannot run it. The script exits non-zero when either program fails.

## Usage

`bun run --filter=ziggy-example test:zig:android` or `bun run --filter=ziggy-example test:zig:ios`, which run `bash apps/ziggy-example/scripts/test-zig-mobile.sh <android|ios>`.

## Arguments

- `android`: claims a device the way the example's Android smoke tests do (the device named in `PHOTOSPHERE_ANDROID_DEVICES`, else a pool emulator, else a plugged-in device), builds the programs for that device's architecture against the NDK's libc, pushes each to `/data/local/tmp` and runs it there. The NDK comes from `ANDROID_HOME`, the version `apps/android-frontend` pins. A run on a CI emulator names it with `PHOTOSPHERE_ANDROID_DEVICES=emulator-5554`.
- `ios`: builds the programs for the iOS simulator (`aarch64-ios.14.0-simulator`) and runs each with `xcrun simctl spawn` on the booted simulator. A simulator must already be booted, and the script fails when none is. It needs a Mac, so it is only run by the Ziggy example workflow.

Both start by building the page (`bun run bundle:ui`), because the example's core embeds it.
