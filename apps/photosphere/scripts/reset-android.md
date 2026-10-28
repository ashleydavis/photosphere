# reset-android.sh

Wipes everything Photosphere has stored on an Android emulator (its storage, settings, keystore entries and permissions), so the next `bun run android` starts from a fresh install. The app stays installed. The device photo library is not touched.

It works on an emulator only. It refuses any device whose adb serial does not start with `emulator-` or whose kernel does not report itself as QEMU (`ro.kernel.qemu`), and without `--target` it refuses to run while a real device is attached, because `bun run android` would then run on that device rather than on the emulator it wiped.

Invoke: `bun run android:reset` from the repository root, or `bun run --filter=ziggy android:reset -- [--target <adb serial>]`.

- `--target <serial>`: the emulator to wipe (or set `PHOTOSPHERE_ANDROID_TARGET`). Without it the emulator is picked the way [run-android](run-android.md) picks one: the hand-testing emulator (`psphere-single`), else a smoke test pool emulator whose device lock is free. Name the same target for both scripts when you name one at all.

A pool emulator's device lock is held while it is wiped, so a test that is using it is left alone. An app that is not installed is reported and left alone.
