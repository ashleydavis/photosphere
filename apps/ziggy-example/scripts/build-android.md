# build-android.sh

Runs `sync-android.sh`, then `gradlew assembleDebug`. The APK is `shells/android/app/build/outputs/apk/debug/app-debug.apk`.

Invoke: `mise exec -- bash apps/ziggy-example/scripts/build-android.sh [--arch "<list>"] [--optimize <mode>] [--test-hooks]`

The options are passed to `sync-android.sh`, which describes them.
