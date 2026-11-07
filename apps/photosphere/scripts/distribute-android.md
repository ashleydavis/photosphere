# distribute-android.sh

Builds the Photosphere App's Android APK with `package-android.sh` and uploads it to Firebase App Distribution, which notifies the tester group and gives them a link to install it. [Delivering the Android app to testers](../../../docs/android-tester-distribution.md) covers the one-time Firebase setup, what testers do on their phones and what goes wrong.

Run it from the repository root:

```
bun run distribute:ziggy:android
bun run distribute:ziggy:android -- --groups testers,family
bun run distribute:ziggy:android -- --version-name 1.2.3
```

It needs the Firebase CLI on your PATH and signed in (`curl -sL https://firebase.tools | bash`, then `firebase login`), and the Android SDK and NDK that `bun run --filter=ziggy setup` sets up.

## Arguments

- `--groups <aliases>` names the tester group aliases to release to, comma separated, as they appear in the Firebase console. The default is `testers`.
- `--project <id>` names the Firebase project. The default is the one the Photosphere apps are in.
- `--version-name <name>` is the version the build reports and Firebase shows, such as `1.2.3` for the tag `v1.2.3`. The default is the version in `apps/photosphere/package.json` followed by `-dev.` and the UTC time of the build.
- `--build-only` builds the APK and stops. It runs nothing against Firebase and needs no Firebase CLI.

## What it decides for you

- **The Firebase app** is found by the app's package name, `au.com.codecapers.photosphere.ziggy`. When the project has no app for that package the script creates one, so nothing has to be set up in the console first.
- **The build** is `package-android.sh` for arm64, the architecture of testers' phones. It is the release build, debug signed so that it installs. Android's Play Protect may show "Unsafe app blocked" until the app targets a newer Android version and is signed with a release key.
- **The version code** is minutes since the epoch, which only goes up, so a phone treats each upload as an update.
- **The release notes** come from `scripts/release-notes.sh`, cut to the newest commits because Firebase rejects long notes after the whole APK has been uploaded.
