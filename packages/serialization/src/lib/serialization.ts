//
// Binary serialization and deserialization with versioning support.
//

import { IStorage } from 'storage';
import { createHash } from 'crypto';
import { gzipSync, gunzipSync } from 'zlib';
import { serialize as bsonSerialize, deserialize as bsonDeserialize } from 'bson';
import { retry } from 'utils';

//
// Interface for writing binary data during serialization
//
export interface ISerializer {
    //
    // Write a 32-bit unsigned integer (little-endian)
    //
    writeUInt32(value: number): void;

    //
    // Write a 32-bit signed integer (little-endian)
    //
    writeInt32(value: number): void;

    //
    // Write a 64-bit unsigned integer (little-endian)
    //
    writeUInt64(value: bigint): void;

    //
    // Write a 64-bit signed integer (little-endian)
    //
    writeInt64(value: bigint): void;

    //
    // Write a 32-bit float (little-endian)
    //
    writeFloat(value: number): void;

    //
    // Write a 64-bit double (little-endian)
    //
    writeDouble(value: number): void;

    //
    // Write a boolean as a single byte (1 for true, 0 for false)
    //
    writeBoolean(value: boolean): void;

    //
    // Write an 8-bit unsigned integer
    //
    writeUInt8(value: number): void;

    //
    // Write a UTF-8 string (prefixed with 32-bit length)
    //
    writeString(value: string): void;

    //
    // Write raw buffer data (prefixed with 32-bit length)
    //
    writeBuffer(buffer: Buffer): void;

    //
    // Write raw bytes without length prefix
    //
    writeBytes(buffer: Buffer): void;

    //
    // Write BSON data (serializes object to BSON and writes with 32-bit length prefix)
    //
    writeBSON<T>(obj: T): void;

}

//
// Interface for reading binary data during deserialization
//
export interface IDeserializer {
    //
    // Read a 32-bit unsigned integer (little-endian)
    //
    readUInt32(): number;

    //
    // Read a 32-bit signed integer (little-endian)
    //
    readInt32(): number;

    //
    // Read a 64-bit unsigned integer (little-endian)
    //
    readUInt64(): bigint;

    //
    // Read a 64-bit signed integer (little-endian)
    //
    readInt64(): bigint;

    //
    // Read a 32-bit float (little-endian)
    //
    readFloat(): number;

    //
    // Read a 64-bit double (little-endian)
    //
    readDouble(): number;

    //
    // Read a boolean from a single byte
    //
    readBoolean(): boolean;

    //
    // Read an 8-bit unsigned integer
    //
    readUInt8(): number;

    //
    // Read a UTF-8 string (reads 32-bit length prefix first)
    //
    readString(): string;

    //
    // Read buffer data (reads 32-bit length prefix first)
    //
    readBuffer(): Buffer;

    //
    // Read specified number of raw bytes
    //
    readBytes(length: number): Buffer;

    //
    // Read BSON data (reads 32-bit length prefix and deserializes to object)
    //
    readBSON<T>(): T;
}

//
// Type definitions for serializer and deserializer functions
//
export type SerializerFunction<T> = (data: T, serializer: ISerializer) => void;
export type DeserializerFunction<T> = (deserializer: IDeserializer) => T;

//
// Map of version numbers to deserializer functions
//
export type DeserializerMap<T> = Record<number, DeserializerFunction<T>>;

//
// Migration function that converts data from one version to another
//
export type MigrationFunction<TFrom, TTo> = (data: TFrom) => TTo;

//
// Map of version transitions to migration functions
// Key format: "fromVersion:toVersion" (e.g., "1:2", "2:3")
//
export type MigrationMap = Record<string, (data: any) => any>;

//
// Implementation of ISerializer for writing binary data
//
export class BinarySerializer implements ISerializer {
    private buffer: Buffer;
    private position: number = 0;
    private capacity: number;

