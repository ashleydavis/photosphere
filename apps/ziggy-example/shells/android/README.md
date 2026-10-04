# Ziggy example, Android shell

The example's Android project: one activity (`MainActivity`) that hosts a web view run by Ziggy's Android shell (`packages-android/ziggy-shell-android`). Package `dev.ziggy.example`. The SDK levels, library versions, plugin version and NDK are the Photosphere Android app's (`apps/android-frontend/android`), read from its files, so they cannot drift.

What is packaged:

- The Zig core library `libziggy_example.so` per architecture (`arm64-v8a` and `x86_64`), with the JNI entry points in Zig.
- The built page as `assets/ui`, loaded from `file:///android_asset/ui/index.html`.
- `ziggy-inject.js` as an asset, which the shell injects into the page.

All of it is generated into `app/build/ziggy` by `scripts/sync-android.sh`; see `scripts/*-android.md` for the setup, sync, build, run, open, package and clean scripts. Run them through mise.

The debug build has the INTERNET permission (in `app/src/debug`), because a test hooks build opens its control connection on the loopback address and Android refuses an app any socket without it. The release build has no such permission.

Smoke tests: `mise exec -- bash apps/ziggy-example/smoke-tests/run.sh android`, on a pool emulator or a plugged-in device, claimed under the repository's device lock.

The example's file and folder pickers (`pick-files`, `pick-folder`, `pick-file`) use the system document pickers through Ziggy's Android shell, which describes them: opened files are copied into the app's cache directory and answered as file system paths, while a chosen folder or a save location is answered as a `content://` Uri, which is not a file system path. `MainActivity` forwards `onActivityResult` to the shell.
