# Delivering the Android app to testers

Tester builds of the Android app go out through [Firebase App Distribution](https://firebase.google.com/docs/app-distribution). It takes an APK, emails the testers you have added, and installs onto their phones through the Firebase App Tester app. There is no store listing and no review, so a tester has the build a couple of minutes after the upload finishes. It is free on Firebase's Spark plan.

This covers Android only. iOS distribution is not set up.

## One-time setup

### The Firebase project

Firebase signs in with a Google account, so there is no separate account to create. Use the Google account that should own the project long term. In the [Firebase console](https://console.firebase.google.com):

1. Create a project called Photosphere. Google Analytics is not needed. Leaving it on does nothing here either way, since the app does not include the Analytics SDK.
2. Add an Android app to it: the gear next to Project Overview > Project settings > General > Your apps > Add app > Android. The platform icons on the project overview page open the same wizard when they are there.
3. Give it the package name `au.com.codecapers.photosphere`, which is the `applicationId` in `apps/android-frontend/android/app/build.gradle` and has to match exactly. The nickname is free text and the debug signing certificate SHA-1 is left blank.
4. Skip the `google-services.json` download and the SDK and verification steps the wizard offers. App Distribution needs none of them, and the CLI upload needs nothing inside the app.
5. Open App Distribution and click Get started, which turns the API on for the project. Reach it from the search box at the top of the console, or from All products at the bottom of the left nav: the console's nav sections get renamed often, so search for the product by name rather than looking for a particular heading.
6. On the Testers & Groups tab, create a group named Testers and check the alias it generates is `testers`, because the alias is what the upload command names. Add tester email addresses to it, including your own.
The app id that says which app a build belongs to is baked into `apps/android-frontend/scripts/distribute-android.sh`, so nothing more is needed here. If the Firebase project is ever recreated, or the Android app is added to a different one, take the new app id from Project settings > General > Your apps and update that script.

### The Firebase CLI

```bash
curl -sL https://firebase.tools | bash
firebase login
```

The installer asks for sudo, because it puts the `firebase` binary in `/usr/local/bin`. `firebase login` then opens a browser and asks which Google account to use: pick the one that owns the project. What the login stores is per-user and outside the repository.

### The build toolchain

The build needs a JDK 17 and the Android SDK, the same as every other Android command here. The distribute script resolves both itself, so nothing has to be exported. `apps/android-frontend/README.md` covers installing them if either is missing.

## Deploying a new version

One command from the repository root:

```bash
bun run dist:and
```

That builds the web assets, the embedded worker bundle and the APK, then uploads it to App Distribution for the `testers` group. Testers get an email the first time and a notification in App Tester after that.

The release notes are generated, not written by hand: `scripts/release-notes.sh` lists the commits made since the last release tag as bullets, and the GitHub release workflow generates its notes with the same script, so a tester build and a release describe the same commits the same way. The tester build's notes are cut to the newest commits and say how many older changes were left out, because Firebase rejects long release notes. `scripts/release-notes.md` covers what it does.

Use `--groups` to release to something other than the `testers` group, naming group aliases as they appear in the Firebase console, comma separated for more than one:

```bash
bun run dist:and --groups testers,family
```

## What this build is, and what it costs

The script builds the debug APK, the same one `bun run and` puts on the emulator, because the app has no release signing set up. It installs and runs, so testing works, with these consequences:

- Android's Play Protect shows "Unsafe app blocked" on install. On a recent phone the reason given is that the app "was built for an older version of Android and doesn't include the latest privacy protections", which is about `targetSdkVersion` in `apps/android-frontend/android/variables.gradle`, currently 33, and not about the signing. A debug-signed build can draw the warning on its own too. Some phones offer **More details** and then **Install anyway**. Others offer only **OK**, and the build cannot be installed until Play Protect's app scanning is turned off in the Play Store (profile icon > Play Protect > settings).
- The app is debuggable and unoptimised, so it is bigger and slower than a release build would be.

Getting past both means signing release builds: a release keystore created with `keytool`, and a `signingConfig` in `android/app/build.gradle` reading the keystore path and passwords from a file kept out of git. That is a change to the build, not a step in this doc, and it is not done.

## How the build is versioned

The build is versioned the way the release workflow versions a nightly: `dev-nightly.<UTC timestamp>`, written into `packages/config/src/index.ts` by `scripts/set-build-config.sh` before the build, so the app reports it. The same string is the version name Firebase shows, and the version code beside it is minutes since the epoch, so every upload's number is higher than the one before and a phone treats the new build as an update rather than a reinstall.

That tracked config file says `dev` in the repository and is put back to `dev` when the build finishes, whether it succeeded or failed. If you ever find it stamped with a version, a distribute run was killed outright.

## Adding a tester

In the Firebase console, on App Distribution's Testers & Groups tab, open the `testers` group and add their email address. Anything they can receive mail at works, and it does not have to be a Gmail address.

They are invited by email as soon as they are added. If they open App Tester and find nothing to install, run `bun run dist:and`: a release sent to the group they are in always reaches them.

To stop sending builds to someone, remove them from the group. The builds they already installed stay on their phone.

## What a tester does

The first time:

1. They get an invitation email from Firebase App Distribution and tap Get started in it.
2. That downloads `app-tester.apk`. They tap the downloaded file to install it, and Android refuses with "your phone currently isn't allowed to install unknown apps from this source", naming whatever app did the download, their browser or their files app. They tap Settings on that prompt and turn on "Allow from this source", which brings up the install itself, so they tap Install and then Open. That prompt is Android's, and there is no way around it for a build that does not come from the Play Store.
3. They open App Tester, which shows no releases until they sign in with the Google account the invitation was sent to. They open Photosphere in it, tick the checkbox and tap "Start testing on this device", then tap Download on the release. Installing that build brings the same unknown-apps prompt again, this time naming App Tester: Settings, "Allow from this source", then "Install this app?" and Install.

After that each new build arrives as a notification in App Tester and they tap to install.

There is also a browser route, where a tester opens a release link on the phone, signs in and downloads the APK without App Tester. It has not been tried for this project, and it gives them no notification when a build goes out, so they would need a fresh link every time.

A tester who already has a Photosphere build signed with a different key, such as one sideloaded over adb from another machine or from a checkout with a different debug keystore, has to uninstall it first. Android refuses an update whose signature does not match, and the refusal does not always say so: on a phone plugged in over USB it is plain (`adb install` reports `INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match`), but through App Tester it can surface as Play Protect's "Unsafe app blocked" with no explanation of the real cause.

`adb shell dumpsys package au.com.codecapers.photosphere` says whether a build is already installed and which version it is, which is worth checking before believing any other explanation.

## When something goes wrong

| Symptom | Cause and fix |
| --- | --- |
| `the Firebase CLI is not on your PATH` | Install it, then run `firebase login`. |
| The upload is rejected as an app that does not exist | The app id baked into the distribute script belongs to another Firebase project, or the Android app was never added to this one. |
| `Failed to authenticate` | The login has expired or is for the wrong account. Run `firebase login` again. |
| A tester sees no new build | The group you released to is not the group they are in. Check Testers & Groups in the console. |
| "Unsafe app blocked" on the tester's phone | Play Protect, usually objecting to the app's `targetSdkVersion`. Tap **More details** then **Install anyway** if the dialog offers them. If the only option is **OK**, turn off app scanning in the Play Store (profile icon > Play Protect > settings) and install again. |
| `App not installed` on the tester's phone | They have an older build signed with a different key. Uninstall it, then install again. |
