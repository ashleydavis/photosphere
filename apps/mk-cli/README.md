# mk

A command-line tool for inspecting and visualizing merkle trees.

## Usage

```bash
# Show the merkle tree visualization
mk show <tree-path>

# Show simple visualization format
mk show <tree-path> --simple

# Print just the root hash
mk root-hash <tree-path>

# Show merkle tree from S3
mk show s3://my-bucket/database/.db
```

## Commands

- `show <tree-path>` - Visualize the merkle tree structure from a saved tree file
- `root-hash <tree-path>` - Print the root hash of the merkle tree

## Options

- `-s, --simple` - Use simple visualization format (shows only file names)
- `-v, --verbose` - Enable verbose logging
- `-h, --help` - Display help information
- `-V, --version` - Display version information

## S3 Cloud Storage Support

The `mk` tool supports loading merkle trees from S3-compatible cloud storage. When using an S3 path (e.g., `s3://bucket/path/.db`), credentials are read from environment variables:

**Required:**
- `AWS_ACCESS_KEY_ID` - Your S3 access key ID
- `AWS_SECRET_ACCESS_KEY` - Your S3 secret access key

**Optional:**
- `AWS_REGION` - AWS region (defaults to `us-east-1`)
- `AWS_ENDPOINT_URL` - Custom endpoint URL for S3-compatible services (e.g., Digital Ocean Spaces)

### Example

```bash
# Set credentials
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_REGION="us-east-1"

# Load merkle tree from S3
mk show s3://my-bucket/database/.db --simple
```

