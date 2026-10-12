# ios.sh

The iOS platform library of Photosphere's smoke tests. [common.sh](common.md) sources it when the platform is `ios`, and it is never run on its own. It takes no arguments. It needs MacOS with Xcode, and sources `apps/photosphere/scripts/lib/apple-common.sh` for the checks and the simulator and device helpers.

When an iPhone or iPad is connected the scenarios run on it, and [ios-device.sh](ios-device.md), which `ios.sh` sources, replaces the simulator functions. Otherwise the app runs on an iOS simulator that already exists: a running one or the first available iPhone. Nothing is created or deleted.

It implements the `photosphere_platform_*` functions `common.sh` lists, `photosphere_platform_device_limit`, and the `ios_*` helpers scenarios call as `${PLATFORM}_<name>`. A helper that has no iOS implementation stops the scenario with a message naming it (`photosphere_ios_not_available`), so a scenario that reaches one fails loudly.

A simulator process shares the host's file system and network, so the control port file, the settings, the vault and the logs are host paths inside the scenario's directory, and the control connection is reached at `127.0.0.1`. Variables named `SIMCTL_CHILD_<name>` reach the app's environment as `<name>`. The app's process is not a child of the shell, so it is recorded by its process id and stopped with `simctl`.

## Environment

- `PHOTOSPHERE_IOS_SIMULATOR`: the simulator to use, by name or identifier.
- `PHOTOSPHERE_IOS_DEVICE`: the connected device to use, when several are connected (see [ios-device.md](ios-device.md)).
- `PHOTOSPHERE_NEWS_URL`: passed on to the app, for the scenarios that serve a news feed.