    constructor(initialCapacity: number = 1024) {
        this.capacity = initialCapacity;
        this.buffer = Buffer.alloc(this.capacity);
    }

    private ensureCapacity(bytesNeeded: number): void {
        if (this.position + bytesNeeded > this.capacity) {
            // Double the capacity until we have enough space
            let newCapacity = this.capacity;
            while (this.position + bytesNeeded > newCapacity) {
                newCapacity *= 2;
            }
            
            // Create new buffer and copy existing data
            const newBuffer = Buffer.alloc(newCapacity);
            this.buffer.copy(newBuffer, 0, 0, this.position);
            this.buffer = newBuffer;
            this.capacity = newCapacity;
        }
    }

    writeUInt32(value: number): void {
        this.ensureCapacity(4);
        this.buffer.writeUInt32LE(value, this.position);
        this.position += 4;
    }

    writeInt32(value: number): void {
        this.ensureCapacity(4);
        this.buffer.writeInt32LE(value, this.position);
        this.position += 4;
    }

    writeUInt64(value: bigint): void {
        this.ensureCapacity(8);
        this.buffer.writeBigUInt64LE(value, this.position);
        this.position += 8;
    }

    writeInt64(value: bigint): void {
        this.ensureCapacity(8);
        this.buffer.writeBigInt64LE(value, this.position);
        this.position += 8;
    }

    writeFloat(value: number): void {
        this.ensureCapacity(4);
        this.buffer.writeFloatLE(value, this.position);
        this.position += 4;
    }

    writeDouble(value: number): void {
        this.ensureCapacity(8);
        this.buffer.writeDoubleLE(value, this.position);
        this.position += 8;
    }

    writeBoolean(value: boolean): void {
        this.ensureCapacity(1);
        this.buffer.writeUInt8(value ? 1 : 0, this.position);
        this.position += 1;
    }

    writeUInt8(value: number): void {
        this.ensureCapacity(1);
        this.buffer.writeUInt8(value, this.position);
        this.position += 1;
    }

    writeString(value: string): void {
        const stringBuffer = Buffer.from(value, 'utf8');
        this.writeUInt32(stringBuffer.length);
        this.writeBytes(stringBuffer);
    }

    writeBuffer(buffer: Buffer): void {
        this.writeUInt32(buffer.length);
        this.writeBytes(buffer);
    }

    writeBytes(buffer: Buffer): void {
        this.ensureCapacity(buffer.length);
        buffer.copy(this.buffer, this.position);
        this.position += buffer.length;
    }

    writeBSON<T>(obj: T): void {
        const bsonBuffer = bsonSerialize(obj as any);
        this.writeUInt32(bsonBuffer.length);
        this.writeBytes(Buffer.from(bsonBuffer));
    }

    getBuffer(): Buffer {
        // Return only the used portion of the buffer
        return this.buffer.subarray(0, this.position);
    }
}

//
// CompressedBinarySerializer wraps BinarySerializer and automatically compresses
// the data when finished, writing the compressed length and data to the main serializer.
//
export class CompressedBinarySerializer implements ISerializer {
    private serializer: BinarySerializer;
    private mainSerializer: ISerializer;

    constructor(mainSerializer: ISerializer, initialCapacity: number = 1024) {
        this.mainSerializer = mainSerializer;
        this.serializer = new BinarySerializer(initialCapacity);
    }

    writeUInt32(value: number): void {
        this.serializer.writeUInt32(value);
    }

    writeInt32(value: number): void {
        this.serializer.writeInt32(value);
    }

    writeUInt64(value: bigint): void {
        this.serializer.writeUInt64(value);
    }

    writeInt64(value: bigint): void {
        this.serializer.writeInt64(value);
    }

    writeFloat(value: number): void {
        this.serializer.writeFloat(value);
    }

    writeDouble(value: number): void {
        this.serializer.writeDouble(value);
    }

