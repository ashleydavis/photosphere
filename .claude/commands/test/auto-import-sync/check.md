---
description: Check on the Android auto import and sync test. Reports whether import and sync are still going or have finished, with the counts, what is missing and how long each took.
---

# Check the auto import and sync test

Reports on a run started with `/test:auto-import-sync:start`. Everything here only reads: change nothing on the phone, in the bucket or on this machine.

- The bucket is `photosphere-test-bucket-1`. The run's database is the only `psi-test-` folder in it: list the bucket's top level to find it.
- The replica on the phone is named `my-photos`.

## Rules

- Touch only `photosphere-test-bucket-1`. Never list or read anything in another bucket.
- Never write credentials to a file and never print them. A command that needs them takes them from the vault (`psi secrets view --name default:s3 --yes --raw`) into that one command's environment.
- Never copy files off the phone. Read file names, config files and logs with `adb shell run-as au.com.codecapers.photosphere.ziggy`.
- Report times in local time, never UTC.
- Use `zig-out/bin/psi` from the repository root. If it is missing, build it with `bun run build:cli`.

## Gather

1. Run `adb devices -l`. If no phone is listed, run `adb kill-server` and `adb start-server` and look again. Use its serial with `-s` in every adb command.
2. **On the phone.**
    - Count the device's media: `content query --uri content://media/external/images/media --projection _id` and the same for `video`, counting the rows.
    - Write the replica's asset names, from `ls files/dbs/my-photos/asset`, to the project's `tmp/`.
    - Read `files/config.yaml` to check automatic import and syncing are both still on.
    - From the newest log in `files/logs`, read the last `Import: ` lines and the last `Sync started for`, `Push completed` and `Sync timings` lines. Read the matching errors log for the files that failed to import.
3. **In the bucket.**
    - Write the names under `s3://photosphere-test-bucket-1/<folder>/asset/` to the project's `tmp/` with `aws s3 ls` and the vault credentials, and compare them with the phone's names using `comm`.
    - Run `psi summary --db s3:photosphere-test-bucket-1/<folder>` and read its whole output, not just the first lines.
    - To see what the bucket holds whatever the database records, total `aws s3 ls --recursive` by top-level folder.
4. **Timing.** From the log, take the first `Import: ` line and the last one that imported files, and the first `Sync started for` line and the last `Push completed` line that copied files.

## Decide where it is

- **Import has finished** when the last import pass imported nothing new and its "already there" and "failed" add up to the device's media count.
- **Sync has finished** when the last `Push completed` copied no files and every asset name on the phone is in the bucket.
- Otherwise it is still going. Say how far each has got, and when the last pass ran.

## Report

Give a heading saying whether the run is finished or still going, then:

- The device's media count, the number of photos imported and any that failed, with the reason from the errors log.
- How many of the phone's assets are in the bucket, and any that are missing.
- `psi summary`'s files imported, total files and size.
- How long import and sync took, or how long they have been running.
- Where sync's time went, from the `Sync timings` lines.
