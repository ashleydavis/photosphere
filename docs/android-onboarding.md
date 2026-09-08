# Setting up Photosphere on Android

What to do after the app is installed on an Android phone, to get every photo the phone takes imported on its own and backed up into a remote copy in your own cloud storage. Installing the app is covered by [Delivering the Android app to testers](android-tester-distribution.md); this picks up from the first launch.

At the end of it: photos arrive in the app without anybody importing them, and they reach the bucket without anybody pressing sync.

## What you need before you start

- **The app installed on the phone**, and the phone on Wi-Fi. Automatic syncing refuses a cellular connection unless you turn that restriction off, and a phone on mobile data will sit there doing nothing.
- **A bucket.** S3, or any S3-compatible service such as DigitalOcean Spaces, with its endpoint, region, access key id and secret access key.
- **A computer with the Photosphere CLI**, on the same Wi-Fi network as the phone. The phone cannot create a database in a bucket, and typing an access key on a phone keyboard is the slowest thing in this guide, so the computer does both and hands the result over the local network.

Commands are written as `psi`. From a source checkout, run them from `apps/cli/` as `bun run start -- <command>` instead.

## Which pathway you are on

| Where you are starting | Pathway |
|---|---|
| No remote database yet. | [A: make the phone's database, then make the remote to match it](#pathway-a-no-remote-database-yet) |
| A database already in a bucket. | [B: replicate the existing remote down onto the phone](#pathway-b-a-database-that-already-exists) |

Both end with one database in two places: the same identity on the phone and in the bucket, with the bucket recorded as the phone's origin, and background syncing keeping them level.

They differ in which side is made first, and that decides which way the photos move. In A the phone's database comes first and the remote is created empty to match it, so everything travels up, incrementally, in the background. In B the remote already holds photos, so the phone takes a copy of it first and travels down.

## Pathway A: no remote database yet

### A1. Make the phone's database

1. On the phone, open the menu (the hamburger, top left) and choose **Manage Databases**.
2. Press **New database**.
3. **Name**: whatever you want to see in the app. **Type**: `File system`. **Path**: a short name such as `my-photos`. It is created inside the app's own private storage; there is nothing on the phone's filesystem to browse to, and **Browse** on Android is a text prompt rather than a folder chooser.
4. Leave **Encrypted** off. Android already encrypts the device, and encrypting the local copy as well costs the phone work on every photo it imports.
5. Press **Create**.
6. Back on **Manage Databases**, press the **⋮** on it and choose **Set as default**.

**Set as default** is what makes automatic import write into this database. Without it, switching automatic import on makes a database of its own called **My Photos** and imports into that instead, and you end up with two.

### A2. Read its database id

The remote has to be created carrying this same id. Two databases can only sync when they are the same database, and the id in the merkle tree is what says they are.

**The app does not display the database id anywhere today.** It is not in the database summary, not in **View details**, and not on the Developer screen, and `IDatabaseSummary` does not carry it. Until it is shown, this pathway cannot be completed from the phone, and pathway B is the one that works: create the remote empty on the computer with `psi init`, then replicate it down, which copies the id rather than matching it.

### A3. Create the remote to match it, on the computer

Register the bucket and its keys:

```bash
psi dbs add
```

It asks, in this order:

- **Database name.** A name for the entry, not for the storage. `phone-backup` will do.
- **Description.** Optional.
- **Database path.** `s3:<bucket>/<prefix>`. Nothing must exist at that path yet.
- **S3 credentials.** `+ Create new`, then the endpoint URL (blank for real AWS), region, access key id and secret access key.
- **Encryption key.** `+ Create new`, then `Generate a new RSA-4096 key pair`, or `Import existing PEM files` to use a key you already have. Choose `None` to leave the remote unencrypted.
- **Geocoding API key.** `None`.

Nothing is created in the bucket by that. It only records what the bucket is and which keys open it.

**Keep the encryption key.** Nothing can read the remote copy without it, and it exists only in your computer's keychain and, later, the phone's. `psi secrets view --name <key name> --raw` prints it, so a copy can go somewhere safe such as a password manager. Nobody can recover it for you.

Then create the database in the bucket, carrying the phone's id:

```bash
psi init --db s3:<bucket>/<prefix> --key <encryption key name> --database-id <the phone's id>
```

Leave `--key` off for an unencrypted database. The bucket credentials come from the entry just registered, so no environment variables are needed.

Expected: it reports that it created the database, and `psi database-id --db s3:<bucket>/<prefix>` prints the same id the phone has. A mistyped id is refused rather than accepted, because a remote with the wrong identity looks perfectly fine and then refuses to sync minutes later.

Nothing is copied up front. The remote is created empty and the background sync fills it, a pass at a time, which is what survives the app being backgrounded. Replicating a whole library out of a phone in one go does not.

### A4. Send it to the phone

Follow [Sending the database to the phone](#sending-the-database-to-the-phone).

### A5. Point the phone's database at it

The remote exists and the phone knows the bucket, but the phone's database still has nowhere to sync to.

1. On **Manage Databases**, press the **⋮** on the phone's database and choose **Edit**.
2. Beside **Origin**, use the **Choose…** dropdown and pick the entry for the bucket. Do not type the path: the keys for an origin are found by matching it against the database list, so a typed path with a mistake in it finds no entry and no keys, and the failure turns up minutes later in a log rather than when you save.
3. Press **Save**.

Expected: **View details** on the phone's database now shows the bucket's path against **Origin**. That field is what background syncing looks for, and a database without it never syncs.

Now go to [Part 2](#part-2-switch-it-all-on).
## Pathway B: a database that already exists

### B1. Register it on the computer

If the CLI on this computer does not already list it (`psi dbs list`), register it, naming secrets that are already in the keychain (`psi secrets list` prints their names):

```bash
psi dbs add --yes --name <a name for it> --path s3:<bucket>/<prefix> \
  --s3-cred <s3 secret name> --encryption-key <encryption key name>
```

Leave `--encryption-key` off if the database is not encrypted.

Check it reads, which also proves those are the right secrets:

```bash
psi summary --db s3:<bucket>/<prefix>
```

Expected: a summary rather than a report that no database was found. Note how many photos it holds, because that is what the phone downloads thumbnails for in the next step.

### B2. Send it to the phone

Now go to [Sending the database to the phone](#sending-the-database-to-the-phone), then [Replicating it down](#replicating-it-down-to-the-phone), then [Part 2](#part-2-switch-it-all-on).

## Sending the database to the phone

The phone needs the bucket's credentials and, if the database is encrypted, the encryption key. Sending the database entry carries both.

**Start the phone waiting first, and choose the pairing code yourself.** Each side waits sixty seconds for the other, which is not enough time to start the send on the computer and then walk to the phone and get through three screens. The phone is the slow side, so it goes first, and `--code` is what lets it: the code is normally generated by the sender, and picking it in advance is what makes it possible to type it in before the sender is running.

Pick any four digits. On the phone:

1. Open the menu (the hamburger, top left) and choose **Manage Databases**.
2. Press the **⋮** at the top of the page and choose **Receive database**.
3. Enter the four digits and press **Start**. The phone now waits sixty seconds.

Then, on the computer, inside that minute:

```bash
psi dbs send --name <the entry name> --code <the four digits> --yes
```

`--yes` is what takes it straight to sending; without it the command walks through the name, description and path first, offering to edit each.

Back on the phone:

4. On the review screen leave **Name** and **Path** exactly as they arrive. The path is how the phone finds the keys for the bucket, and it has to match character for character.
5. Tick **Import S3 credentials** and **Import encryption key**.
6. Press **Save**.

Expected: "Database imported successfully!", and the remote appears on the Manage Databases page.

Both devices have to be on the same local network. This does not work over the internet. "No device found within 60 seconds" on the computer means the window was missed, or the two are not on the same network; run the send again with the phone waiting.

## Replicating it down to the phone

This makes the phone's own copy: the same database with the same identity, with the bucket recorded as its origin.

1. On **Manage Databases**, press the **⋮** on the remote and choose **Replicate**.
2. **Destination type**: `File system`.
3. **Destination path**: type a short name, for example `photosphere-ash`. It is created inside the app's own private storage; there is nothing on the phone's filesystem to browse to, and **Browse** on Android is a text prompt rather than a folder chooser. This is a local path, so it can be the same word as the bucket without clashing with it.
4. **Mode**: **Partial**. It copies the README, the files merkle tree and the merkle trees of the record database, and nothing else: a handful of small files however large the library is, because it deliberately does not walk the tree. **Full** copies every original as well, which on a real library is tens of gigabytes onto a phone.
5. Press **Replicate**. It finishes in seconds.

The thumbnails and records are not part of that. Opening a partial replica queues a `prefetch-database` task in the background, which pulls what is missing from the origin a few files at a time, so the gallery fills in behind you rather than making you wait in a dialog.

Then register the copy and make it the one the app uses:

1. On **Manage Databases**, press the **⋮** at the top and choose **Add database**.
2. **Name**: whatever you want to see in the app. Entry names have to be unique, so if you want this one to carry the plain name, rename the remote's entry first (**⋮** then **Edit** on it) to something like `photosphere-ash-remote`. Renaming an entry is safe: an origin is matched to its keys by path, never by name.
3. **Type**: `File system`. **Path**: the same name you typed in step 3 above.
4. Press **Add**. The app registers it and opens it.
5. Press the **⋮** on it and choose **Set as default**.

**Set as default** is what makes automatic import write into this database. Without it, switching automatic import on makes a database of its own called **My Photos** and imports into that instead, and you end up with two.

Check it: **⋮** then **View details** shows the bucket's path against **Origin**. That field is what background syncing looks for, and a database without it never syncs.

## Part 2: switch it all on

### Check syncing is on

Open the menu and choose **Configuration**. Under **Syncing**:

- **Enable syncing** should be on. A fresh install starts with it on, so this is a check rather than a change.
- **Only sync over Wi-Fi** should be on, and the phone on Wi-Fi. Turn it off only if you want the phone uploading photos over mobile data.

There is no interval to set. A pass runs every five minutes, and a pass with nothing to do costs two small reads, one of them over the network.

### Switch automatic import on

Still in **Configuration**, find the **Automatic import** card and turn the toggle on.

Android asks for permission to read your photos. Grant it, and grant access to **all** photos rather than a selection: a partial grant is treated as a refusal, and the toggle goes back to off with nothing on screen to say why.

Leave **Folders watched** empty. On a phone the whole photo library is the source, and **Add a folder** is not a folder chooser on Android.

Expected:

- The toggle stays on.
- A notification appears saying **Backing up your photos**. That is the foreground service, and it is what lets importing carry on with the app closed and the screen off. It stays while automatic import is on.
- Photos from the phone start appearing in the gallery within about half a minute, and keep appearing until the library has been walked. A pass reads the library, imports what is new and ends; the next starts about thirty seconds later.
- The app stays usable throughout.

A photo taken while the app is open appears on its own within about half a minute, once the backlog has been worked through.

### Watch the first photos reach the bucket

A sync runs every five minutes, so give it that long. From the computer:

```bash
psi summary --db s3:<bucket>/<prefix>
```

Expected: the count climbs across passes while automatic import is still catching up, rather than everything arriving at once. Nothing on the phone was pressed to make any of it happen.

### Check the photos are really there

Once the gallery has stopped growing and a sync pass has been through:

```bash
psi verify --db s3:<bucket>/<prefix>
```

## After it is running

**The Import page** (**Import** in the top bar, or in the menu) lists what came in, newest first, badged **automatic** or **manual**. It survives restarts, so it answers "what came in while I was not looking?" rather than only showing what has happened since the app started.

**The photo count in the top bar** opens the database summary: how many photos and files, how big it is, where it is, and whether it holds all its own originals.

**Freeing up space.** Once photos are safely on the remote, the **Free up space on this device** button in the automatic import settings deletes photos from the phone's camera roll that your database already holds. It counts first and says what it found; a second press deletes. It checks the database holds the content rather than trusting that an import reported success. Only do this once the remote copy is verified.

**Switching automatic import off** stops future imports and removes nothing. Photos already imported stay, and the database still syncs.

## When something is not working

| What you see | What it means |
|---|---|
| The **Automatic import** toggle turns itself back off | The photo permission was refused, or only some photos were shared. Grant full photo access in Android's Settings, under Apps, Photosphere, Permissions, then switch it on again. |
| Photos import but nothing reaches the bucket | The database has no **Origin**. Check with **⋮** then **View details**. If it is blank, A5 or the replication did not complete. |
| Nothing syncs and the origin is set | The phone is on mobile data with **Only sync over Wi-Fi** on, or **Enable syncing** is off. |
| Two databases, one of them called **My Photos** | Automatic import was switched on before a default was set, so it made its own. Set the one you want as default, and remove the other once you are sure nothing of yours is only in it. |
| Replicating fails complaining about credentials or access | The phone has no database entry whose path matches the remote exactly, so it found no keys for the bucket. |
| No **Backing up your photos** notification | The service only runs when automatic import is on, or when syncing is on and there is a database with an origin to push. |
