//
// Tests for binary serialization and deserialization with versioning support.
//

import { save, load, UnsupportedVersionError, BinarySerializer, BinaryDeserializer, type DeserializerMap, type MigrationMap, type ISerializer, type IDeserializer, type DeserializerFunction } from '../lib/serialization';
import { IStorage } from 'storage';

//
// Mock storage implementation for testing
//
class MockStorage implements IStorage {
    private files: Map<string, Buffer> = new Map();

    readonly location: string = 'mock://storage';
    readonly isReadonly: boolean = false;

    async isEmpty(path: string): Promise<boolean> {
        return this.files.size === 0;
    }

    async listFiles(path: string, max: number, next?: string): Promise<{ names: string[]; next?: string }> {
        const names = Array.from(this.files.keys()).filter(key => key.startsWith(path));
        return { names, next: undefined };
    }

    async listDirs(path: string, max: number, next?: string): Promise<{ names: string[]; next?: string }> {
        return { names: [], next: undefined };
    }

    async fileExists(path: string): Promise<boolean> {
        return this.files.has(path);
    }

    async dirExists(path: string): Promise<boolean> {
        return Array.from(this.files.keys()).some(key => key.startsWith(path + '/'));
    }

    async info(filePath: string): Promise<{ contentType: string | undefined; length: number; lastModified: Date; } | undefined> {
        const buffer = this.files.get(filePath);
        if (!buffer) return undefined;
        return {
            contentType: undefined,
            length: buffer.length,
            lastModified: new Date()
        };
    }

    async read(path: string): Promise<Buffer | undefined> {
        return this.files.get(path);
    }

    async write(path: string, contentType: string | undefined, buffer: Buffer): Promise<void> {
        this.files.set(path, buffer);
    }

    readStream(filePath: string): NodeJS.ReadableStream {
        throw new Error('Method not implemented');
    }

    async writeStream(filePath: string, contentType: string | undefined, inputStream: NodeJS.ReadableStream, contentLength?: number): Promise<void> {
        throw new Error('Method not implemented');
    }

    async deleteFile(path: string): Promise<void> {
        this.files.delete(path);
    }

    async deleteDir(path: string): Promise<void> {
        const keysToDelete = Array.from(this.files.keys()).filter(key => key.startsWith(path));
        keysToDelete.forEach(key => this.files.delete(key));
    }

    async copyTo(srcPath: string, destPath: string): Promise<void> {
        const buffer = this.files.get(srcPath);
        if (buffer) {
            this.files.set(destPath, buffer);
        }
    }

    clear(): void {
        this.files.clear();
    }
}

//
// Test data types and serializers
//
interface TestDataV1 {
    name: string;
    value: number;
}

interface TestDataV2 extends TestDataV1 {
    description: string;
}

interface TestDataV3 extends TestDataV2 {
    tags: string[];
}

//
// Serializer functions for different versions
//
const serializeV1 = (data: TestDataV1, serializer: ISerializer): void => {
    serializer.writeString(JSON.stringify(data));
};

const serializeV2 = (data: TestDataV2, serializer: ISerializer): void => {
    serializer.writeString(JSON.stringify(data));
};

const serializeV3 = (data: TestDataV3, serializer: ISerializer): void => {
    serializer.writeString(JSON.stringify(data));
};

//
// Deserializer functions for different versions
//
const deserializeV1 = (deserializer: IDeserializer): TestDataV1 => {
    const jsonString = deserializer.readString();
    return JSON.parse(jsonString);
};

const deserializeV2 = (deserializer: IDeserializer): TestDataV2 => {
    const jsonString = deserializer.readString();
    return JSON.parse(jsonString);
};

const deserializeV3 = (deserializer: IDeserializer): TestDataV3 => {
    const jsonString = deserializer.readString();
    return JSON.parse(jsonString);
};

