# sync-android.sh

Brings the Android project up to date with the core and the UI. Invoked as `bun run --filter=ziggy sync:android`.

Builds the UI (`bundle-ui.sh`) and the core as a shared library per Android ABI (`bundle-core.sh`), copies the libraries into the project's `jniLibs` and the UI into its assets, so the project is current when opened in Android Studio or built by Gradle. Takes no arguments. Runs on Linux and MacOS.