    writeBoolean(value: boolean): void {
        this.serializer.writeBoolean(value);
    }

    writeUInt8(value: number): void {
        this.serializer.writeUInt8(value);
    }

    writeString(value: string): void {
        this.serializer.writeString(value);
    }

    writeBuffer(buffer: Buffer): void {
        this.serializer.writeBuffer(buffer);
    }

    writeBytes(buffer: Buffer): void {
        this.serializer.writeBytes(buffer);
    }

    writeBSON<T>(obj: T): void {
        this.serializer.writeBSON(obj);
    }

    //
    // Finishes writing, compresses the data, and writes it to the main serializer.
    // This must be called after all data has been written.
    //
    finish(): void {
        const buffer = this.serializer.getBuffer();
        const compressed = gzipSync(buffer, { level: 9 });
        this.mainSerializer.writeUInt32(compressed.length);
        this.mainSerializer.writeBytes(compressed);
    }
}

//
// CompressedBinaryDeserializer reads compressed data from a deserializer,
// decompresses it, and provides a BinaryDeserializer for reading the decompressed data.
//
export class CompressedBinaryDeserializer implements IDeserializer {
    private deserializer: BinaryDeserializer;

    constructor(mainDeserializer: IDeserializer) {
        // Read compressed length
        const compressedLength = mainDeserializer.readUInt32();
        // Read compressed data
        const compressed = mainDeserializer.readBytes(compressedLength);
        // Decompress
        const decompressed = gunzipSync(compressed);
        // Create deserializer from decompressed buffer
        this.deserializer = new BinaryDeserializer(decompressed);
    }

    readUInt32(): number {
        return this.deserializer.readUInt32();
    }

    readInt32(): number {
        return this.deserializer.readInt32();
    }

    readUInt64(): bigint {
        return this.deserializer.readUInt64();
    }

    readInt64(): bigint {
        return this.deserializer.readInt64();
    }

    readFloat(): number {
        return this.deserializer.readFloat();
    }

    readDouble(): number {
        return this.deserializer.readDouble();
    }

    readBoolean(): boolean {
        return this.deserializer.readBoolean();
    }

    readUInt8(): number {
        return this.deserializer.readUInt8();
    }

    readString(): string {
        return this.deserializer.readString();
    }

    readBuffer(): Buffer {
        return this.deserializer.readBuffer();
    }

    readBytes(length: number): Buffer {
        return this.deserializer.readBytes(length);
    }

    readBSON<T>(): T {
        return this.deserializer.readBSON<T>();
    }
}

//
// Implementation of IDeserializer for reading binary data
//
export class BinaryDeserializer implements IDeserializer {
    private buffer: Buffer;
    private position: number = 0;

    constructor(buffer: Buffer) {
        this.buffer = buffer;
    }

    readUInt32(): number {
        this.checkBounds(4);
        const value = this.buffer.readUInt32LE(this.position);
        this.position += 4;
        return value;
    }

    readInt32(): number {
        this.checkBounds(4);
        const value = this.buffer.readInt32LE(this.position);
        this.position += 4;
        return value;
    }

    readUInt64(): bigint {
        this.checkBounds(8);
        const value = this.buffer.readBigUInt64LE(this.position);
        this.position += 8;
        return value;
    }

    readInt64(): bigint {
        this.checkBounds(8);
        const value = this.buffer.readBigInt64LE(this.position);
        this.position += 8;
        return value;
    }

    readFloat(): number {
        this.checkBounds(4);
        const value = this.buffer.readFloatLE(this.position);
        this.position += 4;
        return value;
    }

    readDouble(): number {
        this.checkBounds(8);
        const value = this.buffer.readDoubleLE(this.position);
        this.position += 8;
        return value;
    }

    readBoolean(): boolean {
        this.checkBounds(1);
        const value = this.buffer.readUInt8(this.position);
        this.position += 1;
        return value !== 0;
    }

