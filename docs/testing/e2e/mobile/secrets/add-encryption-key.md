# Mobile Manual Test: Add an Encryption Key

**Do not skip steps.** Run every step in this test, in the order it is written. An agent taking someone through this test is not authorized to skip, reorder, defer, or merge steps, or to decide a step is not worth running. Only the human can ask for that.

Test adding an encryption key to the phone's vault and using it to open an encrypted database.

## Prep

- Run from the repo root. Run the Android lines on Android and the iOS lines on iOS. The reset scripts work on an Android emulator or an iOS simulator only. On a real phone, clear the app's data by hand instead: on Android **Settings > Apps > Photosphere > Storage > Clear storage**, on iOS delete the app.
- `bun run android:reset` and `bun run ios:reset` wipe everything the app has stored (databases, settings, secrets and the photo permission) so the test starts from a fresh install. They leave the device photo library alone.
- An encryption key in PEM form. The `openssl` command below generates one in `tmp/manual-test-key.pem`. It has to be 4096-bit RSA: the CLI refuses a smaller key, because it would write files that cannot be decrypted.
- S3 is a fresh bucket on a local MinIO server on this machine, set up by `bun run start-minio`: see [MinIO for the manual tests](../../minio.md). The phone must be on the same network as this machine. Run the commands in one terminal, which the later CLI steps use too.
- Test step 3 needs an encrypted database that uses this key: `--key tmp/manual-test-key.pem --add test/test.jpg` creates one holding one photo.
- `psi dbs send` sends the database entry, `mobile-test-encrypted`, with only the S3 credentials attached, prints a pairing code and waits. On the phone, go to the **Databases** page, choose **Receive database** and enter the code. The key itself goes onto the phone in Test step 1. In Test step 3, attach `manual-test-key` to the entry (open its **⋮** menu, **Edit**, **Configure secrets…**) before opening it.

```bash
bun run android:reset   # Android
bun run android   # Android
bun run ios:reset   # iOS
bun run ios   # iOS
mkdir -p tmp
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out tmp/manual-test-key.pem
bun run start-minio -- mobile-test-encrypted --key tmp/manual-test-key.pem --add test/test.jpg
source tmp/minio/mobile-test-encrypted.env
psi dbs send --name mobile-test-encrypted --yes
```

Expected:
- The reset prints that it wiped Photosphere's data, or that the app is not installed.
- `tmp/manual-test-key.pem` holds the generated key.
- The encrypted database is created with that key and the photo is added, and the phone receives `mobile-test-encrypted`.

## Test

### 1. Add the key

1. Go to **Secrets** and add a secret of type encryption key.
2. Name it `manual-test-key` and give it the PEM.

Expected: It is saved and listed by name.

### 2. View it

1. Open the secret.

Expected:
- It is shown as an encryption key rather than as plain text.
- The value matches the PEM you generated.

### 3. Use it

1. Open an encrypted database that uses this key, as in [open-encrypted-database](../database/open-encrypted-database.md).

Expected: The database opens and its photos are readable, which is the only real proof the key was stored intact.

## Check

### 4. A malformed key

1. Add another encryption key, giving it text that is not a PEM.

Expected: The app refuses it and says why, rather than saving something that will fail later when a database needs it.

When the test is done, stop the S3 server:

```bash
bun run stop-minio -- mobile-test-encrypted
```

## Agent notes

- How to drive the app: [Driving the apps as an agent](../../agent-driving.md). Android: the agent does the UI steps with adb. iOS: the human does them, and the agent reads the results from screenshots.
- The pairing code `psi dbs send` prints is typed on the phone with `input text`.
- Step 1 needs the whole PEM in the secret's field. `input text` cannot type the line breaks in a PEM, and has not been tried with one, so pasting the PEM may need the human.
- Step 4 types text that is not a PEM with `input text`.
