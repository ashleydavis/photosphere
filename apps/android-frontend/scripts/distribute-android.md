# Distributing the Android app to testers

`distribute-android.sh` builds the Android app and uploads it to Firebase App Distribution, which notifies the tester group and gives them a link to install it.

Run it from the repository root:

```
bun run dist:and
bun run dist:and --groups testers,family
```

It builds the web assets and the embedded worker bundle (`bun run sync`), then the APK through `android-gradle.sh`, which resolves a JDK 17 and the Android SDK so nothing has to be exported first. Then it uploads.

## Arguments

- `--groups <aliases>` names the tester group aliases to release to, comma separated, as they appear in the Firebase console (default: `testers`).

## What it decides for you

- **The release notes** come from `scripts/release-notes.sh`, the same script the GitHub release workflow uses, so a tester build and a release describe the same commits the same way. They are cut to the newest commits, with a final line saying how many older changes were left out, because Firebase App Distribution rejects long release notes and does it only after the whole APK has been uploaded. See [its own file](../../../scripts/release-notes.md).
- **The version** comes from `scripts/set-build-config.sh`, which versions the build the way the release workflow versions a nightly: `dev-nightly.<UTC timestamp>`. The app reports it, and it is also the version name Firebase shows, alongside a version code of minutes since the epoch so each upload's number is higher than the last. The tracked config file that carries the version is put back when the build finishes, however it finishes. See [its own file](../../../scripts/set-build-config.md).
- **The Firebase app id** is a constant near the top of the script. It says which app a build belongs to, is not a secret, and changes only if the Firebase project is recreated or the Android app is added to a different one.
- **The build is the debug APK**, the same one `bun run and` puts on the emulator, because the app has no release signing set up and an unsigned release APK installs nowhere. What that costs a tester is covered in the guide below.

## More

[Delivering the Android app to testers](../../../docs/android-tester-distribution.md) covers the Firebase project setup, what testers do on their phones, and what goes wrong.
