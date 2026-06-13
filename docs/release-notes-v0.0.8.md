# Photosphere release v0.0.8

Big release. The headline is a **new cross-platform GUI** (Windows, macOS, Linux) with photo/video browsing, importing, organising, sync, and local-network sharing. Photosphere also moved to a local-first architecture, and there are many CLI, database, encryption, and reliability improvements.

## New cross-platform GUI

A desktop app for Windows, MaxOS and Linux, with:
- Photo gallery with search, photo viewer, video playback and metadata editor.
- Map view to find photos by location.
- Star and flag photos; shift/ctrl multi-selection.
- Saved searches and recent searches.
- Import page to add photos and directories to your database.
- Replicate databases.
- Support for partial (lazy) database replicas on space limited devices.
- Move assets between databases.
- Bidirection automatic background sync; keeps database synchronized between devices via a cloud-hosted database (currently supporting just S3-compatible).

## Sharing over the local network

- Securely share databases and secrets between devices on the same network.
- Pairing-code flow with mutual authentication, from both the GUI and CLI.

## Secrets and credentials

- Secrets managed securely on device with easy sharing between devices (on the same local network).

## CLI changes

- `repair` now fixes assets missing a database record, missing a hash, or with an incorrect hash.
- `verify` checks every asset against its database record and hash, and checks all database files for consistency.
- Different exit codes for different failure types.
- `info` can match assets by filename, asset ID, or hash.
- Windows config file now stored in the same directory as other platforms.
- `add` uses worker threads to import media in parallel; `check` optimised to use parallel workers with fixed progress reporting.
- New `encrypt` / `decrypt` commands (streaming, multiple keys, partial encryption).
- New `secrets` and `dbs` commands; new `upgrade` command to migrate older databases.
- Encryption-key management, short command aliases, consistent `--yes` non-interactive mode, built-in bug reporting and examples.

## Performance and reliability

- Parallel worker-thread processing for add, check, verify, and import.
- Database write locking to prevent corruption from concurrent writes.
- Robust S3 large-file handling (range requests, retries, timeouts).
- Faster sync/replication via a more efficient merkle-tree diff.

## Database format

- Format advanced to v6 (run `psi upgrade` to migrate; old versions refused until upgraded).
- BSON database syncs via a merkle tree, with per-field timestamps so records merge with minimal conflicts.
- Per-device identity to keep updates from different devices separate.

## Architecture

- **Removed the self-hosted backend + frontend.** I might restore this someday if people want it.
- Photosphere is now local-first: it runs off local data or data stored in your preferred S3-compatible cloud storage provider. Enables local database for each device automatically syncrhonized via shared databases in cloud storage.

---

## CLI Download

- **Linux:** photosphere-cli-linux-x64.tar.gz
- **Windows modern:** photosphere-cli-windows-x64.zip (for modern processors, try this one first)
- **Windows baseline:** photosphere-cli-windows-x64-baseline.zip (for older processors, try this one next)
- **macOS (Intel):** photosphere-cli-macos-x64.tar.gz
- **macOS (Apple Silicon):** photosphere-cli-macos-arm64.tar.gz

## CLI Installation

1. Download the appropriate file for your platform
2. Extract the archive
3. Make the binary executable (Linux/macOS): `chmod +x psi`
4. Remove the quarantine attribute (macOS only): `xattr -c ./psi`
5. Move to your PATH or run directly

## Desktop Download

- **Linux:** .deb package or .zip
- **Windows:** .exe installer or .zip
- **macOS:** .dmg disk image or .zip
