# Android shell

The Android shell is a Java activity that hosts a `WebView` and passes messages between the page and the Zig core library. The Java is kept to the bridge only.

## What it does

- Hosts the `WebView`, injects `window.ziggy` and answers every request to the app's page address from the page embedded in the core library, so the APK holds no page files.
- Page to native goes through `addJavascriptInterface`, native to page through `evaluateJavascript` on the UI thread.
- Loads the Zig shared library through a JNI loader. The JNI entry points are written in Zig inside the core library.
- Provides what Android forces: the photo library and its permission flow (including the partial answer on Android 14 and later), file and folder pickers, export and share, secure storage, the foreground service of type `dataSync`, and network type changes. The pickers are Ziggy's `pick_paths` callback and the foreground service is its `keep_alive` callback. The rest are host requests the core makes by name, answered in `PhotosphereHostRequests.java` or the class it hands the method to (`MediaLibraryHostRequests.java`, `ExportHostRequests.java`). The core makes the decisions.
- Allows cleartext loopback to the asset server through `network_security_config.xml`.

## Project and build

A Gradle project. `sync:android` builds the UI, which the core library embeds, and the core as a shared library per ABI (`libphotosphere.so`) into `app/build/ziggy/jniLibs`, then Gradle builds the APK. The application id is `au.com.codecapers.photosphere.ziggy`. `open:android` opens the project in Android Studio. Runs on Linux and MacOS. See [Photosphere App](../../README.md).

## Icon

The launcher icons are in `app/src/main/res/mipmap-*`, named by `android:icon` and `android:roundIcon` in the manifest.
