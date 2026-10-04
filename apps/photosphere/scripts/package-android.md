# package-android.sh

Runs `sync-android.sh`, then builds the APK to distribute with Gradle. Invoked as `bun run --filter=ziggy package:android`.

Leaves the APK in the Android output folder, named `photosphere-<version>-android.apk`. This is the file sent to testers through Firebase App Distribution. Takes no arguments. Runs on Linux and MacOS.
