# setup-android.sh

One-time setup for building the example for Android. It runs the Photosphere Android app's `install-android-sdk.sh --install` (which installs the SDK packages and the pinned NDK) and then checks the JDK 17, SDK and NDK are where the build looks for them. It installs nothing of its own.

Invoke: `mise exec -- bash apps/ziggy-example/scripts/setup-android.sh`. No arguments.

Needs `zig`, `bun`, `jq` and `unzip` on the PATH.
