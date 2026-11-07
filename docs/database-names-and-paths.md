# Database names and paths

How Photosphere names a database, where it records the path, how the path is written and resolved and how this differs between the desktop app, the mobile app and the CLI.

## The database list

The app and the CLI share one list of databases, stored in `databases.toml` in the settings directory.

Where the settings directory is:

- Desktop app and CLI on every desktop OS, and iOS: `<home>/.config/photosphere`.
- Android: the app's files directory, which the app makes its home directory.
- No home directory found at all: `.`, relative to the working directory.

Each database in the list is a `[[databases]]` table in `databases.toml`, called a **database record** below. It has these keys:

- `name`: the database's name, unique ignoring letter case.
- `description`: free text the user writes about the database, shown on the databases page. It can be empty.
- `path`: where the database is, a filesystem path or an S3 path.
- `origin`: the path of the database this database syncs with, mirrored from the database's own `.db/config.json`.
- `s3_key`, `encryption_key`, `geocoding_key`: names of vault secrets.

`databases.toml` holds only the database records. The recent databases and the database to reopen at the next start are in [state.yaml](#stateyaml).

## The name

The name is the database's identity in the list.

- Matching is case insensitive. Adding a database record whose name matches another fails with `A database named "X" already exists.`
- The name is used to find, update and remove a database record, for the recents list and to mark a database as opened.
- The UI shows the name as the title (databases page, sidebar, recents, open dialog). When the name is empty, which happens when a record in `databases.toml` has no `name` key, it shows the last segment of the path instead.
- Renaming a database record changes only its name; the database stays where it is on disk.

### Database records the app adds

In four cases the app adds a database record without the user naming it. This is the name each record gets:

- Opening a database whose path matches no database record adds one named after the last segment of the path.
- A replication that succeeds adds the destination, named after the last segment of the destination path, with `origin` set to the source path.
- The default database is named `My Photos`.
- A database received over the LAN takes the name the sender gave it, which the user can edit before importing.
- The first two fail if that name is already taken.

## The path

The database is located in the file system, or in S3, by the database path. The app and the CLI open a database by its path. The name is only used to find the database record, which holds the path.

### Forms a path takes

- `s3:<bucket>/<key>`: a database in S3. The part after `s3:` is used as it is and must have a bucket and a key. The S3 browser in the UI produces these.
- `fs:<path>`: a filesystem path, written explicitly.
- A path with neither prefix: a filesystem path.

How a filesystem path is resolved:

There are three kinds of filesystem path, and each resolves differently:

- **An absolute path** starts at the root: `/home/me/photos`, `C:\photos` or `\photos` on Windows. It stays as it is, in the app and the CLI.
- **A simple name** is a single folder name: no `/` or `\`, not `.` or `..`. Only a simple name uses the data dir:
  - In the app it resolves to `<data dir>/dbs/<name>`.
  - In the CLI it opens `<cwd>/<name>` when a database is there, otherwise `<data dir>/dbs/<name>` when a database is there. A new database is created at `<cwd>/<name>`.
- **A relative path** is any other path that is not absolute, including `.`, `./x`, `../x` and `foo/bar`, resolves against the working directory, in the app and the CLI. On a phone the working directory is `/`, so such a path fails there.
- Backslashes become forward slashes.
- When both encryption keys are given, the database is opened as encrypted.

Examples in the app, with `<cwd>` as the working directory:

```
What is typed                 Opens
----------------------------  -------------------------------
my-photos                     <data dir>/dbs/my-photos
photos/2024                   <cwd>/photos/2024
.                             <cwd>
./my-photos                   <cwd>/my-photos
../my-photos                  <parent of cwd>/my-photos
/home/me/photos               /home/me/photos
~/photos                      <cwd>/~/photos
C:\Users\me\photos            C:/Users/me/photos
\photos  (Windows)            <drive of cwd>:/photos
fs:my-photos                  <data dir>/dbs/my-photos
fs:/home/me/photos            /home/me/photos
s3:my-bucket/photos           S3 bucket my-bucket, key photos
s3:my-bucket                  Error: no key
content://... (Android pick)  <cwd>/content:/...
(empty)                       Error: Path is required
```

The CLI opens the same, except that `my-photos` and `fs:my-photos` open `<cwd>/my-photos` when a database is there.

- The CLI's `--db` is first looked up as a database record's path or name, so `--db my-photos` opens the database record called `my-photos` when there is one. See [In the CLI](#in-the-cli).
- `~` is an ordinary folder name.
- What is stored in a database record is the text as typed, trimmed.

### Credentials and keys found from the path

S3 credentials, for an `s3:` path only, in order:

1. an S3 secret named by the caller;
2. the `s3_key` of the database record whose `path` equals this path;
3. the AWS environment variables (see [Environment variables](#environment-variables)).

Encryption keys, in order:

1. a key named by the caller: a file path if that file exists, otherwise a vault name;
2. the database record's `encryption_key`, a vault name;
3. the encryption key environment variable.

The CLI's own S3 lookup uses the AWS variables first, then the vault secret `default:s3`.

### Paths are compared as exact strings

Paths are compared character for character. So `/home/me/photos` and `/home/me/photos/` name the same folder but are two different databases for:

- finding the database record for a path, for its S3 secret and keys;
- deciding, when a database is opened, whether to add a database record;
- a replication deciding whether the destination is already listed;
- deciding whether the default database is already listed;
- the CLI matching `--db` to a database record;
- the UI marking which database is open and which is the default;
- the UI offering origins.

What is stored is what was given. `databases.last_opened_path` in `state.yaml`, a database record's `path` and an `origin` are all written as the string the user typed or picked, after trimming.

### Origin

- `origin` is a path. It is kept in the database's `.db/config.json`, which sync reads. It is mirrored into the database record.
- It is written by:
  - replicate: the destination's origin is the source path as given;
  - consolidate: the local database's origin is the remote path as given;
  - the Edit dialog;
  - the CLI's `set-origin`.
- Sync opens the origin by that path. Its credentials come from a database record whose `path` equals the origin string, or from the AWS variables.

## How a user gives a path

### In the app

Each dialog trims the path and checks it is filled in. It passes the trimmed text to the core unchanged: the core resolves it, by the rules in [Forms a path takes](#forms-a-path-takes).

- New database: filesystem or S3. Type it, or Browse: a folder picker for filesystem, the S3 browser for S3 (needs an S3 secret first). Creates the database at the path, then opens it.
- Add database: the same choices. Adds the database record, then opens the database.
- Edit database: path and origin. Browse picks a folder. The origin can be picked from the other database records' paths.
- Replicate: the destination, filesystem or S3, typed or browsed. Must differ from the source path.
- Consolidate: the remote, typed only (`/path/to/backup or s3:bucket/prefix`).
- Receive: the path the sender gave, which the user can edit.

What the folder picker returns:

- Desktop: the folder's path.
- iOS: the folder's path. Access lasts while the app runs.
- Android: a `content://` tree address. The app treats it as a relative filesystem path.

### In the CLI

- `--db <path or name>` names the database. Without it the CLI uses the working directory if it holds a database, otherwise it shows a picker.
- Given the `--db` value, the CLI first looks for a database record whose path equals it, then for one whose name matches it, ignoring letter case. It then uses that database record's path, S3 secret and key. If two names match it stops with an "Ambiguous database name" error listing them. When no database record matches, the CLI treats the value as a path.
- A simple name opens `<cwd>/<name>` when a database is there, otherwise `<data dir>/dbs/<name>` when a database is there. A new database, for example from `psi init`, is created at `<cwd>/<name>`. `.` and every other relative path resolve against the working directory. An absolute path is used as it is.
- `dbs add` adds a database record, storing the path as typed, trimmed. `psi init` creates the database on disk.

## The default database

- Where: `auto_import.default_database_path` in `config.yaml`, otherwise `<data dir>/dbs/photosphere-default`, in the same [data directory](#simple-names-and-the-data-directory) simple names resolve against.
- Desktop and mobile both look for it in that same directory and check it exists there.
- Made on desktop when automatic import starts. On mobile it is the first step of the automatic import plan.
- Recorded: the path goes into `auto_import.default_database_path` and a database record named `My Photos` is added with the absolute path.

So the default database and simple names share `<data dir>/dbs/`.

The data directory is the one Ziggy's native app chooses. [Filesystem layout per platform](#filesystem-layout-per-platform) shows it for each platform.

- Linux: the GLib user data directory.
- Android: the app's files directory.
- Windows, macOS and iOS: see the layout trees.
- The app id comes from the Linux and Windows app builds, the macOS and iOS bundle ids from their Xcode projects and the Android id from its Gradle build.

On mobile, sync and prefetch work on `sync.database_path` in `config.yaml`, which is the last database opened, or else on the default database. They run only when that database has an origin.

## The asset server

- The page loads thumbnails and originals from the in-process asset server with `db=<path>`, the exact path it opened.
- The server opens that path and finds credentials by matching it against the database records' paths, so the same rules apply.
- A simple name in `db` resolves against `<data dir>/dbs`; any other relative `db` resolves against the working directory.

## Desktop, mobile and CLI compared

- Working directory: a relative path that is not a simple name resolves against it, in the app and the CLI. The CLI also looks there first for a simple name. The CLI's working directory is where the command runs.
- A simple name typed: `<data dir>/dbs/<name>` in the app; in the CLI, the working directory first, then `<data dir>/dbs/<name>`.
- Name to path: the app uses the database record; the CLI matches `--db` to a database record by path, then by name.

## Simple names and the data directory

On a phone the app's storage path is hidden from the user, so the only thing they can type is a simple name such as `my-photos`. The app puts a database given by a simple name in its data directory, at `<data dir>/dbs/<name>`.

- In the app, on every platform, an absolute path is used as it is. A simple name resolves against `<data dir>/dbs`; any other relative path resolves against the working directory. So `my-photos` is `<data dir>/dbs/my-photos`.
- `<data dir>` is the data directory Ziggy's native app chooses. The smoke tests give each scenario its own (see [Environment variables](#environment-variables)).
- Databases get a folder of their own because the data directory also holds the logs, the single-instance lock and on Windows the web view's data (see [What each directory is for](#what-each-directory-is-for)).
- The app's handlers and tasks, the asset server and the shared tasks get the data directory from Ziggy. The shared tasks receive it in their task data.
- The CLI works out the same data directory the desktop app uses on its OS. It looks for an existing database in `<data dir>/dbs/` after the working directory.
- Database records keep the path as the user typed it, so the exact string comparisons above still match each other.

## Config and state files

The files below are the ones the app and the CLI write that refer to a database.

### What each directory is for

- Settings: what the user chose and the app remembered: `databases.toml`, `config.yaml`, `state.yaml`.
- Data: the app's own files, including its databases under `dbs/`. The trees below show what is in it.
- Cache: what this machine has worked out about each database and its own import history, kept outside the database. See [Per database, on this machine](#per-database-on-this-machine).
- Vault: the secrets a database record names by `s3_key`, `encryption_key` and `geocoding_key`. See [The vault](#the-vault).
- Logs: the app's and the CLI's log files.

[Filesystem layout per platform](#filesystem-layout-per-platform) shows where each directory is. [Environment variables](#environment-variables) lists what moves them.

### databases.toml

- Holds: the database records. See [The database list](#the-database-list).
- Refers to databases: database records by name and path; `origin` by path.
- Read and written by the app's database handlers, by creating the default database and by the CLI's `dbs` commands and `--db` lookup.

### config.yaml

- On a phone the page asks for `config.yaml` and the core points that at the settings directory, so every platform uses the one file there.
- What the user chose:
  - `theme`: `light`, `dark` or `system`.
  - `developer_mode`, `show_fps_indicator`: developer settings.
  - `saved_searches`: searches saved from the sidebar.
  - `auto_import.enabled`, `auto_import.sources`, `auto_import.pause_between_runs_ms`, `auto_import.cleanup_enabled`: automatic import. A source is `type: folder` with `path` and `recurse`, or `type: device-album` with `album_id`.
  - `auto_import.default_database_path`: the database automatic import writes to, by **path**.
  - `sync.enabled`, `sync.only_on_wifi`, `sync.pause_between_runs_ms`: background sync.
  - `sync.database_path`: the database background sync pushes, by **path**.
  - Only the two `*_path` keys refer to a database.
- Read and written by the app's settings handlers.
- Creating the default database writes `auto_import.default_database_path`. Automatic import reads it.
- On a phone the page writes only the `sync` section.
- Writes merge under a lock file beside `config.yaml`.
- Read and written by the app only.

### state.yaml

- `databases.recent_names`: up to 5 database **names**, most recent first. A name with no database record is dropped when read.
- `databases.last_opened_path`: a **path**, the database to reopen at the next start.
- What else the app remembered: `desktop.last_folder`, `desktop.last_download_folder`, `desktop.dev_tools_open`, `searches.recent`, `gallery.sort`, `gallery.row_height`, `news` (shown news ids, the last update version told about and on a phone the fetched feed) and `ui` (keys the interface makes, such as collapsed sidebar sections).
- Folder pickers start in a saved folder and store the chosen folder back: `desktop.last_folder` by default, or `desktop.last_download_folder`.
- Refers to databases through `databases.recent_names` by **name**, `databases.last_opened_path` by **path** and `desktop.last_folder`, where Open Database stores the **parent folder** of the database it opened.
- Read and written by the app and its folder pickers. The `news` section is also read and written by the CLI.

### The vault

The vault holds the secrets a database record names by `s3_key`, `encryption_key` and `geocoding_key`. It also holds the CLI's `default:s3`. The database record stores only the secret's **name**.

The vault is `phone` on Android and iOS and `keychain` elsewhere. The tests use `plaintext`.

- `keychain` on macOS: the login keychain through `security`, service `photosphere`, account `psi-<name>`.
- `keychain` on Linux: the Secret Service through `secret-tool`, service `photosphere`.
- `keychain` on Windows: the Windows `PasswordVault` through PowerShell, resource `photosphere`.
- `phone` on Android: `EncryptedSharedPreferences` file `photosphere_secure_store`.
- `phone` on iOS: the keychain, generic passwords under service `au.com.codecapers.photosphere.securestore`.
- `plaintext` on any platform, used only by the tests: `vault.json` in the plaintext vault directory above.

A phone secret is two items in the phone's keychain: `photosphere.secret.<name>` holds the value and `photosphere.secret-type.<name>` the type.

### Inside each database

The same on every platform, wherever the database is:

```
<database>/
└── .db/
    ├── config.json       Origin only, by path
    ├── state.dat         Content hash, last modified,
    │                     last synced, last replicated
    ├── files.dat         Files merkle tree and database
    │                     metadata, with the partial flag
    │                     (set by replication and by
    │                     evicting originals)
    ├── bson/...          Metadata collections
    ├── write.lock        The write lock
    └── encryption.pub    The encryption marker
```

`config.json` is the only file here that refers to another database.

### Per database, on this machine

The cache directory has one folder for each database. The folder holds what this machine has learned about that database. It is kept outside the database because:

- a database can be in S3, away from this machine;
- a database on shared storage is opened by several machines, which would overwrite each other's files;
- what one machine knows is keyed by its own file paths and photo library ids, so it applies to that machine only.

The folder:

- `<key>` is the first 16 hex digits of the SHA-256 of the database path string. The path is hashed so that a Windows path or an `s3:` path makes a valid folder name.
- `hash-cache/hash-cache-x.dat`: for each source file, its size, modified time, hash and the asset id it has in this database.
  - Import, check and source cleanup use it to avoid hashing a file again.
  - It can be deleted: the next import, check or cleanup works the hashes out again from the source files.
  - A file of another format version is discarded and rebuilt.
- `imports.dat`: this machine's record of what it imported into this database. It is a history of imports. An unreadable one reads as empty and losing it loses that history; the database itself is unaffected.
- Refers to the database by **path**, hashed as the string given. The same folder written two ways gets two caches, as with [paths compared as exact strings](#paths-are-compared-as-exact-strings).
- Stays on this machine. `psi hash-cache clear` deletes one database's hash cache.

### What a reset clears

- Reset empties the settings and cache directories.
- On Android and iOS it also empties Ziggy's data directory.
- On desktop the data directory is left alone, so the default database survives.

## Filesystem layout per platform

`~` is the home directory. `<container>` is the iOS app's sandbox container. Each tree shows the default places and only what is on that platform's disk. [Environment variables](#environment-variables) lists what moves them, [What each directory is for](#what-each-directory-is-for) says what each holds and [Inside each database](#inside-each-database) shows a database folder.

### Desktop app on Linux

App id `au.com.codecapers.photosphere`.

```
~/
├── .config/photosphere/          Settings
│   ├── databases.toml            Database list
│   ├── config.yaml               What the user chose
│   ├── state.yaml                What the app remembered,
│   │                             including recents and the
│   │                             last database
│   └── vault/vault.json          Plaintext vault, tests only
├── .cache/photosphere/           Cache
│   └── <key>/                    One per database path
│       ├── hash-cache/hash-cache-x.dat
│       │                         Source file hashes
│       └── imports.dat           Import history
└── .local/share/au.com.codecapers.photosphere/
    │                             Data dir, the app's own files
    ├── single-instance.lock      Keeps the packaged app to one
    ├── single-instance.signal    Running copy and brings its
    │                             window forward
    ├── logs/                     App logs:
    │                             photosphere-<start time>.log,
    │                             photosphere-<start time>-errors.log
    └── dbs/                      The app's own databases
        ├── photosphere-default/  Default database
        └── <name>/               A database given by
                                  simple name
<any absolute path>/              Any other database
```

- Vault: the Secret Service, which stores secrets in the system keyring, outside these folders.
- `auto_import.default_database_path` can put the default database anywhere.

### Desktop app on macOS

App id `au.com.codecapers.photosphere`.

```
~/
├── .config/photosphere/          Settings, vault: as on Linux
└── Library/
    ├── Caches/photosphere/       Cache
    │   └── <key>/                One per database path
    └── Application Support/
        └── au.com.codecapers.photosphere/
            │                     Data dir, the app's own files
            ├── single-instance.lock
            │                     One running copy
            ├── logs/             App logs
            └── dbs/              The app's own databases
                ├── photosphere-default/
                │                 Default database
                └── <name>/       A database given by
                                  simple name
<any absolute path>/              Any other database
```

- Vault: the login keychain by default.

### Desktop app on Windows

App id `au.com.codecapers.photosphere`.

```
~\
├── .config\photosphere\          Settings, vault: as on Linux
└── AppData\Local\
    ├── photosphere\cache\        Cache
    │   └── <key>\                One per database path
    └── au.com.codecapers.photosphere\
        │                         Data dir, the app's own files
        ├── single-instance.lock  One running copy
        ├── logs\                 App logs
        ├── WebView2\             The web view's data
        └── dbs\                  The app's own databases
            ├── photosphere-default\
            │                     Default database
            └── <name>\           A database given by
                                  simple name
<any absolute path>\              Any other database
```

- Vault: `PasswordVault` by default.
- `~\AppData\Local` is the usual place of the local application data folder, which the cache and the data dir follow.
- Ziggy makes the web view directory.

### CLI

The CLI shares the desktop app's settings, vault, cache and data dir on the same OS. It writes its logs to the temp directory. Linux is shown.

```
~/
├── .config/photosphere/          Settings and vault, shared
│                                 with the app
├── .cache/photosphere/           Cache, shared with the app
└── .local/share/au.com.codecapers.photosphere/
    │                             Data dir, shared with the app
    └── dbs/
        └── <name>/               An existing database found by
                                  simple name when the working
                                  directory holds no database of that name

<working directory>/
├── <name>/                       A database given by simple
│                                 name, looked for first; new
│                                 databases go here
└── <relative path>/              A database given by a
                                  relative path such as . or
                                  foo/bar

<tmp>/
└── photosphere/logs/             CLI logs
    ├── psi-<start time>.log
    └── psi-<start time>-errors.log

<any absolute path>/              Any other database
```

`psi version` prints the settings and cache directories.

### Mobile app on Android

App id `au.com.codecapers.photosphere.ziggy`.

```
/data/user/0/au.com.codecapers.photosphere.ziggy/
└── files/                        Files dir: data dir, home,
    │                             settings and cache in one
    ├── databases.toml            Database list
    ├── config.yaml               What the user chose
    ├── state.yaml                What the app remembered
    ├── <key>/                    Per-database cache
    ├── logs/                     App logs
    └── dbs/                      The app's own databases
        ├── photosphere-default/  Default database
        └── <name>/               A database given by
                                  simple name
<app cache dir>/                  Temp files
```

- Settings and cache are in the files dir because the app makes it the home directory before the core starts. Temp files go to the app's cache directory.
- A picked folder is a `content://` address. See [How a user gives a path](#how-a-user-gives-a-path).
- Vault: `EncryptedSharedPreferences`.
- A database can also be any path inside the app's sandbox.

### Mobile app on iOS

App id `au.com.codecapers.photosphere.ziggy`. Settings and cache follow the home directory iOS gives the app, which this repository and Ziggy leave as iOS sets it. The tree assumes iOS gives the container.

```
<container>/
├── .config/photosphere/          Settings, if the home
│                                 directory is the container
├── .cache/photosphere/           Cache, if the home
│                                 directory is the container
└── Library/Application Support/
    └── au.com.codecapers.photosphere.ziggy/
        │                         Data dir, the app's own files
        ├── logs/                 App logs
        └── dbs/                  The app's own databases
            ├── photosphere-default/
            │                     Default database
            └── <name>/           A database given by
                                  simple name
<picked folder>/                  Security-scoped, reachable only
                                  while the app runs
```

- Vault: the iOS keychain.
- A database can also be any path inside the sandbox.
- For a picked folder Ziggy asks iOS for security-scoped access, which lasts while the app runs.

### Environment variables

Each smoke test scenario sets its own, so scenarios running side by side each use directories of their own.

| Variable | What it does | Smoke tests set it on |
|---|---|---|
| `PHOTOSPHERE_CONFIG_DIR` | Moves the settings directory | Every platform |
| `PHOTOSPHERE_DATA_DIR` | Replaces the `<data dir>` that `dbs/` is in | Every platform |
| `PHOTOSPHERE_LOG_DIR` | Moves the app's logs | Every platform |
| `PHOTOSPHERE_CACHE_DIR` | Moves the cache directory | Desktop |
| `PHOTOSPHERE_VAULT_TYPE` | Picks the vault: `keychain`, `phone` or `plaintext` | Desktop and iOS, as `plaintext` |
| `PHOTOSPHERE_VAULT_DIR` | Moves the plaintext vault, default `~/.config/photosphere/vault` | Desktop and iOS |
| `PHOTOSPHERE_TEST_MODE` | Test mode | Every platform, as `1` |
| `PHOTOSPHERE_TMP_DIR` | Moves the CLI's temp directory, and so its logs | |
| `HOME` | The home directory, which settings and cache are under; on Android the app sets it to its files directory | Linux and macOS |
| `XDG_DATA_HOME` | Linux: the base of the data directory, default `~/.local/share` | Linux |
| `XDG_CACHE_HOME` | Linux and iOS: the base of the cache, default `~/.cache` | |
| `CFFIXED_USER_HOME` | macOS: the home directory the system uses | macOS |
| `LOCALAPPDATA` | Windows: the base of the data directory and cache; the app needs it to start | Windows |
| `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, `AWS_ENDPOINT_URL` | S3 credentials used when a database record names no S3 secret; region defaults to `us-east-1` | Unset on desktop, so S3 credentials come from the vault |
| `PSI_ENCRYPTION_KEY` | An encryption key, as a file path or vault name, used when neither the command nor the database record names one | |

- On Windows the home directory is `USERPROFILE`.
- The plaintext vault is only for tests. A real install uses the keychain on desktop and the phone's keychain on mobile.
- On Android a debuggable build copies every `PHOTOSPHERE_*` string extra of the launching Intent into the environment.

### Where a smoke test scenario's files go

Linux:

```
<test>/
├── app logs
├── config/                       Settings
├── files/                        <data dir> for databases
│   └── dbs/                      Default database, simple names
├── cache/                        Cache
├── vault/                        Plaintext vault
├── home/                         Home directory
└── data/
    └── au.com.codecapers.photosphere/
                                  Ziggy's data dir
```

macOS: the same as Linux, without `data/`.

Windows:

```
<test>\
├── app logs
├── config\                       Settings
├── files\                        <data dir> for databases
│   └── dbs\                      Default database, simple names
├── cache\                        Cache
├── vault\                        Plaintext vault
└── data\
    └── au.com.codecapers.photosphere\
                                  Ziggy's data dir, the web
                                  view's data
```

Android, with the cache and vault left where the app keeps them:

```
/data/data/<app id>/
├── files/                        The app's data dir, also the
│   │                             <data dir> for databases
│   ├── config/                   Settings
│   └── dbs/                      Default database, simple names
└── <log dir>/                    App logs
```

iOS simulator, with the cache left where the app keeps it:

```
<the app's data dir>/             Also the <data dir> for databases
└── dbs/                          Default database, simple names
<the log dir>/                    App logs
<test>/
├── config/                       Settings
└── vault/                        Plaintext vault
```

iOS device, with the cache left where the app keeps it:

```
<scenario>/
├── app logs
├── config/                       Settings
├── files/                        <data dir> for databases
│   └── dbs/                      Default database, simple names
└── vault/                        Plaintext vault
```

## Open points

- Android's folder picker returns `content://` addresses, which the app treats as relative filesystem paths, so a picked folder fails to open.
- Comparing paths as exact strings means the same folder written two ways is two databases.
- Moving the data directory for a test moves `dbs/`. The app's logs stay in Ziggy's data directory unless the log directory is moved too.
- A reset on a phone empties Ziggy's data directory, so a data directory a test moved survives it.
- The per-database cache key hashes the path string as given, so `test-db` and its absolute path get separate hash caches and import records.
- The app and Ziggy leave the working directory on a phone as the system sets it. That it is `/` comes from the failure seen when a simple name was typed (`ReadOnlyFileSystem` on `/my-photos`).
