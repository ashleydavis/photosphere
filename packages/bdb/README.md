# BDB - BSON Database

A high-performance BSON-based database library for storing collections of documents with built-in sharding and indexing capabilities.

## Setup

Open a terminal and change directory to the bdb project:

```bash
cd photosphere/packages/bdb
```

Install dependencies:

```bash
bun install
```

## Compile

Compile the code:

```bash
bun run compile
```

Compile with live reload:

```bash
bun run compile:watch
```

## Run automated tests

```bash
bun test
```

## Usage

### Creating a Database

```typescript
import { BsonDatabase } from 'bdb';
import { FileStorage } from 'storage';
import { UuidGenerator, TimestampProvider } from 'utils';

const database = new BsonDatabase(new FileStorage('./my-database'), '', new UuidGenerator(), new TimestampProvider());
```

### Working with Collections

```typescript
// Get a collection
const users = database.collection('users');

// Insert a record
await users.insertOne({
    _id: 'user-123',
    name: 'John Doe',
    email: 'john@example.com',
    createdAt: new Date().toISOString()
});
await users.commit(); // flush all pending writes to disk

// Query records
const user = await users.getOne('user-123');

// Update a record
await users.updateOne('user-123', {
    lastLogin: new Date().toISOString()
});
await users.commit();

// Delete a record
await users.deleteOne('user-123');
await users.commit();
```

### Commit and Flush

All write operations (`insertOne`, `updateOne`, `replaceOne`, `setInternalRecord`, `deleteOne`) buffer changes in memory. Nothing is written to disk until `commit()` is called.

`collection.commit()` flushes a single collection's shards, sort indexes, and merkle tree to disk. `database.commit()` commits all dirty collections and then updates the database-level merkle tree — use it when multiple collections may have changed.

Loaded data (shards, sort index pages, merkle trees) remains cached in memory after `commit()` for fast subsequent reads. This means reads after writes work correctly even before committing.

`flush()` ejects all cached data from memory, forcing the next read to reload from disk. It throws if there are uncommitted changes — always call `commit()` before `flush()`.

The recommended pattern when using a write lock:

```typescript
await database.flush();          // eject stale cache before acquiring lock
await acquireWriteLock(...);
try {
    await collection.insertOne(...);
    await collection.updateOne(...);
    await database.commit();     // write everything to disk before releasing
} finally {
    await releaseWriteLock(...);
}
```

### Creating Sort Indexes

```typescript
// Create a sort index on a field
await users.ensureSortIndex('createdAt', 'desc', 'date');

// Get sorted and paginated results
const result = await users.getSorted('createdAt', 'desc');
console.log(result.records); // Records sorted by createdAt
console.log(result.nextPageId); // ID for the next page
```

## CLI Tool

The `bdb-cli` tool provides utilities for inspecting and managing BSON databases. See the `bdb-cli` package for more information.

