# BDB CLI

A command-line tool for inspecting and managing BSON databases.

## Installation

```bash
cd apps/bdb-cli
bun install
```

## Building

Build executables for different platforms:

```bash
# Linux
bun run build-linux

# Windows
bun run build-win

# macOS (Intel)
bun run build-mac-x64

# macOS (Apple Silicon)
bun run build-mac-arm64
```

## Usage

### List Collections

```bash
bdb collections <db-path>
bdb colls <db-path>
```

Lists all collections in the BSON database.

### Show Collection Details

```bash
bdb collection <db-path> <collection-name>
bdb col <db-path> <collection-name>
```

Shows details about a specific collection including shard count, sort indexes, and total records.

### List Shards

```bash
bdb shards <db-path> <collection-name>
```

Lists all shard IDs in a collection.

### Show Shard Contents

```bash
bdb shard <db-path> <collection-name> <shard-id>
bdb shard <db-path> <collection-name> <shard-id> --records  # Only show record IDs
bdb shard <db-path> <collection-name> <shard-id> --all      # Show all fields
```

Displays the contents of a specific shard.

### Show Record

```bash
bdb record <db-path> <collection-name> <record-id>
bdb record <db-path> <collection-name> <record-id> --all  # Show all fields
```

Displays a specific record from a collection.

### List Sort Indexes

```bash
bdb sort-indexes <db-path> <collection-name>
```

Lists all sort indexes for a collection.

### Visualize Sort Index

```bash
bdb sort-index <db-path> <collection-name> <field-name> <direction>
bdb sort-idx <db-path> <collection-name> <field-name> <direction>
```

Visualizes the structure of a specific sort index. Direction must be `asc` or `desc`.

### Show Sort Index Page

```bash
bdb sort-page <db-path> <collection-name> <field-name> <direction> <page-id>
bdb sort-pg <db-path> <collection-name> <field-name> <direction> <page-id>
```

Displays a specific page from a sort index.

## Examples

```bash
# List collections in a local database
bdb colls ./my-database/metadata

# Show details about the metadata collection
bdb col ./my-database/metadata metadata

# List shards in the metadata collection
bdb shards ./my-database/metadata metadata

# Show shard 5 contents
bdb shard ./my-database/metadata metadata 5

# Show a specific record
bdb record ./my-database/metadata metadata abc-123-def

# List sort indexes
bdb sort-indexes ./my-database/metadata metadata

# Show a sort index
bdb sort-index ./my-database/metadata metadata photoTakenAt desc

# Show a specific page from a sort index
bdb sort-page ./my-database/metadata metadata photoTakenAt desc page-1
```

## Options

- `-v, --verbose` - Enable verbose logging
- `--all` - Display all object fields without truncation
- `--records` - Only show record IDs (for shard command)

## License

MIT


