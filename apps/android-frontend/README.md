# android-frontend

The Android Photosphere mobile app: a React frontend wrapped as a native Android app with [Capacitor](https://capacitorjs.com/) 5.

The frontend lives in `src/` and is built with [Vite](https://vitejs.dev/). The generated native Android project lives in `android/`, and the built web assets are copied into it during sync.

> This package uses Capacitor 5 (not 6, 7, or 8) due to the current macOS toolchain limitation. Do not upgrade the `@capacitor/*` packages past the `^5.x` line.

## Pre reqs

- [Bun](https://bun.sh).
- For Android: [Android Studio](https://developer.android.com/studio) (includes the Android SDK and a device emulator).
- JDK 17. AGP fails on JDK 21; set `JAVA_HOME` to a JDK 17 (`bun run test:and:unit` will also auto-detect one).
- Android NDK `25.1.8937393`. Builds the native ImageMagick shim; install it from Android Studio's SDK Manager or with `sdkmanager "ndk;25.1.8937393"`.

## Setup

Install dependencies from the repository root (this is a Bun workspace):

```bash
bun install
```

## Build and sync the web assets into the native project

```bash
cd apps/android-frontend
bun run sync
```

This builds the frontend and copies the latest web assets into the native `android/` project.

## Android

You need [Android Studio](https://developer.android.com/studio) installed for this.

Open the project in Android Studio:

```bash
cd apps/android-frontend
bun run open
```

Once Android Studio has opened:
- Hit the Run button to run the app on the Android emulator; or
- Connect an Android device and hit Run (you may first need to enable developer mode on the device).

Run on Android directly from the terminal:

```bash
cd apps/android-frontend
bun run run
```

Or from the repo root: `bun run run:and`, or its alias `bun run and`.

### Running with a test database

A freshly installed app has no database in it, and there is no way to open one from the host. To get something to look at, pass a fixture: the run copies one of the checked-in databases from `test/dbs/` into the app's storage.

```bash
bun run and50   # 50 assets
bun run and1    # 1 asset
bun run and0    # an empty database
```

(`run:and:50`, `run:and:1` and `run:and:0` are the long names for the same thing.)

The app opens the database itself. Once, per device: **Databases** page, menu, **Add database**, and give it the fixture's name (`50-assets`, `1-asset` or `no-assets`) as the path. Adding auto-opens it, and the entry is remembered from then on, so later runs just refresh the data underneath it.

Any other directory under `test/dbs/` works too, by name: `bun run --filter=android-frontend run 1-video`.

This works on a physical device as well as an emulator. The database goes over `adb push` and `run-as`, which need only a debuggable build, and the debug APK is one. Plug the phone in with USB debugging authorised and it is chosen as the target like any other device.
