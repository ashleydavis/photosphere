# BDB - BSON Database

A high-performance BSON-based database library for storing collections of documents with built-in sharding and indexing capabilities.

## Features

- **Sharded Collections**: Automatically distributes records across multiple shards for improved performance
- **Sort Indexes**: B-tree based sort indexes with pagination support
- **Type-Safe**: Full TypeScript support with type inference
- **Flexible Storage**: Works with any storage backend (filesystem, S3, encrypted storage, etc.)

## Usage

### Creating a Database

```typescript
import { BsonDatabase } from 'bdb';
import { FileStorage } from 'storage';
import { UuidGenerator } from 'utils';

const database = new BsonDatabase({
    storage: new FileStorage('./my-database'),
    uuidGenerator: new UuidGenerator()
});
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

// Query records
const user = await users.getOne('user-123');

// Update a record
await users.updateOne('user-123', { 
    lastLogin: new Date().toISOString() 
});

// Delete a record
await users.deleteOne('user-123');
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

## License

MIT