    readUInt8(): number {
        this.checkBounds(1);
        const value = this.buffer.readUInt8(this.position);
        this.position += 1;
        return value;
    }

    readString(): string {
        const length = this.readUInt32();
        this.checkBounds(length);
        const value = this.buffer.subarray(this.position, this.position + length).toString('utf8');
        this.position += length;
        return value;
    }

    readBuffer(): Buffer {
        const length = this.readUInt32();
        this.checkBounds(length);
        const value = this.buffer.subarray(this.position, this.position + length);
        this.position += length;
        return value;
    }

    readBytes(length: number): Buffer {
        this.checkBounds(length);
        const value = this.buffer.subarray(this.position, this.position + length);
        this.position += length;
        return value;
    }

    readBSON<T>(): T {
        const length = this.readUInt32();
        this.checkBounds(length);
        const bsonBuffer = this.buffer.subarray(this.position, this.position + length);
        this.position += length;
        return bsonDeserialize(bsonBuffer) as T;
    }

    private checkBounds(bytesNeeded: number): void {
        if (this.position + bytesNeeded > this.buffer.length) {
            throw new Error(`Cannot read ${bytesNeeded} bytes at position ${this.position}. Buffer length: ${this.buffer.length}`);
        }
    }
}

//
// Error thrown when no deserializer is found for a version
//
export class UnsupportedVersionError extends Error {
    constructor(version: number, availableVersions: number[]) {
        super(`No deserializer found for version ${version}. Available versions: ${availableVersions.join(', ')}`);
        this.name = 'UnsupportedVersionError';
    }
}


//
// V6 layout: [version 4][type 4][payload][checksum 32]. Type is 4-byte ASCII. Checksum covers version + type + payload.
//
const TYPE_CODE_LENGTH = 4;

function typeCodeToBuffer(typeCode: string): Buffer {
    if (typeCode.length !== TYPE_CODE_LENGTH) {
        throw new Error(`Type code must be exactly ${TYPE_CODE_LENGTH} ASCII characters, got "${typeCode}" (length ${typeCode.length})`);
    }
    return Buffer.from(typeCode, 'ascii');
}

//
// Saves data to storage with v6 layout: [version 4][type 4][payload][checksum 32].
// Always writes checksum covering version + type + payload.
//
export async function save<T>(
    storage: IStorage,
    filePath: string,
    data: T,
    version: number,
    typeCode: string,
    serializer: SerializerFunction<T>
): Promise<void> {
    const binarySerializer = new BinarySerializer();

    binarySerializer.writeUInt32(version);
    binarySerializer.writeBytes(typeCodeToBuffer(typeCode));
    serializer(data, binarySerializer);

    const serializedData = binarySerializer.getBuffer();
    const checksum = createHash('sha256').update(serializedData).digest();
    const finalBuffer = Buffer.concat([serializedData, checksum]);

    await retry(() => storage.write(filePath, undefined, finalBuffer));
}

