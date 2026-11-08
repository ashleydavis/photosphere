# require-wifi-default-network.sh

Fails, naming what it found, unless an Android device's default network is Wi-Fi (or Ethernet).

The Photosphere App refuses an automatic sync while "Only sync over Wi-Fi" is on (the default) and the WebView reports the connection as cellular (`packages/api/src/lib/sync-gate.ts`). The WebView takes the connection type from the device's default network, and an emulator has a virtual cellular radio beside its virtual Wi-Fi, so an emulator whose default network is cellular makes every scenario that waits for a sync time out without saying why. This turns that into a loud failure.

It only reads `adb shell dumpsys connectivity`. It never turns a radio on or off, so it is safe to run against a pool emulator.

## Usage

```
bash scripts/android/require-wifi-default-network.sh <adb-serial> <wait-seconds>
```

- `<adb-serial>`: the device to read, as `adb devices` lists it, for example `emulator-5554`.
- `<wait-seconds>`: how long to keep reading, once a second, for the default network to become Wi-Fi. `0` reads once.

`ANDROID_HOME` must name the Android SDK; adb is taken from its `platform-tools`.

## Exit codes

- `0`: the default network is Wi-Fi or Ethernet.
- `1`: it is anything else (cellular, or no default network), or adb did not answer, or the arguments were wrong.
- `2`: dumpsys did not name the default network's transports in a form the script knows. The lines of the dump that mention the default network are printed.

## Who calls it

- The smoke tests' `require_wifi_for_sync` (`apps/photosphere-smoke-tests/lib/common.sh`), with a wait of `0`, before a scenario that waits for a sync starts the app.
- The Release Android workflow, with a wait of 120 seconds, after it switches the CI emulator's mobile data off and its Wi-Fi on and before it runs `bun run test:ziggy:and`.
