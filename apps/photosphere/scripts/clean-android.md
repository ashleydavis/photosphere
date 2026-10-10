# clean-android.sh

Runs Gradle's own `clean` in the Android project. It removes `app/build`, which includes everything `sync-android.sh` generated, so build again with `build-android.sh` or `sync-android.sh`. It also deletes the APKs in `apps/photosphere/out/android`, one file at a time.

Invoke: `bun run --filter=ziggy clean:android`. No arguments.