//
// Loads data from storage. Prefers v6 layout [version][type][payload][checksum]; falls back to legacy [version][payload][checksum] for pre-v6 databases.
//
export async function load<T>(
    storage: IStorage,
    filePath: string,
    expectedTypeCode: string,
    deserializers: Record<number, DeserializerFunction<unknown>>,
    migrations?: MigrationMap,
    targetVersion?: number
): Promise<T | undefined> {
    const buffer = await retry(() => storage.read(filePath));
    if (!buffer) {
        return undefined;
    }

    if (buffer.length < 4) {
        throw new Error(`File '${filePath}' is too small. File has ${buffer.length} bytes, minimum 4.`);
    }

    const availableVersions = Object.keys(deserializers).map(Number).sort((a, b) => b - a);
    const finalTargetVersion = targetVersion ?? availableVersions[0];

    let version: number;
    let payload: Buffer;

    const v6MinLength = 4 + TYPE_CODE_LENGTH + 32;
    if (buffer.length >= v6MinLength) {
        const dataBuffer = buffer.subarray(0, buffer.length - 32);
        const calculatedChecksum = createHash('sha256').update(dataBuffer).digest();
        const storedChecksum = buffer.subarray(buffer.length - 32);
        if (calculatedChecksum.equals(storedChecksum)) {
            const typeCode = dataBuffer.subarray(4, 4 + TYPE_CODE_LENGTH).toString('ascii');
            if (typeCode === expectedTypeCode) {
                version = dataBuffer.readUInt32LE(0);
                payload = dataBuffer.subarray(4 + TYPE_CODE_LENGTH);
                const deserializerFunction = deserializers[version];
                if (!deserializerFunction) {
                    throw new UnsupportedVersionError(version, availableVersions);
                }
                const binaryDeserializer = new BinaryDeserializer(payload);
                let data = deserializerFunction(binaryDeserializer);
                if (version !== finalTargetVersion && migrations) {
                    data = applyMigrations(data, version, finalTargetVersion, migrations);
                }
                return data as T;
            }
        }
    }

    // Legacy format: [version 4][payload] or [version 4][payload][checksum 32]
    if (buffer.length >= 36) {
        const dataBuffer = buffer.subarray(0, buffer.length - 32);
        const calculatedChecksum = createHash('sha256').update(dataBuffer).digest();
        const storedChecksum = buffer.subarray(buffer.length - 32);
        if (calculatedChecksum.equals(storedChecksum)) {
            version = dataBuffer.readUInt32LE(0);
            payload = dataBuffer.subarray(4);
        }
        else {
            // No checksum (e.g. pre-checksum v2): try [version 4][payload]; only accept if deserialization succeeds
            const legacyVersion = buffer.readUInt32LE(0);
            const legacyPayload = buffer.subarray(4);
            const legacyDeserializer = deserializers[legacyVersion];
            if (legacyDeserializer) {
                try {
                    const binaryDeserializer = new BinaryDeserializer(legacyPayload);
                    let data = legacyDeserializer(binaryDeserializer);
                    if (legacyVersion !== finalTargetVersion && migrations) {
                        data = applyMigrations(data, legacyVersion, finalTargetVersion, migrations);
                    }
                    return data as T;
                }
                catch {
                    // Deserialization failed; treat as corrupted legacy-with-checksum and throw
                }
            }
            throw new Error(`Checksum mismatch: expected ${storedChecksum.toString('hex')}, got ${calculatedChecksum.toString('hex')}`);
        }
    }
    else {
        version = buffer.readUInt32LE(0);
        payload = buffer.subarray(4);
    }

    const deserializerFunction = deserializers[version];
    if (!deserializerFunction) {
        throw new UnsupportedVersionError(version, availableVersions);
    }

    const binaryDeserializer = new BinaryDeserializer(payload);
    let data = deserializerFunction(binaryDeserializer);

    if (version !== finalTargetVersion && migrations) {
        data = applyMigrations(data, version, finalTargetVersion, migrations);
    }

    return data as T;
}

//
// Loads only the per-file version number (first 4 bytes) from a versioned serialized file.
// Uses a stream so only the first 4 bytes are read, not the entire file.
// This is the single place that reads the version header; callers use this instead of
// reading the version bytes directly.
//
export async function loadVersion(storage: IStorage, filePath: string): Promise<number | undefined> {
    return new Promise((resolve, reject) => {
        const stream = storage.readStream(filePath);
        const versionBuffer = Buffer.alloc(4);
        let bytesRead = 0;

        stream.on('data', (chunk: Buffer) => {
            if (bytesRead < 4) {
                const toCopy = Math.min(chunk.length, 4 - bytesRead);
                chunk.copy(versionBuffer, bytesRead, 0, toCopy);
                bytesRead += toCopy;
                if (bytesRead >= 4) {
                    stream.destroy();
                    resolve(versionBuffer.readUInt32LE(0));
                }
            }
        });

        stream.on('end', () => {
            resolve(bytesRead >= 4 ? versionBuffer.readUInt32LE(0) : undefined);
        });

        stream.on('error', () => {
            resolve(undefined);
        });
    });
}

