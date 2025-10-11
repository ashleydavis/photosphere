# Serialization Package

Binary serialization and deserialization with versioning support.

## Overview

This package provides utilities for saving and loading data with version headers, allowing for backwards compatibility and data format evolution over time.

## Features

- **Version Header**: Automatically includes a 32-bit version number at the beginning of each file
- **Flexible Serializers**: Use any serialization format (JSON, BSON, Protocol Buffers, etc.)
- **Version Migration**: Support multiple deserializers for different data format versions
- **Type Safety**: Full TypeScript support with generic types
- **Error Handling**: Clear error messages for unsupported versions

## Usage

### Basic Example

```typescript
import { save, load, type DeserializerMap } from 'serialization';
import { IStorage } from 'storage';

// Define your data structure
interface MyData {
    name: string;
    value: number;
}

// Create serializer function
const serialize = (data: MyData): Buffer => {
    return Buffer.from(JSON.stringify(data), 'utf8');
};

// Create deserializer functions for different versions
const deserializeV1 = (buffer: Buffer): MyData => {
    return JSON.parse(buffer.toString('utf8'));
};

// Save data
const data = { name: 'test', value: 42 };
await save(storage, 'data.bin', data, 1, serialize);

// Load data
const deserializers: DeserializerMap<MyData> = {
    1: deserializeV1,
};
const loadedData = await load(storage, 'data.bin', deserializers);
```

### Version Migration Example

```typescript
// Original data format (v1)
interface DataV1 {
    name: string;
    value: number;
}

// Extended data format (v2)
interface DataV2 extends DataV1 {
    description: string;
}

// Deserializers for both versions
const deserializers: DeserializerMap<DataV1 | DataV2> = {
    1: (buffer: Buffer): DataV1 => JSON.parse(buffer.toString('utf8')),
    2: (buffer: Buffer): DataV2 => JSON.parse(buffer.toString('utf8')),
};

// Load data - automatically uses correct deserializer based on file version
const data = await load(storage, 'data.bin', deserializers);
```

## API

### `save<T>(storage, filePath, data, version, serializer)`

Saves data to storage with a version header.

- `storage`: IStorage instance
- `filePath`: Path where to save the file
- `data`: Data to serialize
- `version`: Version number (32-bit unsigned integer)
- `serializer`: Function that converts data to Buffer

### `load<T>(storage, filePath, deserializers)`

Loads data from storage using the appropriate deserializer.

- `storage`: IStorage instance
- `filePath`: Path to the file to load
- `deserializers`: Map of version numbers to deserializer functions

Returns the deserialized data.

### Error Handling

- `UnsupportedVersionError`: Thrown when no deserializer exists for the file's version
- File errors: Thrown for missing files, empty files, or files too small to contain a version header

## File Format

```
[4 bytes: version (32-bit little-endian)] [remaining bytes: serialized data]
```

The version is stored as a 32-bit unsigned integer in little-endian format, followed by the serialized data.