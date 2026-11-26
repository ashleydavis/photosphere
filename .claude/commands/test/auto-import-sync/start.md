---
description: Reset the Android auto import and sync test and start a new run. Asks whether to run it automatically or manually, asks twice before deleting anything, then sets up automatic import into a partial replica on the mobile that syncs to a new folder in the S3 test bucket.
---

# Start the auto import and sync test

Tests automatic import and syncing on a real Android mobile: a database in an S3 bucket, a partial replica of it on the mobile as the default database, automatic import into the replica and background syncing to the bucket. Check on a run with `/test:auto-import-sync:check`.

- The bucket is `photosphere-test-bucket-1`.
- Each run's database is a folder in it named `psi-test-<number>`. The current run's folder is the only `psi-test-` folder in the bucket: list the bucket's top level to find it. The new run's folder is the next number, or `psi-test-1` when there is none.
- The database entry on this machine and on the mobile is named `do-test`, and the replica on the mobile is named `my-photos`.

## Rules

- Touch only `photosphere-test-bucket-1`. Never list, write or delete anything in another bucket.
- Never write credentials to a file and never print them. A command that needs them takes them from the vault (`psi secrets view --name default:s3 --yes --raw`) into that one command's environment.
- Never copy files off the mobile. Read file names, config files and logs with `adb shell run-as`.
- Report times in local time, never UTC.
- Do not use **Consolidate into remote**. Do not change anything on the mobile that these steps do not name.
- Use `zig-out/bin/psi` from the repository root. If it is missing, build it with `bun run build:cli`.

## Ask how to run it

Before anything else, ask with the question tool (`AskUserQuestion`), offering two options: **Automatic** and **Manual**, each with a one-line description of what it does. Wait for the answer.

- **Automatic**: you do every step below, including driving the mobile with adb taps.
- **Manual**: you do every step on this machine and the bucket: finding what the reset deletes, asking before the reset, the reset, creating the new database and installing the app. The steps on the mobile in **Set up the new run** step 3 are the human's, so they experience the test. Walk them through those steps one at a time, as described under **Walking the human through the mobile steps**.

## Find out what the reset would delete

Delete nothing yet.

1. Run `adb devices -l`. If no mobile is listed, run `adb kill-server` and `adb start-server` and look again. Use its serial with `-s` in every adb command.
2. Count the device's media, so the count can be compared after the reset: `content query --uri content://media/external/images/media --projection _id` and the same for `video`, counting the rows.
3. List what the app holds on the mobile: the databases in `files/databases.toml`, read with `adb shell run-as au.com.codecapers.photosphere.ziggy`.
4. List the bucket's top level to find the current `psi-test-` folder.

## Ask twice before the reset

The reset deletes data from a real device, so it needs two separate confirmations. Ask each question with the question tool (`AskUserQuestion`), one call per question, offering **Yes** and **No**, and wait for the answer. Anything other than **Yes** to either question stops the command, with nothing deleted.

1. Ask: "The reset uninstalls Photosphere from the mobile, which deletes these databases from it: <the databases listed>. It also deletes `<current folder>` from `photosphere-test-bucket-1`. The mobile's own photos are not touched. Do you want to reset?"
2. After a yes, ask: "This cannot be undone. Are you sure you want to delete those databases from the mobile and `<current folder>` from the bucket?"

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
3. Set up the app on the mobile. In automatic mode, drive the mobile with adb taps, taking a screenshot into the project's `tmp/` before each tap to find the control. The screen is 1080 by 2400. Menus, drawers and sheets slide in, so take a second screenshot when the first shows one moving, and tap only once it has settled. In manual mode, walk the human through these steps instead.
    - **Receive the database.** Open the menu, **Manage Databases**, the page's **⋮**, **Receive database**. Type a four-digit code into the field. The keyboard moves **Start** up the screen, so take a screenshot before tapping it. Straight after tapping it, run `psi dbs send --name do-test --code <code> --yes`. Check the review screen shows the new path and **Import S3 credentials (default:s3)** is ticked, then press **Save** and **Close**.
    - **Replicate.** Press **⋮** on `do-test` and **Replicate**. The first tap on the menu sometimes closes it without opening the dialog: take a screenshot and tap again. Leave **File system** and **Partial**, type `my-photos` as the destination path, hide the keyboard with Back and press **Start replication**. Wait for "Replication completed", then **Close**.
    - **Set the default.** Press **⋮** on `my-photos` and **Set as default**. Check the mobile's `files/config.toml` has `default_database_path = "my-photos"` under `[auto_import]`.
    - **Start automatic import and syncing.** Open the menu, **Configuration**. Turn on **Automatic import**, press **Allow all** for photos and **Allow** for notifications. Turn on **Enable syncing**. Check `files/config.toml` has the `[auto_import]` and `[sync]` tables, each with `enabled = true`.
    - **Open the database.** Open the menu, **Open database**, **my-photos**, so the gallery shows the photos as automatic import adds them. Import and syncing run whether it is open or not.
4. Tell the human the run is underway: what was set up, the new folder's name, that sync passes run every five minutes and that the mobile must stay on Wi-Fi.

## Walking the human through the mobile steps

In manual mode, give one step per message: what to tap or type on the mobile and what they should see afterwards. Then stop and wait for them to say it is done. Never list later steps or preview them.

- A step is one action or a short run of taps on one screen, such as "Open the menu and tap **Manage Databases**".
- Number the steps, starting at 1, and open each message with the step's number in bold, such as "**Step 3:**".
- After each step, check it took effect before giving the next one: read `files/config.toml` or `files/databases.toml` with `adb shell run-as`, or take a screenshot into the project's `tmp/` and look at it. When the check fails, say what you see and give the step again.
- **Receive the database** needs both sides at once. Pick the four-digit code yourself and give it to the human. Ask them to type it in and press **Start**, then say done. When they do, run `psi dbs send --name do-test --code <code> --yes` straight away. Then give them the next step: check the review screen and press **Save** and **Close**.
- Use the control names exactly as the app shows them, in bold.
- End every step with the short replies the human can give: `d` (done: give the next step) and `s` (show: give the current step again, unchanged).