//
// Verifies a serialized file's integrity (checksum and/or version header).
// Similar to load() but doesn't deserialize the data.
//
export interface IVerifyResult {
    valid: boolean;
    size: number;
    error?: string;
}

export async function verify(
    storage: IStorage,
    filePath: string
): Promise<IVerifyResult> {
    const buffer = await retry(() => storage.read(filePath));
    if (!buffer) {
        return { valid: false, size: 0, error: "File not found or empty" };
    }

    const minLength = 4 + TYPE_CODE_LENGTH + 32;
    if (buffer.length < minLength) {
        return {
            valid: false,
            size: buffer.length,
            error: `File too small for v6 format (${buffer.length} bytes, minimum ${minLength})`
        };
    }

    const dataBuffer = buffer.subarray(0, buffer.length - 32);
    const calculatedChecksum = createHash('sha256').update(dataBuffer).digest();
    const storedChecksum = buffer.subarray(buffer.length - 32);
    if (!calculatedChecksum.equals(storedChecksum)) {
        return {
            valid: false,
            size: buffer.length,
            error: `Checksum mismatch: expected ${storedChecksum.toString('hex')}, got ${calculatedChecksum.toString('hex')}`
        };
    }

    return { valid: true, size: buffer.length };
}

//
// Applies a chain of migrations to convert data from one version to another
//
function applyMigrations(data: any, fromVersion: number, toVersion: number, migrations: MigrationMap): any {
    if (fromVersion === toVersion) {
        return data;
    }

    // Build migration path from fromVersion to toVersion
    const migrationPath = findMigrationPath(fromVersion, toVersion, migrations);
    if (!migrationPath) {
        throw new Error(`No migration path found from version ${fromVersion} to ${toVersion}`);
    }

    // Apply migrations in sequence
    let currentData = data;
    for (let i = 0; i < migrationPath.length - 1; i++) {
        const currentVersion = migrationPath[i];
        const nextVersion = migrationPath[i + 1];
        const migrationKey = `${currentVersion}:${nextVersion}`;
        const migration = migrations[migrationKey];
        
        if (!migration) {
            throw new Error(`Missing migration from version ${currentVersion} to ${nextVersion}`);
        }
        
        currentData = migration(currentData);
    }

    return currentData;
}

//
// Finds the shortest migration path between two versions
//
function findMigrationPath(fromVersion: number, toVersion: number, migrations: MigrationMap): number[] | undefined {
    // Extract all available versions from migration keys
    const versionSet = new Set<number>();
    for (const key of Object.keys(migrations)) {
        const [from, to] = key.split(':').map(Number);
        versionSet.add(from);
        versionSet.add(to);
    }
    
    const versions = Array.from(versionSet).sort((a, b) => a - b);
    
    // Use BFS to find shortest path
    const queue: { version: number; path: number[] }[] = [{ version: fromVersion, path: [fromVersion] }];
    const visited = new Set<number>();
    
    while (queue.length > 0) {
        const { version: currentVersion, path } = queue.shift()!;
        
        if (currentVersion === toVersion) {
            return path;
        }
        
        if (visited.has(currentVersion)) {
            continue;
        }
        visited.add(currentVersion);
        
        // Find all possible next versions
        for (const nextVersion of versions) {
            const migrationKey = `${currentVersion}:${nextVersion}`;
            if (migrations[migrationKey] && !visited.has(nextVersion)) {
                queue.push({
                    version: nextVersion,
                    path: [...path, nextVersion]
                });
            }
        }
    }
    
    return undefined; // No path found
}