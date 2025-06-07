# Photosphere CLI - Getting Started Guide

## Overview

The Photosphere CLI (`psi`) is a command-line tool for managing your local photo and video database. It allows you to initialize databases, add media files, check what's already indexed, and launch the web UI for viewing your media.

## Installation

### Using Pre-built Binaries

Download the appropriate binary for your platform:
- Linux: `psi`
- Windows: `psi.exe`
- macOS: `psi`

**Important**: After downloading, make sure the binary has execute permissions:

```bash
# On Linux/macOS
chmod +x psi

# Verify permissions
ls -la psi
```

The binary should show execute permissions like `-rwxr-xr-x` for the user.

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
- `-p, --profile <name>`: Suggested profile name (default: "default")
- `-c, --clear`: Clear all S3 configuration files

**Example:**
```bash
# Configure with interactive profile name prompt
psi configure

# Configure with suggested profile name
psi configure --profile backup

# Clear all configuration
psi configure --clear
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

## Cloud Storage (S3)

Photosphere supports S3-compatible storage for both local and cloud deployments. You can use AWS S3, DigitalOcean Spaces, MinIO, or any S3-compatible service.

### Configuring S3 Credentials

Use the `configure` command to set up your S3 credentials:

```bash
# Configure default profile
psi configure

# Configure a named profile
psi configure --profile backup
```

The configuration wizard will prompt you for:
- **Profile name**: A name for this configuration (default: "default")
- **S3 Endpoint URL**: Leave empty for AWS S3, or enter the URL for other providers (e.g., `https://nyc3.digitaloceanspaces.com`)
- **Region**: The S3 region (e.g., `us-east-1` for AWS, `nyc3` for DigitalOcean)
- **Access Key ID**: Your S3 access key
- **Secret Access Key**: Your S3 secret key

Credentials can be saved in two locations:
- **Local** (`.photosphere.json` in current directory): Best for project-specific credentials
- **Global** (`~/.photosphere/.photosphere.json`): Best for personal use across projects

### Using S3 Storage

Once configured, you can use S3 paths directly in commands:

```bash
# Initialize database on S3
psi init s3:my-bucket/photos

# Add files to S3-backed database
psi add s3:my-bucket/photos ~/Pictures/*.jpg

# Launch UI for S3 database
psi ui s3:my-bucket/photos
```

### Managing Profiles

You can configure multiple profiles for different S3 services or buckets:

```bash
# Configure with interactive prompt for profile name
psi configure

# Configure with a suggested profile name (can be changed interactively)
psi configure --profile aws-backup
psi configure --profile spaces-primary

# Use a specific profile (if not default)
export S3_PROFILE=aws-backup
psi ui s3:backup-bucket/photos
```

**Note**: The `--profile` flag provides a suggested name, but you'll be prompted to confirm or change it during configuration. This allows you to organize multiple S3 configurations for different environments or services.

### Clearing Configuration

To remove all S3 configuration files:

```bash
psi configure --clear
```

This will prompt for confirmation before deleting all credential files.

### Security Notes

- Credentials are stored with restrictive permissions (0600 on Unix systems)
- Never commit `.photosphere.json` files to version control
- Add `.photosphere.json` to your `.gitignore`
- Consider using environment variables for CI/CD:
  ```bash
  export AWS_ACCESS_KEY_ID=your_key
  export AWS_SECRET_ACCESS_KEY=your_secret
  export AWS_DEFAULT_REGION=us-east-1
  export AWS_ENDPOINT=https://custom.endpoint.com  # Optional
  ```

## Tips

- Use `--verbose` flag for detailed progress information
- Check files before adding to avoid duplicates: `psi check`
- The CLI automatically processes images and creates optimized versions
- Supported formats: JPEG, PNG, WebP, HEIC, and common video formats