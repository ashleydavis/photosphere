# Photosphere CLI - Getting Started Guide

## Overview

The Photosphere CLI (`psi`) is a command-line tool for managing your local photo and video database. It allows you to initialize databases, add media files, check what's already indexed, and launch the web UI for viewing your media.

## Installation

### Using Pre-built Binaries

Download the appropriate binary for your platform:
- Linux: `psi`
- Windows: `psi.exe`
- macOS: `psi`

### Building from Source

```bash
# Clone the repository
git clone <repository-url>
cd photosphere

# Install dependencies
bun install

# Build the CLI tool
cd apps/cli
bun run build-linux   # For Linux
bun run build-win     # For Windows
bun run build-mac     # For macOS
```

## Quick Start

### 1. Initialize a Database

Create a new Photosphere database in your desired directory:

```bash
psi init ~/my-photos
```

With encryption:
```bash
psi init ~/my-photos --key ~/my-key.pem --generate-key
```

### 2. Add Media Files

Add photos and videos to your database:

```bash
# Add individual files
psi add ~/my-photos ~/Pictures/vacation.jpg ~/Videos/birthday.mp4

# Add entire directories
psi add ~/my-photos ~/Pictures/2024/
```

### 3. Launch the Web UI

View and manage your media through the web interface:

```bash
psi ui ~/my-photos
```

The UI will automatically open in your default browser. Use `--no-open` to prevent auto-opening.

## Commands

### `init [database-dir]`
Initializes a new Photosphere media file database.

**Options:**
- `-m, --meta <dir>`: Metadata directory (default: `<database-dir>/.db`)
- `-k, --key <keyfile>`: Path to encryption key file
- `-g, --generate-key`: Generate encryption keys if they don't exist
- `-v, --verbose`: Enable verbose logging

**Example:**
```bash
psi init ~/photos --meta ~/photos/.metadata --generate-key
```

### `add [database-dir] <files...>`
Add files and directories to the database.

**Options:**
- `-m, --meta <dir>`: Metadata directory
- `-k, --key <keyfile>`: Path to encryption key file
- `-v, --verbose`: Enable verbose logging

**Example:**
```bash
psi add ~/photos ~/Downloads/*.jpg ~/Pictures/
```

### `check [database-dir] <files...>`
Check which files have already been added to the database.

**Options:**
- `-m, --meta <dir>`: Metadata directory
- `-k, --key <keyfile>`: Path to encryption key file
- `-v, --verbose`: Enable verbose logging

**Example:**
```bash
psi check ~/photos ~/Pictures/vacation/
```

### `ui [database-dir]`
Start the Photosphere web interface.

**Options:**
- `-m, --meta <dir>`: Metadata directory
- `-k, --key <keyfile>`: Path to encryption key file
- `--no-open`: Don't automatically open browser

**Example:**
```bash
psi ui ~/photos --no-open
```

### `configure`
Configure S3 credentials for cloud storage.

**Options:**
- `-p, --profile <name>`: Profile name (default: "default")

**Example:**
```bash
psi configure --profile backup
```

## Database Structure

Photosphere organizes your media into:
- **Original files**: Full resolution originals
- **Display versions**: Web-optimized versions
- **Thumbnails**: Small preview images
- **Metadata**: EXIF data, timestamps, and custom tags

The database directory structure:
```
my-photos/
├── .db/           # Metadata (if using default location)
├── assets/        # Original media files
├── display/       # Optimized versions
└── thumb/         # Thumbnails
```

## Encryption

To protect your media with encryption:

1. Generate a key on first init:
   ```bash
   psi init ~/photos --key ~/my-key.pem --generate-key
   ```

2. Use the same key for all operations:
   ```bash
   psi add ~/photos ~/new-photos/ --key ~/my-key.pem
   psi ui ~/photos --key ~/my-key.pem
   ```

## Cloud Storage

Configure S3-compatible storage for backups:

```bash
# Configure credentials
psi configure --profile backup

# Use S3 storage in operations
export ASSET_STORAGE_CONNECTION="s3:my-bucket:/photos"
export DB_STORAGE_CONNECTION="s3:my-bucket:/photos-db"
```

## Tips

- Use `--verbose` flag for detailed progress information
- Check files before adding to avoid duplicates: `psi check`
- The CLI automatically processes images and creates optimized versions
- Supported formats: JPEG, PNG, WebP, HEIC, and common video formats