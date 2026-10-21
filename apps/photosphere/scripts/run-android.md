# run-android.sh

Builds the debug APK for the chosen device's architecture, installs it and starts it.

Invoke: `bun run --filter=ziggy android -- [--target <adb serial>] [fixture]`, or from the repository root `bun run run:ziggy:android:50`, `run:ziggy:android:1` or `run:ziggy:android:0`.

- `--target <serial>`: the device to use (or set `PHOTOSPHERE_ANDROID_TARGET`). Without it a plugged-in device is used, else the hand-testing emulator (`psphere-single`), else a running smoke test pool emulator. A pool emulator is taken only while its device lock is free, the lock the smoke tests and the pool repair take, so a run never installs over an app a test is using, and the lock is held until the script ends. The script never starts an emulator.
- `[fixture]`: a test database to put on the device: `50`, `1` or `0` for `50-assets`, `1-asset` and `no-assets`, or the name of any directory under `test/dbs`. It is copied into the app's files directory, registered in the app's `databases.toml` as `test-<name>` by `write-fixture-databases-config.ts`, and made the database the app opens on launch. The copy is unpacked over any copy an earlier run left, so a file the app added to that copy since stays there.
