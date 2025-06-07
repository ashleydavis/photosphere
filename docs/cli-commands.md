# Photosphere CLI Commands Documentation

## Overview
The Photosphere CLI (`psi`) is a command-line tool for managing your media file database. It provides commands to initialize databases, add media files, start the web UI, configure cloud storage, and analyze media file metadata.

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
3. **Configure cloud storage (optional):** `psi configure`
4. **Start the web UI:** `psi ui ~/my-photos`
5. **Analyze specific files:** `psi info ~/my-photos photo.jpg --raw`

This CLI provides a complete workflow for managing media databases from initialization through analysis and web viewing.