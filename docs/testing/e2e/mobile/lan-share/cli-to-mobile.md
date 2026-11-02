# Mobile Manual Test: LAN Share, CLI to Phone

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test the `psi` CLI sending a database entry and a secret to the phone on the same network. The phone is the target.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- The CLI on a machine on the same local network, run from the repo root, with the CLI on the PATH. Run the commands in one terminal, which the steps use too.
- The phone must be on Wi-Fi, not mobile data.
- The CLI gets its own config and vault, holding a secret to send, `manual-test-secret`, and a database entry to send, `mobile-test-db`. In the steps, `<secret name>` is `manual-test-secret` and `<database name>` is `mobile-test-db`.
- S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). The phone must be on the same network as this machine. Run the commands in one terminal, which the later CLI steps use too.
- So that opening the entry on the phone can load its assets, the database is a copy of the `1-asset` test database (`--from 1-asset`).

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
bun run start-minio -- mobile-test-db --from 1-asset
source tmp/minio/mobile-test-db.env
psi secrets add --yes --name manual-test-secret --type plain --value hello123
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- `zig build` completes and `psi` is on the PATH.
- The S3 server starts, the replication completes, and both secrets and the entry are added.

## Test

### 1. Receive a secret from the CLI

1. Choose a 4-digit pairing code. The sender sets the code and the phone is given it, so the phone shows none of its own.
2. On the machine:

   ```bash
   psi secrets send --name <secret name> --yes --code <pairing code>
   ```

3. While it waits, on the phone go to **Secrets**, start receiving and enter the same code.

Expected:
- The CLI reports that it found a device and sent the secret.
- The phone lists the secret with the value it had on the machine.

### 2. Receive a database entry from the CLI

1. Choose a new 4-digit pairing code.
2. On the machine:

   ```bash
   psi dbs send --name <database name> --yes --code <pairing code>
   ```

3. While it waits, on the phone go to **Databases**, choose **Receive database** and enter the same code.

Expected:
- The entry arrives and is listed on the phone.
- Opening it loads the assets.

### 3. The CLI cannot find the phone

1. Put the phone on mobile data, or on a different network from the machine.
2. Start receiving on the phone and send from the CLI.

Expected: The CLI says no device was found within its window. It does not report success, and the phone does not show a half-finished transfer.

### 4. The wrong code

1. Start receiving on the phone (**Secrets**, **⋮**, **Receive secret**) and enter one 4-digit code.
2. Send from the CLI with a different code.

Expected: The CLI says a device was found but is using a different code, rather than sending the secret to a device that could not prove it had the code.

## Check

### 5. Check what arrived is what was sent

For a secret, compare it against the machine's copy:

```bash
psi secrets view --name <secret name>
```

Expected: The value on the phone matches character for character. A secret that arrives truncated or re-encoded fails later, when a database will not open, and is much harder to trace from there.

When the test is done, stop the S3 server:

```bash
bun run stop-minio -- mobile-test-db
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- The phone shows no pairing code: it asks for the one the sender uses. Start the `psi ... send --code` command in the background, then type the same code on the phone with `input text`.
- Step 3 needs the phone off the machine's network. On an emulator that means changing its network, which the agent has no tested way to do, so the human does it.
