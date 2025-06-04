# Photosphere CLI Configuration Guide

This guide covers all configuration options available for the Photosphere CLI tool, including command-line arguments, environment variables, and configuration files.

## Command-Line Options

### Global Options

These options are available for all CLI commands:

| Option | Description | Default |
|--------|-------------|---------|
| `[database-dir]` | Directory containing the media file database | Current directory |
| `-m, --meta <dir>` | Directory for asset database metadata | `<database-dir>/.db` |
| `-k, --key <keyfile>` | Path to private key file for encryption | None |
| `-v, --verbose` | Enable verbose logging | false |

### Command-Specific Options

#### `photosphere init`
- `-g, --generate-key` - Generate encryption keys if they don't exist

#### `photosphere ui`
- `--no-open` - Disable automatic browser opening

#### `photosphere configure`
- `-p, --profile <name>` - Profile name to configure (default: "default")
- `-c, --clear` - Clear all S3 configuration files

## Environment Variables

### S3/AWS Configuration

| Variable | Description | Example |
|----------|-------------|---------|
| `AWS_ACCESS_KEY_ID` | S3 access key ID | `AKIAIOSFODNN7EXAMPLE` |
| `AWS_SECRET_ACCESS_KEY` | S3 secret access key | `wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY` |
| `AWS_DEFAULT_REGION` | S3 region | `us-east-1` |
| `AWS_ENDPOINT` | S3 endpoint URL (for non-AWS S3) | `https://nyc3.digitaloceanspaces.com` |
| `S3_PROFILE` | Select S3 profile to use | `production` |

### Other Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `GOOGLE_API_KEY` | Google API key for reverse geocoding | None |
| `PORT` | Server port (when using `ui` command) | 3000 |
| `AUTH_TYPE` | Authentication type | `no-auth` |
| `APP_MODE` | Application mode | `readwrite` |

## Configuration Files

### S3 Configuration

S3 credentials are stored in JSON configuration files. The CLI searches for configuration in this order:

1. `.photosphere.json` in current directory (local)
2. `.photosphere` in current directory (legacy)
3. `~/.photosphere/.photosphere.json` (global)

### Configuration File Format

```json
{
  "profiles": {
    "default": {
      "endpoint": "https://nyc3.digitaloceanspaces.com",
      "region": "us-east-1",
      "accessKeyId": "your-access-key",
      "secretAccessKey": "your-secret-key"
    },
    "production": {
      "region": "us-west-2",
      "accessKeyId": "prod-access-key",
      "secretAccessKey": "prod-secret-key"
    }
  }
}
```

### Profile Selection

Profiles are selected in the following priority:
1. Command-line flag: `-p, --profile <name>`
2. Environment variable: `S3_PROFILE`
3. Default: `default`

## Storage Connection Strings

The CLI supports multiple storage backends:

| Type | Format | Example |
|------|---------|---------|
| Filesystem | `fs:path/to/directory` | `fs:/var/photosphere/data` |
| Filesystem (implicit) | `path/to/directory` | `./my-photos` |
| S3-compatible | `s3:bucket-name/path` | `s3:my-bucket/photos` |

## Usage Examples

### Basic Usage
```bash
# Initialize a new database in current directory
photosphere init

# Initialize with custom metadata directory
photosphere init ./photos -m ./photos/.metadata

# Initialize with encryption
photosphere init ./photos -k ./my-key.pem -g
```

### S3 Configuration
```bash
# Configure default S3 profile
photosphere configure

# Configure named profile
photosphere configure -p production

# Use environment variables
export AWS_ACCESS_KEY_ID=your-key
export AWS_SECRET_ACCESS_KEY=your-secret
export AWS_DEFAULT_REGION=us-east-1
photosphere add s3:my-bucket/photos

# Use specific profile
photosphere add s3:my-bucket/photos -p production
```

### Running the UI
```bash
# Start UI with default settings
photosphere ui ./photos

# Start UI without opening browser
photosphere ui ./photos --no-open

# Start UI with custom port
PORT=8080 photosphere ui ./photos
```

## Security Considerations

1. **Configuration File Permissions**: Configuration files are automatically saved with restrictive permissions (0600 on Unix systems)
2. **Encryption Keys**: Private keys can be auto-generated with `--generate-key` flag
3. **Credential Storage**: S3 credentials are stored locally and never transmitted except to the configured S3 endpoint
4. **Profile Isolation**: Different profiles can be used for different environments (dev, staging, production)

## Precedence Rules

When multiple configuration sources are available, they are applied in this order (later overrides earlier):

1. Default values
2. Global configuration file (`~/.photosphere/.photosphere.json`)
3. Local configuration file (`.photosphere.json`)
4. Environment variables
5. Command-line arguments

## Troubleshooting

### Common Issues

1. **S3 Connection Errors**: Verify credentials and endpoint URL
   ```bash
   # Test with verbose logging
   photosphere check s3:bucket-name -v
   ```

2. **Permission Denied**: Ensure the CLI has read/write access to database directories
   ```bash
   # Check permissions
   ls -la ./photos/.db
   ```

3. **Missing Configuration**: Use `photosphere configure` to set up S3 credentials
   ```bash
   # View current configuration (credentials are masked)
   photosphere configure -p default
   ```