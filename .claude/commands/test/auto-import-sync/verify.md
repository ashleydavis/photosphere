---
description: Verify a finished Android auto import and sync test. Lists every asset imported on the mobile in a CSV, confirms each one in the remote database, runs a full verify of the local and remote databases and compares them.
---

# Verify the auto import and sync test

Checks the result of a run started with `/test:auto-import-sync:start`, once import and sync have finished.

- The bucket is `photosphere-test-bucket-1`. The run's folder is the only `psi-test-` folder in it: list the bucket's top level to find it. In the commands below, `<run>` is that folder's name, such as `psi-test-7`.
- The remote database is `s3:photosphere-test-bucket-1/<run>`.
- The local database is the replica named `my-photos` on the mobile. Its copy on this machine is `tmp/auto-import-sync-verify/<run>-<time>/my-photos`, where `<time>` is the local time the copy is made, as `YYYYMMDD-HHMMSS`. Every run of this command makes a new folder: the mobile drops originals once the remote holds them, so a copy written over an older one would keep originals the mobile no longer has.
- The CSV is `docs/testing/auto-import-sync/<run>-assets.csv`.

## Rules

- Touch only `photosphere-test-bucket-1`. Never list, read or write anything in another bucket.
- Never write credentials to a file and never print them. A command that needs them takes them from the vault (`psi secrets view --name default:s3 --yes --raw`) into that one command's environment.
- Change nothing on the mobile and nothing in the bucket. Everything here only reads from them.
- The one thing copied off the mobile is the `my-photos` replica, in step 2, because the local verify and the CSV need the database on this machine. It is copied with `adb exec-out run-as` and written under the project's `tmp/` only.
- Report times in local time, never UTC.
- Use `zig-out/bin/psi` from the repository root. If it is missing, build it with `bun run build:cli`.
- Start every long command (the copy and both verifies) as a background command and read its result when it finishes. A foreground command is killed after ten minutes.

## Check the run has finished

1. Run `adb devices -l`. If no mobile is listed, run `adb kill-server` and `adb start-server` and look again. Use its serial with `-s` in every adb command.
2. Decide whether import and sync have finished, the way `/test:auto-import-sync:check` does.
    - Import has finished when the last import pass imported nothing new and its "already there" and "failed" add up to the device's media count.
    - Sync has finished when the last `Push completed` copied no files and every asset ID in the mobile's `thumb` folder (see step 1) is in the bucket's `asset/` folder.
3. When either is still going, say how far each has got in two lines and end the command. A copy taken while they run is not a consistent database, so nothing below would mean anything.

## 1. Count what is on the mobile

Read the names in `files/dbs/my-photos/thumb` and in `files/dbs/my-photos/asset` with `adb shell run-as au.com.codecapers.photosphere.ziggy ls` and count each.

- Every asset in the local database has a thumbnail on the mobile, so the names in `thumb` are the IDs of every asset in it.
- The names in `asset` are the originals still on the mobile. There are usually fewer: once the remote holds an original, the retention policy may drop the local copy, so an asset can have no original on the mobile and still be in the database.

Keep both counts: step 2 checks the copy against them.

## 2. Copy the local database

From the repository root:

```bash
mkdir -p tmp/auto-import-sync-verify/<run>-<time>
adb -s <serial> exec-out run-as au.com.codecapers.photosphere.ziggy tar -c -C files/dbs my-photos | tar -x --warning=no-timestamp -C tmp/auto-import-sync-verify/<run>-<time>
```

Check both halves of the pipe exited 0, and that the copy's `thumb` and `asset` folders hold the same number of files as step 1 counted. When they do not, say so and end the command.

Use the same `<time>` in every command below. The copy stays where it is when the command ends.

## 3. Write the CSV

Write `docs/testing/auto-import-sync/<run>-assets.csv`, creating the directory when it is missing. It has one row per asset ID in `tmp/auto-import-sync-verify/<run>-<time>/my-photos/thumb`, sorted by asset ID, and a header row naming these columns in this order:

`asset_id, hash, original_file_name, original_path, content_type, width, height, original_on_mobile, size_bytes, file_date, photo_date, upload_date, remote_check, remote_hash`

- Each row is read from the local database with `psi debug record <asset id> --db tmp/auto-import-sync-verify/<run>-<time>/my-photos --yes --all`. Its output starts with a few lines of text and then the record as JSON: take everything from the first line that starts with `{`, and read the fields with `jq`.
- `asset_id` is `_id`, `hash` is `hash`, `original_file_name` is `origFileName`, `original_path` is `origPath`, `content_type` is `contentType`, and `width`, `height`, `file_date`, `photo_date` and `upload_date` are `width`, `height`, `fileDate`, `photoDate` and `uploadDate`.
- `original_on_mobile` is `yes` when the copy has `asset/<asset id>` and `no` when it does not. `size_bytes` is that file's size, `stat -c %s tmp/auto-import-sync-verify/<run>-<time>/my-photos/asset/<asset id>`, and is empty when the original is not on the mobile.
- `remote_check` and `remote_hash` are left empty until step 4.
- The CSV is checked in, so it must not hold a path with a user name: in `original_path`, replace a leading `/home/<user>` or `/Users/<user>` with `~` (in `jq`, `sub("^/(home|Users)/[^/]+"; "~")`). The photo the run starts with was added from this machine and has such a path.
- Leave out the coordinates, the EXIF properties and the labels: they are personal and make the file large.
- Build each row with `jq -r '[...] | @csv'` so every value is quoted and a comma or quote in a file name cannot break a row. Run the records eight at a time (`xargs -P 8`), since one record takes under half a second and there are thousands.

## 4. Check every row against the remote database

For every row, read the asset's record from the remote database with `psi debug record <asset id> --db s3:photosphere-test-bucket-1/<run> --yes --all`, run eight at a time, and take the `hash` field the same way as in step 3.

- A missing record prints `Record not found.` and still exits 0, so decide from the output: the remote has the record only when the output has a line that starts with `{`.
- Set `remote_hash` to the hash the remote database holds for the asset. Leave it empty when the remote has no record of that ID.
- Set `remote_check` to `✓` only when the remote has the record and its hash equals the row's `hash`. Leave it empty otherwise, which covers a missing record and a different hash.

Rewrite the CSV with both columns filled in. Count the rows with a `✓` and the rows without.

## 5. Verify the local database

`psi verify --db tmp/auto-import-sync-verify/<run>-<time>/my-photos --full --yes`

The local database is a partial replica: its metadata is complete but originals it did not import, such as the one photo the run started with, are not on the mobile. Report exactly what verify says, including any such files, and do not explain a failure away.

## 6. Verify the remote database

`psi verify --db s3:photosphere-test-bucket-1/<run> --full --yes`

## 7. Compare the two databases

`psi compare --db tmp/auto-import-sync-verify/<run>-<time>/my-photos --dest s3:photosphere-test-bucket-1/<run> --yes`

Leave out `--full`: it lists every difference, which can be thousands of lines. Without it compare prints the totals first, such as `Found differences: 2046 files only in source`, and lists only the first ten of each kind.

## Report

A short summary, nothing more:

- The CSV's path.
- How many assets are confirmed in the remote and how many are not.
- Whether the verify of the local database passed or failed, and the same for the remote, with the failure when there is one.
- Whether the compare says the two databases are the same or different, and what differs when they are different.
