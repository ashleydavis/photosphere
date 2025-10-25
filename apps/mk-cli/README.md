# mk

A command-line tool for inspecting and visualizing merkle trees.

## Usage

```bash
# Show the merkle tree visualization (both sort tree and merkle tree)
mk show <tree-file>

# Print just the root hash
mk root-hash <tree-file>

# Show merkle tree from S3
mk show s3://my-bucket/database/.db/tree.dat
```

## Commands

- `show <tree-file>` - Visualize the merkle tree structure from a saved tree file (displays both sort tree and merkle tree)
- `root-hash <tree-file>` - Print the root hash of the merkle tree

## Options

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

