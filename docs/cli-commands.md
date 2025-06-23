# Photosphere CLI Commands Documentation

## Overview
The Photosphere CLI (`psi`) is a command-line tool for managing your media file database. 

**CLI Tool Name:** `psi`  
**Version:** 0.0.1

## Global Options
These options are available for most commands:

- `--db <path>` - The directory that contains the media file database (defaults to current directory) 
- `-m, --meta <db-metadata-dir>` - The directory to store media file database metadata (default: `<current-dir>/.db`)
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

## Commands

### `init` - Initialize Database
**Purpose:** Creates a new Photosphere media file database.

**Usage:**
```bash
psi init [options]
```

**Options:**
- `--db <path>` - The directory that will contain the media file database (defaults to current directory)
- `-g, --generate-key` - Generate encryption keys if they don't exist
- `-m, --meta <db-metadata-dir>` - The directory to store media file database metadata (default: `<current-dir>/.db`)
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Example:**
```bash
psi init --db ~/photos
psi init --db ~/photos --generate-key --verbose
```

---

### `add` - Add Media Files
**Purpose:** Add files and directories to the Photosphere media file database.

**Usage:**
```bash
psi add <files...> [options]
```

**Arguments:**
- `<files...>` - Media files or directories to add to the database (required)

**Options:**
- `--db <path>` - The directory containing the media file database (defaults to current directory)
- `-m, --meta <db-metadata-dir>` - The directory to store media file database metadata (default: `<current-dir>/.db`)
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Examples:**
```bash
psi add --db ~/photos ~/my-photos
psi add --db ~/photos ~/vacation-pics ~/family-photos
psi add --db . /path/to/photos --verbose
```

---

### `check` - Check Media Files
**Purpose:** Check which files have already been added to the media file database to avoid duplicates.

**Usage:**
```bash
psi check <files...> [options]
```

**Arguments:**
- `<files...>` - Media files or directories to check against the database (required)

**Options:**
- `--db <path>` - The directory containing the media file database (defaults to current directory)
- `-m, --meta <db-metadata-dir>` - The directory to store media file database metadata (default: `<current-dir>/.db`)
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Examples:**
```bash
psi check --db ~/photos ~/Pictures
psi check --db ~/photos image.jpg video.mp4
psi check --db ~/photos ~/Downloads/photos
```

---

### `ui` - Start Web Interface
**Purpose:** Starts the Photosphere web user interface to view, search, and edit photos and videos.

**Usage:**
```bash
psi ui [options]
```

