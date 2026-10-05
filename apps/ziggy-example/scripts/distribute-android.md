# distribute-android.sh

Builds the example's Android app and uploads it to Firebase App Distribution, which notifies the tester group and gives them a link to install it. It is the example's version of `apps/android-frontend/scripts/distribute-android.sh`, and [Delivering the Android app to testers](../../../docs/android-tester-distribution.md) covers what testers do on their phones and what goes wrong.

Run it from the repository root:

```
bun run distribute:ziggy-example:android
bun run distribute:ziggy-example:android -- --groups testers,family
```

It needs the Firebase CLI on your PATH and signed in (`curl -sL https://firebase.tools | bash`, then `firebase login`), and the Android SDK and NDK that `bun run --filter=ziggy-example setup` sets up.

## Arguments

- `--groups <aliases>` names the tester group aliases to release to, comma separated, as they appear in the Firebase console. The default is `testers`. Groups belong to the whole Firebase project, so the example shares the Photosphere app's.
- `--project <id>` names the Firebase project. The default is the one the Photosphere apps are in.
- `--build-only` builds the APK and stops. It runs nothing against Firebase and needs no Firebase CLI.

## What it decides for you

- **The Firebase app** is found by the example's package name, `dev.ziggy.example`. When the project has no app for that package the script creates one, called "Ziggy example", so nothing has to be set up in the console first.
- **The build** is `package-android.sh` for arm64, the architecture of testers' phones. It is the release build, debug signed so that it installs. What that costs a tester is the same as for the Photosphere build: Android's Play Protect may show "Unsafe app blocked" until the app targets a newer Android version and is signed with a release key.
- **The version** is the version in `apps/ziggy-example/package.json` followed by `-dev.` and the UTC time of the build, so a tester can say which build they have. The version code beside it is minutes since the epoch, which only goes up, so a phone treats each upload as an update.
- **The release notes** come from `scripts/release-notes.sh`, cut to the newest commits because Firebase rejects long notes after the whole APK has been uploaded.
