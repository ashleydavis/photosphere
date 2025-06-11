# Photosphere CLI Commands Documentation

## Overview
The Photosphere CLI (`psi`) is a command-line tool for managing your media file database. It provides commands to initialize databases, add media files, view database summaries, verify database integrity, replicate databases across storage systems, start the web UI, configure cloud storage, and analyze media file metadata.

**CLI Tool Name:** `psi`  
**Version:** 0.0.1

## Global Options
These options are available for most commands:

- `-m, --meta <db-metadata-dir>` - The directory to store asset database metadata (default: `<current-dir>/.db`)
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

## Commands

### `init` - Initialize Database
**Purpose:** Creates a new Photosphere media file database

**Usage:**
```bash
psi init [database-dir] [options]
```

**Arguments:**
- `[database-dir]` - The directory that will contain the media file database (defaults to current directory)

**Options:**
- `-g, --generate-key` - Generate encryption keys if they don't exist
- All global options listed above

**Example:**
```bash
psi init ~/photos
psi init ~/photos --generate-key --verbose
```

**Post-completion guidance:**
After successful initialization, the command provides next steps:
1. Change to your database directory: `cd <database-dir>`
2. Add your photos and videos: `psi add <source-media-directory>`

---

### `add` - Add Media Files
**Purpose:** Add files and directories to the Photosphere media file database

**Usage:**
```bash
psi add [database-dir] <files...> [options]
```

**Arguments:**
- `[database-dir]` - The directory containing the media file database (defaults to current directory)
- `<files...>` - Media files or directories to add to the database (required)

**Options:**
- All global options listed above

**Examples:**
```bash
psi add ~/my-photos
psi add ~/photos ~/vacation-pics ~/family-photos
psi add . /path/to/photos --verbose
```

**Real-time feedback:**
- Shows progress: Added, Ignored, Failed file counts
- Displays currently scanning file
- Safe to abort with Ctrl-C and resume later

**Summary output:**
- Number of files added, ignored, failed, already in database
- Total size and average size of added files

---

### `ui` - Start Web Interface
**Purpose:** Starts the Photosphere web user interface to view, search, and edit photos and videos

**Usage:**
```bash
psi ui [database-dir] [options]
```

**Arguments:**
- `[database-dir]` - The directory containing the media file database (defaults to current directory)

