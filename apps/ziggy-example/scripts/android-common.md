# android-common.sh

Shared by the `*-android.sh` scripts and by the smoke test platform library (`smoke-tests/lib/android.sh`). It is sourced, never run, and has no arguments.

It resolves a JDK 17 and the Android SDK by sourcing the Photosphere Android app's `apps/android-frontend/scripts/android-env.sh` (it exits with a message when either is missing), and defines:

- `ziggy_android_require_commands <command...>`: fails unless each command is on the PATH. Run the scripts through mise so `zig` and `bun` are the pinned ones.
- `ziggy_android_ndk_version`: the NDK version the Photosphere Android app pins in its `app/build.gradle`. The example uses that one, so the two cannot drift.
- `ziggy_android_min_sdk`: the minimum SDK level, from the shared `variables.gradle`.
- `ziggy_android_gradle <arguments...>`: runs the example project's Gradle wrapper.
- `ziggy_android_version`: the version in the example's `package.json`.
- `ziggy_android_abi <x86_64|arm64>`: the Android ABI directory name.