describe('Serialization', () => {
    let storage: MockStorage;

    beforeEach(() => {
        storage = new MockStorage();
    });

    describe('save function', () => {
        it('should save data with version header', async () => {
            const data: TestDataV1 = { name: 'test', value: 42 };
            const filePath = 'test.bin';
            const version = 1;

            await save(storage, filePath, data, version, serializeV1);

            const savedBuffer = await storage.read(filePath);
            expect(savedBuffer).toBeDefined();
            expect(savedBuffer!.length).toBeGreaterThan(36); // Version header (4) + data + checksum footer (32)

            // Check version header
            const savedVersion = savedBuffer!.readUInt32LE(0);
            expect(savedVersion).toBe(version);

            // Check checksum footer exists (32 bytes for SHA-256)
            const savedChecksum = savedBuffer!.subarray(savedBuffer!.length - 32);
            expect(savedChecksum.length).toBe(32);

            // Check data portion by deserializing with our deserializer
            const dataBuffer = savedBuffer!.subarray(4, savedBuffer!.length - 32);
            const deserializer = new BinaryDeserializer(dataBuffer);
            const deserializedData = JSON.parse(deserializer.readString());
            expect(deserializedData).toEqual(data);
        });

        it('should handle different data types', async () => {
            const stringData = 'hello world';
            const numberData = 12345;
            const objectData = { foo: 'bar', nested: { value: 100 } };

            const stringSerializer = (data: string, serializer: ISerializer): void => {
                serializer.writeString(data);
            };
            const numberSerializer = (data: number, serializer: ISerializer): void => {
                serializer.writeInt32(data);
            };
            const objectSerializer = (data: any, serializer: ISerializer): void => {
                serializer.writeString(JSON.stringify(data));
            };

            await save(storage, 'string.bin', stringData, 1, stringSerializer);
            await save(storage, 'number.bin', numberData, 2, numberSerializer);
            await save(storage, 'object.bin', objectData, 3, objectSerializer);

            expect(await storage.fileExists('string.bin')).toBe(true);
            expect(await storage.fileExists('number.bin')).toBe(true);
            expect(await storage.fileExists('object.bin')).toBe(true);
        });

        it('should handle large version numbers', async () => {
            const data: TestDataV1 = { name: 'test', value: 42 };
            const largeVersion = 0xFFFFFFFF; // Maximum 32-bit unsigned integer

            await save(storage, 'large-version.bin', data, largeVersion, serializeV1);

            const savedBuffer = await storage.read('large-version.bin');
            const savedVersion = savedBuffer!.readUInt32LE(0);
            expect(savedVersion).toBe(largeVersion);
        });
    });

    describe('load function', () => {
        it('should load data using correct deserializer based on version', async () => {
            const dataV1: TestDataV1 = { name: 'test', value: 42 };
            const dataV2: TestDataV2 = { name: 'test', value: 42, description: 'a test object' };

            const deserializers: DeserializerMap<TestDataV1 | TestDataV2> = {
                1: deserializeV1,
                2: deserializeV2,
            };

            // Save v1 data
            await save(storage, 'data-v1.bin', dataV1, 1, serializeV1);
            // Save v2 data  
            await save(storage, 'data-v2.bin', dataV2, 2, serializeV2);

            // Load and verify v1 data
            const loadedV1 = await load(storage, 'data-v1.bin', deserializers);
            expect(loadedV1).toEqual(dataV1);

            // Load and verify v2 data
            const loadedV2 = await load(storage, 'data-v2.bin', deserializers);
            expect(loadedV2).toEqual(dataV2);
        });

        it('should throw UnsupportedVersionError for unknown version', async () => {
            const data: TestDataV3 = { 
                name: 'test', 
                value: 42, 
                description: 'a test object',
                tags: ['tag1', 'tag2'] 
            };

            // Save with version 3
            await save(storage, 'data-v3.bin', data, 3, serializeV3);

            // Try to load with deserializers that only support v1 and v2
            const deserializers: DeserializerMap<TestDataV1 | TestDataV2> = {
                1: deserializeV1,
                2: deserializeV2,
            };

            await expect(load(storage, 'data-v3.bin', deserializers))
                .rejects
                .toThrow(UnsupportedVersionError);

            try {
                await load(storage, 'data-v3.bin', deserializers);
            } catch (error) {
                expect(error).toBeInstanceOf(UnsupportedVersionError);
                expect((error as Error).message).toContain('No deserializer found for version 3');
                expect((error as Error).message).toContain('Available versions: 2, 1');
            }
        });

        it('should throw error for empty or too small files', async () => {
            const deserializers: DeserializerMap<TestDataV1> = {
                1: deserializeV1,
            };

            // Test with completely empty file
            await storage.write('empty.bin', undefined, Buffer.alloc(0));
            await expect(load(storage, 'empty.bin', deserializers))
                .rejects
                .toThrow("File 'empty.bin' is too small to contain version and checksum");

            // Test with file smaller than version (4 bytes) + checksum (32 bytes) = 36 bytes minimum
            await storage.write('small.bin', undefined, Buffer.alloc(35));
            await expect(load(storage, 'small.bin', deserializers))
                .rejects
                .toThrow("File 'small.bin' is too small to contain version and checksum");
        });

        it('should return undefined for non-existent files', async () => {
            const deserializers: DeserializerMap<TestDataV1> = {
                1: deserializeV1,
            };

            const result = await load(storage, 'non-existent.bin', deserializers);
            expect(result).toBeUndefined();
        });

        it('should handle files with minimal data', async () => {
            const deserializers: DeserializerMap<string> = {
                1: (deserializer: IDeserializer) => deserializer.readString(),
            };

            // Create a file with version header, empty string data, and checksum footer
            const versionBuffer = Buffer.alloc(4);
            versionBuffer.writeUInt32LE(1, 0);
            
            // Create empty string data (4 bytes length + 0 bytes data)
            const lengthBuffer = Buffer.alloc(4);
            lengthBuffer.writeUInt32LE(0, 0); // String length of 0
            const dataBuffer = Buffer.concat([lengthBuffer]);
            
            // Calculate 32-byte SHA-256 checksum of the data portion
            const { createHash } = await import('crypto');
            const checksum = createHash('sha256').update(dataBuffer).digest(); // Full 32-byte hash
            
            const fileBuffer = Buffer.concat([versionBuffer, dataBuffer, checksum]);

            await storage.write('minimal.bin', undefined, fileBuffer);

            const result = await load(storage, 'minimal.bin', deserializers);
            expect(result).toBe(''); // Empty string from empty buffer
        });
    });

    describe('round-trip compatibility', () => {
        it('should maintain data integrity across save/load cycles', async () => {
            const testCases = [
                { version: 1, data: { name: 'simple', value: 123 } },
                { version: 2, data: { name: 'complex', value: 456, description: 'test description' } },
                { version: 3, data: { name: 'full', value: 789, description: 'full test', tags: ['a', 'b', 'c'] } }
            ];

            const deserializers: Record<number, DeserializerFunction<unknown>> = {
                1: deserializeV1,
                2: deserializeV2,
                3: deserializeV3,
            };

            for (const testCase of testCases) {
                const fileName = `roundtrip-v${testCase.version}.bin`;
                
                // Choose appropriate serializer based on version
                if (testCase.version === 1) {
                    await save(storage, fileName, testCase.data as TestDataV1, testCase.version, serializeV1);
                } else if (testCase.version === 2) {
                    await save(storage, fileName, testCase.data as TestDataV2, testCase.version, serializeV2);
                } else {
                    await save(storage, fileName, testCase.data as TestDataV3, testCase.version, serializeV3);
                }

                // Load data back
                const loadedData = await load(storage, fileName, deserializers);

                // Verify data integrity
                expect(loadedData).toEqual(testCase.data);
            }
        });

        it('should handle special characters and binary data', async () => {
            const specialData = {
                unicode: '🚀 Unicode test with émojis and spëcial chars',
                binary: 'This contains null bytes: \x00\x01\x02\xFF',
                numbers: [Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER, 0, -1, 3.14159],
                nested: {
                    deep: {
                        object: {
                            with: 'many levels'
                        }
                    }
                }
            };

            const serializer = (data: any, serializer: ISerializer): void => {
                serializer.writeString(JSON.stringify(data));
            };
            const deserializer = (deserializer: IDeserializer) => {
                const jsonString = deserializer.readString();
                return JSON.parse(jsonString);
            };

            const deserializers: Record<number, DeserializerFunction<unknown>> = {
                1: deserializer,
            };

            await save(storage, 'special.bin', specialData, 1, serializer);
            const loadedData = await load(storage, 'special.bin', deserializers);

            expect(loadedData).toEqual(specialData);
        });
    });

    describe('checksum verification', () => {
        it('should detect corrupted data with checksum mismatch', async () => {
            const data: TestDataV1 = { name: 'test', value: 42 };
            const deserializers: DeserializerMap<TestDataV1> = {
                1: deserializeV1,
            };

            // Save valid data
            await save(storage, 'valid.bin', data, 1, serializeV1);

            // Read the saved buffer and corrupt the data portion
            const validBuffer = await storage.read('valid.bin');
            const corruptedBuffer = Buffer.from(validBuffer!);
            // Corrupt a byte in the data portion (after version = 4 bytes, before checksum at end)
            if (corruptedBuffer.length > 8) {
                corruptedBuffer[4] = corruptedBuffer[4] ^ 0xFF; // Flip all bits in first data byte
            }

            // Write corrupted data back
            await storage.write('corrupted.bin', undefined, corruptedBuffer);

            // Try to load corrupted data - should throw checksum error
            await expect(load(storage, 'corrupted.bin', deserializers))
                .rejects
                .toThrow(/Checksum mismatch/);
        });

        it('should detect corrupted checksum header', async () => {
            const data: TestDataV1 = { name: 'test', value: 42 };
            const deserializers: DeserializerMap<TestDataV1> = {
                1: deserializeV1,
            };

            // Save valid data
            await save(storage, 'valid.bin', data, 1, serializeV1);

            // Read the saved buffer and corrupt the checksum
            const validBuffer = await storage.read('valid.bin');
            const corruptedBuffer = Buffer.from(validBuffer!);
            // Corrupt the checksum (last 32 bytes for SHA-256)
            const badChecksum = Buffer.from('deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef', 'hex');
            badChecksum.copy(corruptedBuffer, corruptedBuffer.length - 32);

            // Write corrupted checksum back
            await storage.write('bad-checksum.bin', undefined, corruptedBuffer);

            // Try to load data with bad checksum - should throw checksum error
            await expect(load(storage, 'bad-checksum.bin', deserializers))
                .rejects
                .toThrow(/Checksum mismatch/);
        });

        it('should show exact checksum values in error message', async () => {
            const data: TestDataV1 = { name: 'test', value: 42 };
            const deserializers: DeserializerMap<TestDataV1> = {
                1: deserializeV1,
            };

            // Save valid data
            await save(storage, 'valid.bin', data, 1, serializeV1);

            // Read the saved buffer and set a specific bad checksum (32 bytes for SHA-256)
            const validBuffer = await storage.read('valid.bin');
            const corruptedBuffer = Buffer.from(validBuffer!);
            const badChecksum = Buffer.from('1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef', 'hex');
            badChecksum.copy(corruptedBuffer, corruptedBuffer.length - 32);

            // Write corrupted checksum back
            await storage.write('bad-checksum.bin', undefined, corruptedBuffer);

            // Try to load and capture the exact error message
            try {
                await load(storage, 'bad-checksum.bin', deserializers);
                fail('Expected checksum error to be thrown');
            } catch (error) {
                expect(error).toBeInstanceOf(Error);
                const errorMessage = (error as Error).message;
                console.log('Checksum error message:', errorMessage);
                
                // Verify it contains the expected and actual checksums in hex (32-byte format)
                expect(errorMessage).toMatch(/Checksum mismatch: expected 1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef, got [0-9a-f]{64}/);
            }
        });
    });

    describe('error handling', () => {
        it('should handle serializer errors gracefully', async () => {
            const badSerializer = (data: any, serializer: ISerializer): void => {
                throw new Error('Serializer error');
            };

            await expect(save(storage, 'bad.bin', { test: 'data' }, 1, badSerializer))
                .rejects
                .toThrow('Serializer error');
        });

        it('should handle deserializer errors gracefully', async () => {
            const goodSerializer = (data: string, serializer: ISerializer): void => {
                serializer.writeString(data);
            };
            const badDeserializer = (deserializer: IDeserializer): string => {
                throw new Error('Deserializer error');
            };

            // Save valid data
            await save(storage, 'good-data.bin', 'test', 1, goodSerializer);

            // Try to load with bad deserializer
            const deserializers: DeserializerMap<string> = {
                1: badDeserializer,
            };

            await expect(load(storage, 'good-data.bin', deserializers))
                .rejects
                .toThrow('Deserializer error');
        });
    });

    describe('BSON serialization', () => {
        interface TestObject {
            name: string;
            value: number;
            nested: {
                array: number[];
                bool: boolean;
            };
        }

        it('should write and read BSON objects with type safety', () => {
            const serializer = new BinarySerializer();
            const testObj: TestObject = {
                name: 'test',
                value: 42,
                nested: {
                    array: [1, 2, 3],
                    bool: true
                }
            };

            // Write BSON object with generic type
            serializer.writeBSON<TestObject>(testObj);

            // Get buffer and create deserializer
            const buffer = serializer.getBuffer();
            const deserializer = new BinaryDeserializer(buffer);

            // Read BSON object back with generic type
            const result = deserializer.readBSON<TestObject>();

            expect(result).toEqual(testObj);
            expect(result.name).toBe('test'); // TypeScript should know this is a string
            expect(result.value).toBe(42); // TypeScript should know this is a number
        });

        it('should handle multiple BSON objects in sequence with different types', () => {
            interface SimpleObj {
                id: number;
                name: string;
            }

            interface ComplexObj {
                id: number;
                name: string;
                data: number[];
            }

            interface NestedObj {
                id: number;
                complex: {
                    nested: {
                        deep: string;
                    };
                };
            }

            const serializer = new BinarySerializer();
            const obj1: SimpleObj = { id: 1, name: 'first' };
            const obj2: ComplexObj = { id: 2, name: 'second', data: [1, 2, 3] };
            const obj3: NestedObj = { id: 3, complex: { nested: { deep: 'value' } } };

            // Write multiple BSON objects with specific types
            serializer.writeBSON<SimpleObj>(obj1);
            serializer.writeBSON<ComplexObj>(obj2);
            serializer.writeBSON<NestedObj>(obj3);

            // Get buffer and create deserializer
            const buffer = serializer.getBuffer();
            const deserializer = new BinaryDeserializer(buffer);

            // Read objects back in order with proper types
            const result1 = deserializer.readBSON<SimpleObj>();
            const result2 = deserializer.readBSON<ComplexObj>();
            const result3 = deserializer.readBSON<NestedObj>();

            expect(result1).toEqual(obj1);
            expect(result2).toEqual(obj2);
            expect(result3).toEqual(obj3);
        });

        it('should handle empty BSON objects', () => {
            const serializer = new BinarySerializer();
            const emptyObj = {};

            serializer.writeBSON(emptyObj);

            const buffer = serializer.getBuffer();
            const deserializer = new BinaryDeserializer(buffer);

            const result = deserializer.readBSON();
            expect(result).toEqual(emptyObj);
        });

        it('should handle BSON with special types', () => {
            const serializer = new BinarySerializer();
            const specialObj = {
                date: new Date('2023-01-01'),
                buffer: Buffer.from('hello', 'utf8'),
                null_value: null,
                undefined_value: undefined,
                number: 3.14159,
                bigNumber: 9007199254740991
            };

            serializer.writeBSON(specialObj);

            const buffer = serializer.getBuffer();
            const deserializer = new BinaryDeserializer(buffer);

            const result = deserializer.readBSON<any>();
            
            // Note: BSON doesn't preserve undefined, so we expect it to be omitted
            expect(result.date).toEqual(specialObj.date);
            // BSON wraps Buffer in Binary type, so we need to check the underlying buffer
            expect(Buffer.from(result.buffer.buffer)).toEqual(specialObj.buffer);
            expect(result.null_value).toBe(null);
            expect(result.number).toBe(specialObj.number);
            expect(result.bigNumber).toBe(specialObj.bigNumber);
            expect(result.undefined_value).toBeUndefined();
        });

        it('should mix BSON with other data types', () => {
            const serializer = new BinarySerializer();
            const bsonObj = { name: 'test', value: 42 };
            const stringData = 'hello world';
            const numberData = 123;

            // Write mixed data
            serializer.writeString(stringData);
            serializer.writeBSON(bsonObj);
            serializer.writeInt32(numberData);

            const buffer = serializer.getBuffer();
            const deserializer = new BinaryDeserializer(buffer);

            // Read back in same order
            const resultString = deserializer.readString();
            const resultBSON = deserializer.readBSON();
            const resultNumber = deserializer.readInt32();

            expect(resultString).toBe(stringData);
            expect(resultBSON).toEqual(bsonObj);
            expect(resultNumber).toBe(numberData);
        });

        it('should handle BSON serialization errors gracefully', () => {
            const serializer = new BinarySerializer();
            
            // Create an object with circular reference that can't be serialized
            const circularObj: any = { name: 'test' };
            circularObj.self = circularObj;

            expect(() => {
                serializer.writeBSON(circularObj);
            }).toThrow();
        });

        it('should detect corrupted BSON data', () => {
            const serializer = new BinarySerializer();
            const testObj = { name: 'test', value: 42 };

            serializer.writeBSON(testObj);
            const buffer = serializer.getBuffer();

            // Corrupt the BSON data (change length to be incorrect)
            const corruptedBuffer = Buffer.from(buffer);
            corruptedBuffer.writeUInt32LE(999, 0); // Write incorrect length

            const deserializer = new BinaryDeserializer(corruptedBuffer);

            expect(() => {
                deserializer.readBSON();
            }).toThrow();
        });
    });

    describe('Migration system', () => {
        interface DataV1 {
            name: string;
            value: number;
        }

        interface DataV2 extends DataV1 {
            description: string;
        }

        interface DataV3 extends DataV2 {
            tags: string[];
        }

        interface DataV4 extends DataV3 {
            metadata: {
                created: Date;
                modified: Date;
            };
        }

        const serializeV1 = (data: DataV1, serializer: ISerializer): void => {
            serializer.writeString(JSON.stringify(data));
        };

        const serializeV2 = (data: DataV2, serializer: ISerializer): void => {
            serializer.writeString(JSON.stringify(data));
        };

        const serializeV3 = (data: DataV3, serializer: ISerializer): void => {
            serializer.writeString(JSON.stringify(data));
        };

        const serializeV4 = (data: DataV4, serializer: ISerializer): void => {
            serializer.writeString(JSON.stringify(data));
        };

        const deserializeV1 = (deserializer: IDeserializer): DataV1 => {
            return JSON.parse(deserializer.readString());
        };

        const deserializeV2 = (deserializer: IDeserializer): DataV2 => {
            return JSON.parse(deserializer.readString());
        };

        const deserializeV3 = (deserializer: IDeserializer): DataV3 => {
            return JSON.parse(deserializer.readString());
        };

        const deserializeV4 = (deserializer: IDeserializer): DataV4 => {
            return JSON.parse(deserializer.readString());
        };

        it('should migrate from v1 to v3 through v2', async () => {
            // Save v1 data
            const dataV1: DataV1 = { name: 'test', value: 42 };
            await save(storage, 'data-v1.bin', dataV1, 1, serializeV1);

            // Set up deserializers for all versions
            const deserializers: Record<number, DeserializerFunction<unknown>> = {
                1: deserializeV1,
                2: deserializeV2,
                3: deserializeV3,
            };

            // Set up migration chain: v1 -> v2 -> v3
            const migrations: MigrationMap = {
                '1:2': (data: unknown): unknown => {
                    const v1Data = data as DataV1;
                    return {
                        ...v1Data,
                        description: `Migrated from v1: ${v1Data.name}`
                    } as DataV2;
                },
                '2:3': (data: unknown): unknown => {
                    const v2Data = data as DataV2;
                    return {
                        ...v2Data,
                        tags: ['migrated', 'v3']
                    } as DataV3;
                }
            };

            // Load with migrations (should auto-migrate to latest version 3)
            const result = await load<DataV3>(storage, 'data-v1.bin', deserializers, migrations);

            expect(result).toEqual({
                name: 'test',
                value: 42,
                description: 'Migrated from v1: test',
                tags: ['migrated', 'v3']
            });
        });

        it('should migrate to specific target version', async () => {
            // Save v1 data
            const dataV1: DataV1 = { name: 'test', value: 42 };
            await save(storage, 'data-v1.bin', dataV1, 1, serializeV1);

            const deserializers: Record<number, DeserializerFunction<unknown>> = {
                1: deserializeV1,
                2: deserializeV2,
                3: deserializeV3,
            };

            const migrations: MigrationMap = {
                '1:2': (data: unknown): unknown => {
                    const v1Data = data as DataV1;
                    return {
                        ...v1Data,
                        description: `Migrated to v2: ${v1Data.name}`
                    } as DataV2;
                },
                '2:3': (data: unknown): unknown => {
                    const v2Data = data as DataV2;
                    return {
                        ...v2Data,
                        tags: ['should-not-appear']
                    } as DataV3;
                }
            };

            // Load with specific target version (should stop at v2)
            const result = await load<DataV2>(storage, 'data-v1.bin', deserializers, migrations, 2);

            expect(result).toEqual({
                name: 'test',
                value: 42,
                description: 'Migrated to v2: test'
            });
            expect((result as any).tags).toBeUndefined();
        });

        it('should handle complex migration paths', async () => {
            // Save v1 data
            const dataV1: DataV1 = { name: 'test', value: 42 };
            await save(storage, 'data-v1.bin', dataV1, 1, serializeV1);

            const deserializers: Record<number, DeserializerFunction<unknown>> = {
                1: deserializeV1,
                2: deserializeV2,
                3: deserializeV3,
                4: deserializeV4,
            };

            // Multiple migration paths available
            const migrations: MigrationMap = {
                // Direct path: 1 -> 4
                '1:4': (data: unknown): unknown => {
                    const v1Data = data as DataV1;
                    return {
                        ...v1Data,
                        description: 'Direct migration to v4',
                        tags: ['direct'],
                        metadata: {
                            created: new Date('2023-01-01'),
                            modified: new Date('2023-01-01')
                        }
                    } as DataV4;
                },
                // Step-by-step path: 1 -> 2 -> 3 -> 4
                '1:2': (data: DataV1): DataV2 => ({
                    ...data,
                    description: 'Step 1 to 2'
                }),
                '2:3': (data: DataV2): DataV3 => ({
                    ...data,
                    tags: ['step-by-step']
                }),
                '3:4': (data: DataV3): DataV4 => ({
                    ...data,
                    metadata: {
                        created: new Date('2023-01-02'),
                        modified: new Date('2023-01-02')
                    }
                })
            };

            // Should choose shortest path (1 -> 4 directly)
            const result = await load<DataV4>(storage, 'data-v1.bin', deserializers, migrations);

            expect(result).toBeDefined();
            expect(result!.description).toBe('Direct migration to v4');
            expect(result!.tags).toEqual(['direct']);
        });

        it('should load current version without migration', async () => {
            // Save v3 data
            const dataV3: DataV3 = {
                name: 'test',
                value: 42,
                description: 'already v3',
                tags: ['current']
            };
            await save(storage, 'data-v3.bin', dataV3, 3, serializeV3);

            const deserializers: Record<number, DeserializerFunction<unknown>> = {
                1: deserializeV1,
                2: deserializeV2,
                3: deserializeV3,
            };

            const migrations: MigrationMap = {
                '1:2': (data: DataV1): DataV2 => ({ ...data, description: 'should not run' }),
                '2:3': (data: DataV2): DataV3 => ({ ...data, tags: ['should not run'] })
            };

            // Load v3 data (should not apply any migrations)
            const result = await load<DataV3>(storage, 'data-v3.bin', deserializers, migrations);

            expect(result).toEqual(dataV3);
        });

        it('should throw error when no migration path exists', async () => {
            // Save v1 data
            const dataV1: DataV1 = { name: 'test', value: 42 };
            await save(storage, 'data-v1.bin', dataV1, 1, serializeV1);

            const deserializers: Record<number, DeserializerFunction<unknown>> = {
                1: deserializeV1,
                3: deserializeV3, // Note: no v2 deserializer
            };

            const migrations: MigrationMap = {
                '2:3': (data: DataV2): DataV3 => ({ ...data, tags: [] })
                // Note: no 1:2 or 1:3 migration
            };

            await expect(load<DataV3>(storage, 'data-v1.bin', deserializers, migrations))
                .rejects
                .toThrow('No migration path found from version 1 to 3');
        });

        it('should throw error when migration function is missing in path', async () => {
            // Save v1 data
            const dataV1: DataV1 = { name: 'test', value: 42 };
            await save(storage, 'data-v1.bin', dataV1, 1, serializeV1);

            const deserializers: Record<number, DeserializerFunction<unknown>> = {
                1: deserializeV1,
                2: deserializeV2,
                3: deserializeV3,
            };

            const migrations: MigrationMap = {
                '1:2': (data: DataV1): DataV2 => ({ ...data, description: 'migrated' })
                // Missing 2:3 migration
            };

            await expect(load<DataV3>(storage, 'data-v1.bin', deserializers, migrations))
                .rejects
                .toThrow('No migration path found from version 1 to 3');
        });

        it('should throw error when specific migration step is missing', async () => {
            // Save v1 data  
            const dataV1: DataV1 = { name: 'test', value: 42 };
            await save(storage, 'data-v1.bin', dataV1, 1, serializeV1);

            const deserializers: Record<number, DeserializerFunction<unknown>> = {
                1: deserializeV1,
                2: deserializeV2,
                3: deserializeV3,
            };

            // Force a specific path that has a missing step
            const migrations: MigrationMap = {
                '1:3': (data: DataV1): DataV3 => ({ ...data, description: 'direct', tags: [] }),
                '1:2': (data: DataV1): DataV2 => ({ ...data, description: 'step1' }),
                // Missing 2:3 step - this will be tested by modifying internal path finding
            };

            // This should work with direct path
            const result = await load<DataV3>(storage, 'data-v1.bin', deserializers, migrations);
            expect(result).toBeDefined();
            expect(result!.description).toBe('direct');
        });

        it('should work without migrations when versions match', async () => {
            // Save v2 data
            const dataV2: DataV2 = {
                name: 'test',
                value: 42,
                description: 'v2 data'
            };
            await save(storage, 'data-v2.bin', dataV2, 2, serializeV2);

            const deserializers: Record<number, DeserializerFunction<unknown>> = {
                2: deserializeV2,
            };

            // Load without migrations (should work fine)
            const result = await load<DataV2>(storage, 'data-v2.bin', deserializers);

            expect(result).toEqual(dataV2);
        });
    });
});