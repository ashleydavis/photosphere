# Mobile Manual Test: LAN Share, Desktop to Phone

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test the desktop app sending a database entry and a secret to the phone on the same network. The phone is the target.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- The desktop app running on a machine on the same local network, started from the repo root with the script for its platform: `bun run linux`, `bun run macos` or `bun run windows`. The block below uses `bun run linux`.
- The phone must be on Wi-Fi, not mobile data.
- The desktop needs something to send. S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). It makes the entry `desktop-share`, a copy of the `1-asset` test database, with its credentials secret `desktop-share-s3`. The `psi` lines then add an encrypted database, `desktop-share-enc`, holding one photo, encrypted with a key generated as the secret `desktop-share-key`.
- The desktop app is started in the same terminal, after the `source`, so it uses the CLI config and vault `start-minio` set up and lists those entries and secrets.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
bun run start-minio -- desktop-share --from 1-asset
source tmp/minio/desktop-share.env
psi init --db s3:photosphere-smoke-test/desktop-share-enc --key desktop-share-key --generate-key --yes
psi add --db s3:photosphere-smoke-test/desktop-share-enc --key desktop-share-key test/test.jpg --yes
psi dbs add --yes --name desktop-share-enc --path s3:photosphere-smoke-test/desktop-share-enc --s3-cred desktop-share-s3 --encryption-key desktop-share-key
bun run linux
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed, and the app starts with no database open.
- The S3 server starts, and the encrypted database is created with one photo in it.
- The desktop app starts, listing `desktop-share` and `desktop-share-enc` on its **Databases** page and `desktop-share-s3` and `desktop-share-key` on its **Secrets** page.

## Test

### 1. Receive a secret from the desktop

1. On the desktop, go to **Secrets**, share `desktop-share-s3` and note the pairing code it shows.
2. On the phone, go to **Secrets**, start receiving and enter that code.

Expected:
- The phone receives it within a few seconds.
- The secret is listed on the phone with the value it had on the desktop.

### 2. Receive a database entry from the desktop

1. On the desktop, go to **Databases**, share `desktop-share` and note the pairing code it shows.
2. On the phone, start receiving a database entry and enter that code.

Expected:
- The entry arrives and is listed on the phone.
- Opening it loads the assets, fetching them from wherever the entry points, which may be an S3 bucket rather than the desktop itself.

### 3. Receive an encrypted database and its key

1. Share the encryption key, `desktop-share-key`, from the desktop to the phone.
2. Share the encrypted database's entry, `desktop-share-enc`. On the phone's receive screen, untick **Import encryption key**, so that the phone has to use the key from step 1.
3. On the phone, attach `desktop-share-key` to the entry (open its **⋮** menu, **Edit**, **Configure secrets…**), then open it.

Expected: The photos are readable, as in [open-encrypted-database](../database/open-encrypted-database.md). This is the pair a user actually needs: an entry without its key is not usable.

### 4. Cancel on the phone

1. Start receiving on the phone with any code and cancel it. Then share from the desktop.

Expected: The phone stops waiting and the desktop's send eventually reports that nothing received it. Neither claims success.

## Check

### 5. Nothing sends

1. Start receiving on the phone with any code and leave it.

Expected: It gives up after its own timeout and says so, rather than waiting for ever.

When the test is done, quit the desktop app and stop the S3 server:

```bash
bun run stop-minio -- desktop-share
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- The desktop side is driven as in the desktop part of the guide, through a test-hooks build started with its control connection rather than `bun run linux`, with `PHOTOSPHERE_CONFIG_DIR`, `PHOTOSPHERE_VAULT_DIR` and `PHOTOSPHERE_VAULT_TYPE` taken from `tmp/minio/desktop-share.env`. The desktop shows the pairing code: read it with `get-value` on `share-pairing-code` and type it on the phone with `input text`.
