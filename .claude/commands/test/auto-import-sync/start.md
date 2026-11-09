---
description: Reset the Android auto import and sync test and start a new run. Asks twice before deleting anything, then sets up automatic import into a partial replica on the phone that syncs to a new folder in the S3 test bucket.
---

# Start the auto import and sync test

Tests automatic import and syncing on a real Android phone: a database in an S3 bucket, a partial replica of it on the phone as the default database, automatic import into the replica and background syncing to the bucket. Check on a run with `/test:auto-import-sync:check`.

- The bucket is `photosphere-test-bucket-1`.
- Each run's database is a folder in it named `psi-test-<number>`. The current run's folder is the only `psi-test-` folder in the bucket: list the bucket's top level to find it. The new run's folder is the next number, or `psi-test-1` when there is none.
- The database entry on this machine and on the phone is named `do-test`, and the replica on the phone is named `my-photos`.

## Rules

- Touch only `photosphere-test-bucket-1`. Never list, write or delete anything in another bucket.
- Never write credentials to a file and never print them. A command that needs them takes them from the vault (`psi secrets view --name default:s3 --yes --raw`) into that one command's environment.
- Never copy files off the phone. Read file names, config files and logs with `adb shell run-as`.
- Report times in local time, never UTC.
- Do not use **Consolidate into remote**. Do not change anything on the phone that these steps do not name.
- Use `zig-out/bin/psi` from the repository root. If it is missing, build it with `bun run build:cli`.

## Find out what the reset would delete

Delete nothing yet.

1. Run `adb devices -l`. If no phone is listed, run `adb kill-server` and `adb start-server` and look again. Use its serial with `-s` in every adb command.
2. Count the device's media, so the count can be compared after the reset: `content query --uri content://media/external/images/media --projection _id` and the same for `video`, counting the rows.
3. List what the app holds on the phone: the databases in `files/databases.toml`, read with `adb shell run-as au.com.codecapers.photosphere.ziggy`.
4. List the bucket's top level to find the current `psi-test-` folder.

## Ask twice before the reset

The reset deletes data from a real device, so it needs two separate confirmations. Ask each question in its own message and wait for the answer. Anything other than a plain yes to either question stops the command, with nothing deleted.

1. Ask: "The reset uninstalls Photosphere from the phone, which deletes these databases from it: <the databases listed>. It also deletes `<current folder>` from `photosphere-test-bucket-1`. The phone's own photos are not touched. Do you want to reset?"
2. After a yes, ask: "This cannot be undone. Are you sure you want to delete those databases from the phone and `<current folder>` from the bucket?"

## Reset

1. Stop and uninstall the app: `adb shell am force-stop au.com.codecapers.photosphere.ziggy`, then `adb uninstall au.com.codecapers.photosphere.ziggy`.
2. Count the device's media again and check the count has not changed.
3. Delete the current folder, when there is one, with `aws s3 rm s3://photosphere-test-bucket-1/<current folder>/ --recursive` and the endpoint from the vault secret. List the bucket's top level and check it is gone.
4. Remove the old entry from this machine's database list: `psi dbs remove --name do-test --yes`.

## Set up the new run

1. Create the new database in the bucket and put one photo in it:
    - `psi init --db s3:photosphere-test-bucket-1/<new folder> --yes`
    - `psi dbs add --yes --name do-test --path s3:photosphere-test-bucket-1/<new folder> --s3-cred default:s3`
    - `psi add --db s3:photosphere-test-bucket-1/<new folder> <one distinctive photo> --yes`
2. Install and start the app: `bun run android -- --target <serial>`. Check `run-as au.com.codecapers.photosphere.ziggy ls files` finds no files directory, so it starts with no data.
3. Drive the phone with adb taps, taking a screenshot into the project's `tmp/` before each tap to find the control. The screen is 1080 by 2400.
    - **Receive the database.** Open the menu, **Manage Databases**, the page's **⋮**, **Receive database**. Type a four-digit code into the field. The keyboard moves **Start** up the screen, so take a screenshot before tapping it. Straight after tapping it, run `psi dbs send --name do-test --code <code> --yes`. Check the review screen shows the new path and **Import S3 credentials (default:s3)** is ticked, then press **Save** and **Close**.
    - **Replicate.** Press **⋮** on `do-test` and **Replicate**. The first tap on the menu sometimes closes it without opening the dialog: take a screenshot and tap again. Leave **File system** and **Partial**, type `my-photos` as the destination path, hide the keyboard with Back and press **Start replication**. Wait for "Replication completed", then **Close**.
    - **Set the default.** Press **⋮** on `my-photos` and **Set as default**. Check the phone's `files/config.yaml` has `default_database_path: my-photos`.
    - **Start automatic import and syncing.** Open the menu, **Configuration**. Turn on **Automatic import**, press **Allow all** for photos and **Allow** for notifications. Turn on **Enable syncing**. Check `files/config.yaml` has `auto_import` and `sync` both `enabled: true`.
4. Tell the human the run is underway: what was set up, the new folder's name, that sync passes run every five minutes and that the phone must stay on Wi-Fi.