**Options:**
- `--no-open` - Disables opening the UI in the default browser
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-m, --meta <db-metadata-dir>` - The directory containing database metadata
- `-y, --yes` - Non-interactive mode

**Examples:**
```bash
psi ui
psi ui ~/photos
psi ui ~/photos --no-open
```

**Behavior:**
- Starts a web server on http://localhost:3000
- Automatically opens the browser (unless `--no-open` is specified)
- Runs in read-write mode with no authentication
- Press Ctrl+C to stop the server

---

### `configure` - Configure Cloud Storage
**Purpose:** Configure S3 credentials for cloud storage

**Usage:**
```bash
psi configure [options]
```

**Options:**
- `-p, --profile <name>` - The profile name to configure (default: "default")
- `-c, --clear` - Clear all S3 configuration files
- `-y, --yes` - Non-interactive mode

**Examples:**
```bash
psi configure
psi configure --profile production
psi configure --clear
```

**Post-configuration usage:**
Once configured, you can use S3 storage paths like:
- `psi ui s3:my-bucket/photos`
- `psi ui s3:my-bucket/photos --profile production` (for non-default profiles)

---

### `summary` - Database Summary
**Purpose:** Display a summary of the Photosphere media file database including total files, size, and tree hash

**Usage:**
```bash
psi summary [database-dir] [options]
```

**Arguments:**
- `[database-dir]` - The directory containing the media file database (defaults to current directory)

**Options:**
- All global options listed above

**Examples:**
```bash
psi summary
psi summary ~/photos
psi summary ~/photos --verbose
```

**Output Information:**
- **Total files** - Number of files in the database
- **Total size** - Combined size of all files (formatted in B/KB/MB/GB)
- **Tree root hash (short)** - First 8 characters of the Merkle tree root hash
- **Tree root hash (full)** - Complete Merkle tree root hash for verification

**Use Cases:**
- Quick overview of database contents
- Verification of database integrity using hash values
- Monitoring database growth over time
- Debugging and database health checks

---

### `verify` - Database Verification
**Purpose:** Verify the integrity of the Photosphere media file database by checking file hashes against cached values

**Usage:**
```bash
psi verify [database-dir] [file-path] [options]
```

**Arguments:**
- `[database-dir]` - The directory containing the media file database (defaults to current directory)
- `[file-path]` - Optional specific file to verify instead of entire database

**Options:**
- `--full` - Force full verification (bypass cached hash optimization)
- `-o, --output <file>` - Write verification summary to JSON file
- All global options listed above

**Examples:**
```bash
psi verify
psi verify ~/photos
psi verify ~/photos photo.jpg
psi verify ~/photos --full
psi verify ~/photos --output verification-report.json
```

**Verification Process:**
1. **Fast verification** (default): Uses cached hashes when file size/modification time unchanged
2. **Full verification** (`--full`): Recomputes all file hashes regardless of cache
3. **Single file**: Verifies just the specified file
4. **Database scan**: Identifies new, modified, and removed files

**Output Information:**
- **Total files** - Number of files processed
- **Unmodified** - Files that match their cached hashes
- **Modified** - Files with different hashes than cached (potential corruption)
- **New** - Files found in filesystem but not in database
- **Removed** - Files in database but missing from filesystem
- **Detailed lists** - Shows first 10 problematic files for each category

**Use Cases:**
- **Data integrity checks** - Detect file corruption or unauthorized modifications
- **Database consistency** - Ensure filesystem matches database state
- **Forensic analysis** - Identify changes since last verification
- **Maintenance** - Regular health checks of media collections

**Exit Codes:**
- `0` - Verification completed successfully
- `1` - Verification failed or errors encountered

---

### `replicate` - Database Replication
**Purpose:** Replicate an asset database from source to destination location with incremental sync capabilities

**Usage:**
```bash
psi replicate [source-dir] <destination-dir> [options]
```

**Arguments:**
- `[source-dir]` - Source database directory (defaults to current directory)
- `<destination-dir>` - Destination directory for replicated database (required)

**Options:**
- `-s, --src-meta <dir>` - Source metadata directory override
- `-d, --dest-meta <dir>` - Destination metadata directory override
- `--sk, --src-key <keyfile>` - Path to source encryption key file
- `--dk, --dest-key <keyfile>` - Path to destination encryption key file
- `-g, --generate-key` - Generate encryption keys if they don't exist
- All global options listed above

**Examples:**
```bash
psi replicate ~/photos ~/backup/photos
psi replicate ~/photos s3:backup-bucket/photos
psi replicate s3:source-bucket/photos ~/local-backup
psi replicate ~/photos ~/backup --sk source.key --dk backup.key
psi replicate ~/photos ~/backup --generate-key
```

**Replication Process:**
1. **Incremental sync**: Uses hash cache to identify unchanged files and skip copying
2. **Cross-storage support**: Replicates between filesystem, S3, encrypted storage
3. **Hash verification**: Verifies file integrity during copy process
4. **Progress tracking**: Shows real-time progress with batch updates
5. **Resume capability**: Can be safely interrupted and resumed

**Output Information:**
- **Total files** - Number of files processed
- **Copied** - Files that were copied to destination
- **Skipped** - Files already present with matching hashes
- **Failed** - Files that failed to copy with error details
- **Copy percentage** - Percentage of files that needed copying

**Storage Compatibility:**
- **Filesystem to filesystem**: Direct file copy operations
- **Filesystem to S3**: Upload to cloud storage
- **S3 to filesystem**: Download from cloud storage
- **Encrypted ↔ Unencrypted**: Seamless encryption/decryption during replication
- **Cross-platform**: Works across different operating systems

**Performance Features:**
- **Batch progress updates**: Reports progress every 1,000 files
- **Memory efficiency**: Streams large files without loading entirely into memory
- **Retry mechanism**: Automatic retry for failed operations
- **Hash cache optimization**: Avoids unnecessary file re-processing

**Use Cases:**
- **Backup creation**: Create full backup copies of media databases
- **Cloud migration**: Move databases between local and cloud storage
- **Load balancing**: Distribute databases across multiple locations
- **Encryption migration**: Convert between encrypted and unencrypted storage
- **Cross-platform sync**: Replicate databases between different systems

**Exit Codes:**
- `0` - Replication completed successfully
- `1` - Replication failed or had errors

---

### `compare` - Database Comparison
**Purpose:** Compare two asset databases by analyzing their Merkle trees to identify differences

**Usage:**
```bash
psi compare <source-dir> <destination-dir> [options]
```

**Arguments:**
- `<source-dir>` - Source database directory (required)
- `<destination-dir>` - Destination database directory (required)

**Options:**
- `-s, --src-meta <dir>` - Source metadata directory override
- `-d, --dest-meta <dir>` - Destination metadata directory override
- `--sk, --src-key <keyfile>` - Path to source encryption key file
- `--dk, --dest-key <keyfile>` - Path to destination encryption key file
- `-o, --output <file>` - Write comparison results to JSON file
- All global options listed above

**Examples:**
```bash
psi compare ~/photos ~/backup/photos
psi compare ~/photos s3:backup-bucket/photos
psi compare s3:source-bucket/photos ~/local-copy
psi compare ~/photos ~/backup --sk source.key --dk backup.key
psi compare ~/photos ~/backup --output comparison-report.json
```

**Comparison Process:**
1. **Fast path optimization**: Compares root hashes first for identical databases
2. **Detailed analysis**: Uses Merkle tree comparison for comprehensive differences
3. **Cryptographic verification**: Leverages SHA-256 hashes for accurate change detection
4. **Cross-storage support**: Compares databases across different storage systems

**Output Categories:**
- **Files only in source** - Files present in first database but missing from second
- **Files only in destination** - Files present in second database but missing from first
- **Modified files** - Files with same path but different content (hash mismatch)
- **Deleted files** - Files marked as deleted in the tree structure

**Display Format:**
- **Console output**: Color-coded differences with limited display (first 10 items per category)
- **JSON output**: Complete structured data for automation and further analysis
- **Summary statistics**: File counts and difference metrics

**JSON Structure:**
```json
{
  "timestamp": "2023-12-01T10:30:00.000Z",
  "treesMatch": false,
  "message": "Found 5 differences",
  "differences": {
    "filesOnlyInA": ["photo1.jpg", "video1.mp4"],
    "filesOnlyInB": ["photo2.jpg"],
    "modifiedFiles": ["photo3.jpg"],
    "deletedFiles": ["old_photo.jpg"]
  },
  "metrics": {
    "filesInTreeA": 1250,
    "filesInTreeB": 1248,
    "totalDifferences": 5
  }
}
```

**Use Cases:**
- **Backup verification** - Ensure backup copies are complete and current
- **Synchronization audit** - Verify database synchronization between locations
- **Migration validation** - Confirm successful database migration
- **Change detection** - Identify what has changed between database versions
- **Forensic analysis** - Investigate unauthorized modifications

**Performance Features:**
- **Root hash optimization** - O(1) comparison for identical databases
- **Efficient tree traversal** - Only processes differing subtrees
- **Memory efficient** - Streams through large trees without excessive memory use
- **Cross-storage compatible** - Works with any supported storage backend

**Exit Codes:**
- `0` - Comparison completed successfully (regardless of differences found)

---

### `info` - Analyze Media Files
**Purpose:** Display detailed information about media files including EXIF data, metadata, and technical specifications

**Usage:**
```bash
psi info [database-dir] <files...> [options]
```

**Arguments:**
- `[database-dir]` - The directory containing the media file database (defaults to current directory)
- `<files...>` - Media files to analyze (required)

**Options:**
- `-r, --raw` - Show raw EXIF/metadata properties
- All global options listed above

**Examples:**
```bash
psi info photo.jpg video.mp4
psi info ~/photos *.jpg --raw
psi info . /path/to/media/* --verbose
```

**Output Information:**
For each file, displays:
- **File path and database status** (✓ In database / ○ Not in database)
- **Media type** (IMAGE/VIDEO)
- **Dimensions** (width × height for images/videos)
- **Duration** (MM:SS format for videos)
- **Date taken** (from EXIF data)
- **GPS coordinates** (if available)
- **Frame rate** (for videos)
- **Audio presence** (for videos)
- **Raw metadata** (when `--raw` flag is used)

## Storage Support

The CLI supports multiple storage backends:
- **Local filesystem:** Standard file paths
- **S3-compatible storage:** `s3:bucket-name:/path` format
- **Encrypted storage:** Works with encryption keys for secure storage

## Prerequisites

The CLI automatically checks for required tools (ImageMagick, FFmpeg) and prompts for installation if needed.

## Error Handling

- All commands provide colored output for better readability
- Progress indicators show real-time status
- Safe interruption (Ctrl-C) with graceful cleanup
- Detailed error messages with verbose logging option

## Typical Workflow

1. **Initialize a database:** `psi init ~/my-photos`
2. **Add media files:** `psi add ~/my-photos ~/source-photos`
3. **View database summary:** `psi summary ~/my-photos`
4. **Verify database integrity:** `psi verify ~/my-photos`
5. **Create backup/replica:** `psi replicate ~/my-photos ~/backup/photos`
6. **Configure cloud storage (optional):** `psi configure`
7. **Start the web UI:** `psi ui ~/my-photos`
8. **Analyze specific files:** `psi info ~/my-photos photo.jpg --raw`

This CLI provides a complete workflow for managing media databases from initialization through replication, verification, analysis and web viewing.