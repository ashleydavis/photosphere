# Android shell

The Android shell is a Java activity that hosts a `WebView` and passes messages between the page and the Zig core library. The Java is kept to the bridge only.

## What it does

- Hosts the `WebView`, injects `window.ziggy` and answers every request to the app's page address from the page embedded in the core library, so the APK holds no page files.
- Page to native goes through `addJavascriptInterface`, native to page through `evaluateJavascript` on the UI thread.
- Loads the Zig shared library through a JNI loader. The JNI entry points are written in Zig inside the core library.
- Provides what Android forces: the photo library and its permission flow (including the partial answer on Android 14 and later), file and folder pickers, export and share, secure storage, the foreground service of type `dataSync`, and network type changes. Each is a host callback registered in `ziggy_create`, and the core makes the decisions.
- Allows cleartext loopback to the asset server through `network_security_config.xml`.

## Project and build

A Gradle project. `sync:android` builds the UI, which the core library embeds, and the core as a shared library per ABI (`libphotosphere.so`) into `app/build/ziggy/jniLibs`, then Gradle builds the APK. The application id is `au.com.codecapers.photosphere.ziggy`, so an install never replaces the Capacitor app. `open:android` opens the project in Android Studio. Runs on Linux and MacOS. See [Photosphere App](../../README.md).
