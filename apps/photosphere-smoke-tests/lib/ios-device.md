# ios-device.sh

The iOS platform library of Photosphere's smoke tests when a device is connected. [ios.sh](ios.md) sources it in place of its simulator functions, and it is never run on its own. It takes no arguments. It sources `apps/photosphere/scripts/lib/apple-common.sh`.

The app runs on a connected iPhone or iPad: `PHOTOSPHERE_IOS_DEVICE` names one, otherwise the first connected device is used. Xcode 14 has no command for running an app on a device, so `apps/photosphere/scripts/ios-device.ts` does it through native-run's device library: it installs the app, launches it under the device's debugserver with the test environment and `--remote-control` with the address of the scenario's remote control server. Xcode's `lldb` then takes over the launched process, and is how the run resumes it, sees it exit, stops it, and reads the files it writes in its data container.

iOS starts an app in the root directory whatever working directory it is given, so the run moves the app into its data container before the core is created, and gives the settings, vault and log directory as paths relative to it.

A device runs one copy of the app at a time, so a scenario claims the device under a lock for as long as it runs, and `photosphere_platform_device_limit` reports one.

It implements the `photosphere_platform_*` functions `common.sh` lists and the `ios_*` helpers scenarios call as `${PLATFORM}_<name>`.

## Environment

- `PHOTOSPHERE_IOS_DEVICE`: the device to use, by identifier.
- `PHOTOSPHERE_IOS_TEAM`: the Apple development team the device build is signed by, when Xcode has several.
- `PHOTOSPHERE_NEWS_URL`: passed on to the app, for the scenarios that serve a news feed.