**Options:**
- `--db <path>` - The directory containing the media file database (defaults to current directory)
- `--no-open` - Disables opening the UI in the default browser
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-m, --meta <db-metadata-dir>` - The directory containing database metadata
- `-y, --yes` - Non-interactive mode

**Examples:**
```bash
psi ui --db .
psi ui --db ~/photos
psi ui --db ~/photos --no-open
```

**Behavior:**
- Starts a web server on http://localhost:3000
- Automatically opens the browser (unless `--no-open` is specified)
- Runs in read-write mode with no authentication
- Press Ctrl+C to stop the server

---

### `configure` - Configure Cloud Storage
**Purpose:** Configure S3 credentials for cloud storage.

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
**Purpose:** Display a summary of the Photosphere media file database including total files, size, and tree hash.

**Usage:**
```bash
psi summary [options]
```

**Options:**
- `--db <path>` - The directory containing the media file database (defaults to current directory)
- `-m, --meta <db-metadata-dir>` - The directory to store media file database metadata (default: `<current-dir>/.db`)
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Examples:**
```bash
psi summary --db .
psi summary --db ~/photos
psi summary --db ~/photos --verbose
```

---

### `verify` - Database Verification
**Purpose:** Verify the integrity of the Photosphere media file database by checking file hashes against cached values.

**Usage:**
```bash
psi verify [options]
```

**Options:**
- `--db <path>` - The directory containing the media file database (defaults to current directory)
- `--full` - Force full verification (bypass cached hash optimization)
- `-m, --meta <db-metadata-dir>` - The directory to store media file database metadata (default: `<current-dir>/.db`)
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Examples:**
```bash
psi verify --db .
psi verify --db ~/photos
psi verify --db ~/photos --full
psi verify --db ~/photos --output verification-report.json
```
**Exit Codes:**
- `0` - Verification completed successfully
- `1` - Verification failed or errors encountered

---

### `replicate` - Database Replication
**Purpose:** Replicate an media file database from source to destination location with incremental sync capabilities.

**Usage:**
```bash
psi replicate [options]
```

**Options:**
- `--db <path>` - Source database directory (defaults to current directory)
- `--dest <path>` - Destination directory for replicated database (required)
- `-m, --meta <dir>` - Source metadata directory override
- `-k, --key <keyfile>` - Path to source encryption key file
- `-d, --dest-meta <dir>` - Destination metadata directory override
- `--dk, --dest-key <keyfile>` - Path to destination encryption key file
- `-g, --generate-key` - Generate encryption keys if they don't exist
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Examples:**
```bash
psi replicate --db ~/photos --dest ~/backup/photos
psi replicate --db ~/photos --dest s3:backup-bucket/photos
psi replicate --db s3:source-bucket/photos --dest ~/local-backup
psi replicate --db ~/photos --dest ~/backup --key source.key --dest-key backup.key
psi replicate --db ~/photos --dest ~/backup --generate-key
```

**Exit Codes:**
- `0` - Replication completed successfully
- `1` - Replication failed or had errors

---

### `compare` - Database Comparison
**Purpose:** Compare two media file databases by analyzing their Merkle trees to identify differences

**Usage:**
```bash
psi compare [options]
```

**Options:**
- `--db <path>` - Source database directory (required)
- `--dest <path>` - Destination database directory (required)
- `-s, --src-meta <dir>` - Source metadata directory override
- `-d, --dest-meta <dir>` - Destination metadata directory override
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Examples:**
```bash
psi compare --db ~/photos --dest ~/backup/photos
psi compare --db ~/photos --dest s3:backup-bucket/photos
psi compare --db s3:source-bucket/photos --dest ~/local-copy
psi compare --db ~/photos --dest ~/backup --sk source.key --dk backup.key
psi compare --db ~/photos --dest ~/backup --output comparison-report.json
```

**Exit Codes:**
- `0` - Comparison completed successfully (regardless of differences found)

---

### `info` - Analyze Media Files
**Purpose:** Display detailed information about media files including EXIF data, metadata, and technical specifications.

**Usage:**
```bash
psi info <files...> [options]
```

**Arguments:**
- `<files...>` - Media files to analyze (required)

**Options:**
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Examples:**
```bash
psi info photo.jpg video.mp4
psi info /path/to/media/* --verbose
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

---

### `tools` - Check Required Tools
**Purpose:** Check the status of all required media processing tools (ImageMagick, ffmpeg, ffprobe).

**Usage:**
```bash
psi tools [options]
```

**Options:**
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Examples:**
```bash
psi tools
```

**Output Information:**
- **ImageMagick**: Status and version information
- **FFmpeg**: Status and version information  
- **FFprobe**: Status and version information
- **Installation prompts**: Guidance for installing missing tools

---

### `examples` - Show Usage Examples
**Purpose:** Display usage examples for all CLI commands categorized by command type.

**Usage:**
```bash
psi examples [options]
```

**Options:**
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Examples:**
```bash
psi examples
```

---

### `bug-report` - Generate Bug Report
**Purpose:** Generate a bug report for GitHub with system information and logs.

**Usage:**
```bash
psi bug-report [options]
```

**Options:**
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)
- `--no-browser` - Don't open the browser automatically

**Examples:**
```bash
psi bug-report
psi bug-report --no-browser
```

---

### `debug merkle-tree` - Visualize Merkle Tree
**Purpose:** Visualize the merkle tree structure of the media file database for debugging purposes.

**Usage:**
```bash
psi debug merkle-tree [options]
```

**Options:**
- `--db <path>` - The directory containing the media file database (defaults to current directory)
- `-m, --meta <db-metadata-dir>` - The directory to store media file database metadata (default: `<current-dir>/.db`)
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)

**Examples:**
```bash
psi debug merkle-tree --db .
psi debug merkle-tree --db ~/photos
```

---

### `debug hash-cache` - Display Hash Cache Information
**Purpose:** Display information about the local and database hash caches for debugging purposes.

**Usage:**
```bash
psi debug hash-cache [options]
```

**Options:**
- `--db <path>` - The directory containing the media file database (defaults to current directory)
- `-m, --meta <db-metadata-dir>` - The directory to store media file database metadata (default: `<current-dir>/.db`)
- `-k, --key <keyfile>` - Path to the private key file for encryption
- `-v, --verbose` - Enables verbose logging
- `-y, --yes` - Non-interactive mode (use command line arguments and defaults)
- `-t, --type <type>` - Cache type to display: 'local', 'database', or 'both' (default: 'both')

**Examples:**
```bash
psi debug hash-cache --db .
psi debug hash-cache --db . -t local
psi debug hash-cache --db ~/photos -t database
```

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

1. **Initialize a database:** `psi init --db ~/my-photos`
2. **Add media files:** `psi add --db ~/my-photos ~/source-photos`
3. **View database summary:** `psi summary --db ~/my-photos`
4. **Verify database integrity:** `psi verify --db ~/my-photos`
5. **Create backup/replica:** `psi replicate --db ~/my-photos --dest ~/backup/photos`
6. **Configure cloud storage (optional):** `psi configure`
7. **Start the web UI:** `psi ui --db ~/my-photos`
8. **Analyze specific files:** `psi info photo.jpg`

This CLI provides a complete workflow for managing media databases from initialization through replication, verification, analysis and web viewing.
