# android-common.sh

Shared by the `*-android.sh` scripts. It is sourced, never run, and has no arguments.

It resolves a JDK 17 and the Android SDK by sourcing the Capacitor Android app (apps/android-frontend)'s `apps/android-frontend/scripts/android-env.sh` (it exits with a message when either is missing), and defines:

- `photosphere_android_require_commands <command...>`: fails unless each command is on the PATH. `mise install` from the repository root provides the pinned `zig` and `bun`.
- `photosphere_android_ndk_version`: the NDK version the Capacitor Android app (apps/android-frontend) pins in its `app/build.gradle`. Photosphere uses that one, so the two cannot drift.
- `photosphere_android_min_sdk`: the minimum SDK level, from the shared `variables.gradle`.
- `photosphere_android_gradle <arguments...>`: runs Photosphere project's Gradle wrapper.
- `photosphere_android_version`: the version in Photosphere's `package.json`.
- `photosphere_android_abi <x86_64|arm64>`: the Android ABI directory name.
