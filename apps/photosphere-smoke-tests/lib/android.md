# android.sh

The Android platform library of Photosphere's smoke tests. [common.sh](common.md) sources it when the platform is `android`, and it is never run on its own. It takes no arguments.

It implements the `photosphere_platform_*` functions `common.sh` lists, `photosphere_platform_device_limit` (how many devices scenarios can run on at once), and the `android_*` helpers scenarios call as `${PLATFORM}_<name>`: seeding databases, config files and the photo library, granting and refusing permissions, sending the app to the background, and reading what it wrote.

The app runs on an emulator or device, driven from the host with `adb`. The build is a debug-type APK, so `run-as` can read the control port file and the log the app writes, and its Zig library has the test hooks. A phone passes no environment to an app, so the settings the desktop sets through `PHOTOSPHERE_*` variables go in as string Intent extras of the same names, which the activity puts into the process environment before the core is created; only a debuggable build honours them. A stream started on the host copies the app's log file into the scenario's `app.log` as the core writes it.

The device is the one named in `PHOTOSPHERE_ANDROID_DEVICES`, else a pool emulator, else a plugged-in device. A scenario claims it under the per-device lock the pool repair also takes, for as long as the scenario's shell runs, so two scenarios never share a device. It also takes the lock Ziggy's own Android suites claim a device under (`ziggy-android-device-<serial>.lock` in the temporary directory), so a Ziggy run beside it never puts its test app in front of this one. It sources `apps/photosphere/scripts/android-common.sh` for the JDK, the SDK and the build helpers, and the emulator pool's configuration for the AVD prefix and the lock path.

## Environment

- `PHOTOSPHERE_ANDROID_DEVICES`: space-separated serials of the devices to run on, in place of the pool.
- `PHOTOSPHERE_DEVICE_CLAIM_TIMEOUT`: seconds a scenario waits for a free device before giving up. The default is 1800.
- `PHOTOSPHERE_ALLOW_DEVICE_WIPE=1`: allow the scenarios to wipe the app's data on a real phone. Without it they refuse, because a phone may hold an imported library. An emulator is always wiped.
- `PHOTOSPHERE_ANDROID_TEST_HOST`: the address the device uses to reach this host, in place of the one worked out from the LAN bridge or the emulator's network.
- `PHOTOSPHERE_NO_LAN_BRIDGE=1`: the run has no LAN bridge, so nothing waits for a bridge address and every device counts as able to reach the host.
- `PHOTOSPHERE_NEWS_URL`: passed on to the app, for the scenarios that serve a news feed.
