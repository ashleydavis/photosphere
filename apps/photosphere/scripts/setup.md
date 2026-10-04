# setup.sh

Runs the one-time environment setup for the platform it is on. Invoked as `bun run --filter=ziggy setup`, and by the root `bun run setup`, which fans out to every package's `setup` script.

Runs `setup-android.sh` where the Android build is possible (Linux and MacOS) and `setup-ios.sh` on MacOS, and skips each cleanly where it does not apply. Takes no arguments. Runs on any platform.
