# run-android.sh

Builds the debug APK for the chosen device's architecture, installs it and starts it.

Invoke: `mise exec -- bash apps/ziggy-example/scripts/run-android.sh [--target <adb serial>]`

- `--target <serial>`: the device to use (or set `ZIGGY_ANDROID_TARGET`). Without it a plugged-in device is used, else the hand-testing emulator (`psphere-single`), else a running smoke test pool emulator. A pool emulator is taken only while its device lock is free, the lock the smoke tests and the pool repair take, so a run never installs over an app a test is using, and the lock is held until the script ends. The script never starts an emulator.
