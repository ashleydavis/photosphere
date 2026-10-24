# Android native app

The Android native app is a Java activity that runs a `WebView` and passes messages between the page and the Zig core library. The Java is kept to the bridge only.

## What it does

- Runs the `WebView`, injects `window.ziggy` and serves every request to the app's page address from the page embedded in the core library, so the APK holds no page files.
- Page to native goes through `addJavascriptInterface`, native to page through `evaluateJavascript` on the UI thread.
- Loads the Zig shared library through a JNI loader. The JNI entry points are written in Zig inside the core library.
- Provides what Android forces: the photo library and its permission flow (including the partial grant on Android 14 and later), file and folder pickers, export and share, secure storage, the foreground service of type `dataSync`, and network type changes. The pickers are Ziggy's `pick_paths` callback and the foreground service is its `keep_alive` callback. The rest are native calls the core makes by name, handled in `PhotosphereNativeCalls.java` or the class it hands the method to (`MediaLibraryNativeCalls.java`, `ExportNativeCalls.java`). The core makes the decisions.
- Allows cleartext loopback to the asset server through `network_security_config.xml`.

## Project and build

A Gradle project. `sync:android` builds the frontend, which the core library embeds, and the core as a shared library per ABI (`libphotosphere.so`) into `app/build/ziggy/jniLibs`, then Gradle builds the APK. The application id is `au.com.codecapers.photosphere.ziggy`. `open:android` opens the project in Android Studio. Runs on Linux and MacOS. See [Photosphere App](../../README.md).

## Icon

The launcher icons are in `app/src/main/res/mipmap-*`, named by `android:icon` and `android:roundIcon` in the manifest.
