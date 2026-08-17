# Mobile End-to-End Tests

Manual test scripts for the Photosphere mobile app on Android and iOS.

## Structure

- [auto-import/](auto-import/) - Tests covering automatic photo backup from the device photo library
- [import/](import/) - Tests covering importing photos and videos chosen by hand
- [gallery/](gallery/) - Tests covering viewing photos, editing their details and exporting them
- [download/](download/) - Tests covering downloading assets onto the device
- [database/](database/) - Tests covering creating, opening and inspecting databases
- [move/](move/) - Tests covering moving photos between databases
- [sync/](sync/) - Tests covering syncing with another copy of a database
- [replication/](replication/) - Tests covering replicating a database elsewhere
- [s3/](s3/) - Tests covering databases held in an S3 bucket
- [secrets/](secrets/) - Tests covering managing secrets in the app vault
- [lan-share/](lan-share/) - Tests covering receiving a database or a secret over the LAN
- [news/](news/) - Tests covering the news notifications

## Prerequisites

Run the app from source on a connected device or emulator:

```bash
bun run and    # Android
bun run ios    # iOS
```

Both commands rebuild before they launch, so the app you are testing is always built from the current source.

For Android, `bun run emu:and:status` says whether an emulator is attached. A physical device needs USB debugging on and `adb devices` should list it.

Where a test needs the CLI to check what the app did, run the CLI from `apps/cli/` on the development machine, against a database the app has shared or replicated to it. The mobile app's own storage is not reachable from the host filesystem.

## What is different about mobile

- **The photo library is the source.** Automatic import reads the device photo library rather than watched folders, so the mobile tests seed photos with the device camera or by copying them onto the device, not by writing to a directory the app watches.
- **Permissions are real.** The photo permission is granted or refused through the system dialog, and refusing it is a case worth testing because the app has to say so rather than sit there doing nothing.
- **Background work runs in a fixed number of engine slots.** A task that cannot get a slot waits, and the symptom is a screen that never updates rather than an error. See [Mobile background tasks](../../../mobile-background-tasks.md) if something appears to hang.
