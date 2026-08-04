import * as crypto from 'crypto';
import * as path from 'path';
import * as fs from 'fs/promises';
import { HashCache, IHashCacheEntry } from '../../lib/hash-cache';
import { createTestTempDir } from 'node-utils';

// Mock implementation of IStorage (no longer used, kept for reference)
class MockStorage {
    private files: Map<string, Buffer> = new Map();
    
    constructor(public readonly location: string = 'mock-storage', public readonly isReadonly: boolean = false) {}
    
    async isEmpty(path: string): Promise<boolean> {
        for (const filePath of this.files.keys()) {
            if (filePath.startsWith(path)) {
                return false;
            }
        }
        return true;
    }
    
    async listFiles(path: string, max: number, next?: string): Promise<{ names: string[], next?: string }> {
        const result: string[] = [];
        for (const filePath of this.files.keys()) {
            if (filePath.startsWith(path)) {
                result.push(filePath.substring(path.length).replace(/^\//, ''));
            }
            if (result.length >= max) {
                break;
            }
        }
        return { names: result };
    }
    
    async listDirs(path: string, max: number, next?: string): Promise<{ names: string[], next?: string }> {
        return { names: [] };
    }
    
    async fileExists(filePath: string): Promise<boolean> {
        return this.files.has(filePath);
    }
    
    async dirExists(dirPath: string): Promise<boolean> {
        return false;
    }
    
    async info(filePath: string): Promise<{ contentType: string | undefined, length: number, lastModified: Date } | undefined> {
        const file = this.files.get(filePath);
        if (!file) {
            return undefined;
        }
        return {
            contentType: 'application/octet-stream',
            length: file.length,
            lastModified: new Date()
        };
    }
    
    async read(filePath: string): Promise<Buffer | undefined> {
        return this.files.get(filePath);
    }
    
    async write(filePath: string, contentType: string | undefined, data: Buffer): Promise<void> {
        this.files.set(filePath, data);
    }
    
    async readStream(filePath: string): Promise<any> {
        throw new Error('Not implemented in mock');
    }
    
    async writeStream(filePath: string, contentType: string | undefined, inputStream: any, contentLength?: number): Promise<void> {
        throw new Error('Not implemented in mock');
    }
    
    async deleteFile(filePath: string): Promise<void> {
        this.files.delete(filePath);
    }
    
    async deleteDir(dirPath: string): Promise<void> {
        // Remove all files that start with dirPath
        for (const filePath of this.files.keys()) {
            if (filePath.startsWith(dirPath)) {
                this.files.delete(filePath);
            }
        }
    }
    
    async copyTo(srcPath: string, destPath: string): Promise<void> {
        const data = this.files.get(srcPath);
        if (data) {
            this.files.set(destPath, data);
        }
    }
    
    async checkWriteLock(filePath: string): Promise<any> {
        return undefined;
    }
    
    async acquireWriteLock(filePath: string, owner: string): Promise<boolean> {
        return true;
    }
    
    async releaseWriteLock(filePath: string): Promise<void> {
        // No-op in mock
    }
    
    async refreshWriteLock(filePath: string, owner: string): Promise<void> {
        // No-op in mock
    }
}

// Helper function to create a file hash
function createHash(content: string): Buffer {
    return crypto.createHash('sha256').update(content).digest();
}

describe('HashCache', () => {
    let hashCache: HashCache;
    let cacheDir: string;

    beforeEach(() => {
        cacheDir = createTestTempDir('hash-cache-test');
        hashCache = new HashCache(cacheDir);
    });
    
    test('should initialize with empty cache', async () => {
        const loaded = await hashCache.load();
        expect(loaded).toBe(false);
        expect(hashCache.getEntryCount()).toBe(0);
    });
    
    test('should add and retrieve hash', async () => {
        await hashCache.load();
        
        const filePath = 'test/file1.txt';
        const hash = createHash('file content');
        const fileSize = 100;
        const lastModified = new Date();
        
        hashCache.addHash(filePath, { hash, length: fileSize, lastModified });
        
        const retrieved = hashCache.getHash(filePath);
        expect(retrieved).toBeDefined();
        expect(retrieved!.hash.toString('hex')).toBe(hash.toString('hex'));
        expect(retrieved!.length).toBe(fileSize);
        expect(retrieved!.lastModified.getTime()).toBe(lastModified.getTime());
        expect(hashCache.getEntryCount()).toBe(1);
    });
    
    test('should update existing hash', async () => {
        await hashCache.load();
        
        const filePath = 'test/file2.txt';
        const hash1 = createHash('original content');
        const fileSize1 = 100;
        const lastModified1 = new Date(2023, 1, 1);
        
        hashCache.addHash(filePath, { hash: hash1, length: fileSize1, lastModified: lastModified1 });
        
        // Update with new hash
        const hash2 = createHash('updated content');
        const fileSize2 = 200;
        const lastModified2 = new Date(2023, 2, 1);
        
        hashCache.addHash(filePath, { hash: hash2, length: fileSize2, lastModified: lastModified2 });
        
        const retrieved = hashCache.getHash(filePath);
        expect(retrieved).toBeDefined();
        expect(retrieved!.hash.toString('hex')).toBe(hash2.toString('hex'));
        expect(retrieved!.length).toBe(fileSize2);
        expect(retrieved!.lastModified.getTime()).toBe(lastModified2.getTime());
        expect(hashCache.getEntryCount()).toBe(1); // Count should still be 1
    });
    
    test('should save and load cache', async () => {
        await hashCache.load();
        
        // Add some hashes
        const file1 = 'test/file1.txt';
        const hash1 = createHash('content 1');
        const size1 = 100;
        const date1 = new Date(2023, 1, 1);
        
        const file2 = 'test/file2.txt';
        const hash2 = createHash('content 2');
        const size2 = 200;
        const date2 = new Date(2023, 2, 1);
        
        hashCache.addHash(file1, { hash: hash1, length: size1, lastModified: date1 });
        hashCache.addHash(file2, { hash: hash2, length: size2, lastModified: date2 });
        
        // Save the cache
        await hashCache.save();
        
        // Create a new cache instance and load
        const newCache = new HashCache(cacheDir);
        const loaded = await newCache.load();
        
        expect(loaded).toBe(true);
        expect(newCache.getEntryCount()).toBe(2);
        
        // Check that hashes are retrieved correctly
        const retrieved1 = newCache.getHash(file1);
        expect(retrieved1).toBeDefined();
        expect(retrieved1!.hash.toString('hex')).toBe(hash1.toString('hex'));
        expect(retrieved1!.length).toBe(size1);
        expect(retrieved1!.lastModified.getTime()).toBe(date1.getTime());
        
        const retrieved2 = newCache.getHash(file2);
        expect(retrieved2).toBeDefined();
        expect(retrieved2!.hash.toString('hex')).toBe(hash2.toString('hex'));
        expect(retrieved2!.length).toBe(size2);
        expect(retrieved2!.lastModified.getTime()).toBe(date2.getTime());
    });
    
    test('should handle non-existent hashes', async () => {
        await hashCache.load();
        
        const result = hashCache.getHash('non-existent-file.txt');
        expect(result).toBeUndefined();
    });
    
    test('should remove hash', async () => {
        await hashCache.load();
        
        const filePath = 'test/file3.txt';
        const hash = createHash('content');
        const fileSize = 100;
        const lastModified = new Date();
        
        hashCache.addHash(filePath, { hash, length: fileSize, lastModified });
        expect(hashCache.getEntryCount()).toBe(1);
        
        // Remove the hash
        const removed = hashCache.removeHash(filePath);
        expect(removed).toBe(true);
        expect(hashCache.getEntryCount()).toBe(0);
        
        // Try to get the removed hash
        const result = hashCache.getHash(filePath);
        expect(result).toBeUndefined();
    });
    
    test('should return false when removing non-existent hash', async () => {
        await hashCache.load();
        
        const removed = hashCache.removeHash('non-existent-file.txt');
        expect(removed).toBe(false);
    });
    
    test('should properly handle paths with different slashes', async () => {
        await hashCache.load();
        
        const filePath = 'test\\file4.txt'; // Windows-style path
        const hash = createHash('content');
        const fileSize = 100;
        const lastModified = new Date();
        
        hashCache.addHash(filePath, { hash, length: fileSize, lastModified });
        
        // Should normalize paths internally
        const retrieved = hashCache.getHash('test/file4.txt'); // Unix-style path
        expect(retrieved).toBeDefined();
        expect(retrieved!.hash.toString('hex')).toBe(hash.toString('hex'));
    });
    
    test('should maintain sorted order when adding hashes', async () => {
        await hashCache.load();
        
        // Add hashes in non-alphabetical order
        const files = [
            'z/file.txt',
            'a/file.txt',
            'm/file.txt',
            'c/file.txt'
        ];
        
        for (const file of files) {
            const hash = createHash(`content of ${file}`);
            hashCache.addHash(file, { hash, length: 100, lastModified: new Date() });
        }
        
        // Save and reload to verify order
        await hashCache.save();
        
        const newCache = new HashCache(cacheDir);
        await newCache.load();
        
        // Verify all hashes can be retrieved
        for (const file of files) {
            const retrieved = newCache.getHash(file);
            expect(retrieved).toBeDefined();
            expect(retrieved!.hash.toString('hex')).toBe(createHash(`content of ${file}`).toString('hex'));
        }
    });
    
    test('should handle buffer resizing for large entries', async () => {
        await hashCache.load();
        
        // Add a large number of entries to force buffer resizing
        const largeEntryCount = 1000;
        
        for (let i = 0; i < largeEntryCount; i++) {
            const filePath = `file${i.toString().padStart(4, '0')}.txt`;
            const hash = createHash(`content ${i}`);
            hashCache.addHash(filePath, { hash, length: i, lastModified: new Date() });
        }
        
        expect(hashCache.getEntryCount()).toBe(largeEntryCount);
        
        // Verify a random entry
        const randomIndex = Math.floor(Math.random() * largeEntryCount);
        const filePath = `file${randomIndex.toString().padStart(4, '0')}.txt`;
        const retrieved = hashCache.getHash(filePath);
        
        expect(retrieved).toBeDefined();
        expect(retrieved!.hash.toString('hex')).toBe(createHash(`content ${randomIndex}`).toString('hex'));
        expect(retrieved!.length).toBe(randomIndex);
    });
    
    test('should correctly calculate entry size', async () => {
        await hashCache.load();
        
        // Add entries with different path lengths
        const shortPath = 'a.txt';
        const longPath = 'very/long/path/with/multiple/directories/and/a/long/filename.extension';
        
        hashCache.addHash(shortPath, { 
            hash: createHash('short'), 
            length: 100, 
            lastModified: new Date() 
        });
        
        hashCache.addHash(longPath, { 
            hash: createHash('long'), 
            length: 200, 
            lastModified: new Date() 
        });
        
        // Save and reload to verify
        await hashCache.save();
        
        const newCache = new HashCache(cacheDir);
        await newCache.load();
        
        // Verify both entries
        const retrievedShort = newCache.getHash(shortPath);
        expect(retrievedShort).toBeDefined();
        expect(retrievedShort!.hash.toString('hex')).toBe(createHash('short').toString('hex'));
        
        const retrievedLong = newCache.getHash(longPath);
        expect(retrievedLong).toBeDefined();
        expect(retrievedLong!.hash.toString('hex')).toBe(createHash('long').toString('hex'));
    });
    
    test('should validate hash length', async () => {
        await hashCache.load();
        
        const filePath = 'test/file.txt';
        const invalidHash = Buffer.from('too-short'); // Not 32 bytes
        
        expect(() => {
            hashCache.addHash(filePath, { 
                hash: invalidHash, 
                length: 100, 
                lastModified: new Date() 
            });
        }).toThrow(/Invalid hash length/);
    });
    
    test('should handle binary search edge cases', async () => {
        await hashCache.load();
        
        // Add entries to test binary search
        for (let i = 0; i < 10; i += 2) { // Add even numbers only
            const filePath = `file${i}.txt`;
            hashCache.addHash(filePath, { 
                hash: createHash(`content ${i}`), 
                length: i, 
                lastModified: new Date() 
            });
        }
        
        // Test getting a hash at the start of the range
        expect(hashCache.getHash('file0.txt')).toBeDefined();
        
        // Test getting a hash at the end of the range
        expect(hashCache.getHash('file8.txt')).toBeDefined();
        
        // Test getting a hash in the middle
        expect(hashCache.getHash('file4.txt')).toBeDefined();
        
        // Test with missing hashes (odd numbers)
        expect(hashCache.getHash('file1.txt')).toBeUndefined();
        expect(hashCache.getHash('file3.txt')).toBeUndefined();
        expect(hashCache.getHash('file5.txt')).toBeUndefined();
        
        // Test with a path that would be before the first entry
        expect(hashCache.getHash('aaa.txt')).toBeUndefined();
        
        // Test with a path that would be after the last entry
        expect(hashCache.getHash('zzz.txt')).toBeUndefined();
    });
});

//
// Builds a cache entry with predictable content for the encode/decode and merge tests.
//
function makeEntry(filePath: string): IHashCacheEntry {
    return {
        filePath,
        hash: createHash(`content of ${filePath}`),
        length: filePath.length,
        lastModified: new Date(2024, 0, 1).getTime(),
    };
}

// The file codec is private to HashCache and depends on no instance state, so the tests reach it
// through a throwaway instance rather than going through the filesystem for every case.
const codec = new HashCache('unused-cache-dir') as any;

//
// Encodes entries into the bytes of a cache file.
//
function encodeEntries(entries: IHashCacheEntry[]): Buffer {
    return codec.encodeEntries(entries);
}

//
// Decodes the bytes of a cache file, or undefined when they are not usable.
//
function decodeEntries(fileBytes: Buffer | undefined): IHashCacheEntry[] | undefined {
    return codec.decodeEntries(fileBytes);
}

describe('encodeEntries / decodeEntries', () => {
    test('round-trips a set of entries', () => {
        const entries = [makeEntry('a/one.txt'), makeEntry('b/two.txt'), makeEntry('c/three.txt')];

        const decoded = decodeEntries(encodeEntries(entries));

        expect(decoded).toBeDefined();
        expect(decoded!.length).toBe(3);
        for (let entryIndex = 0; entryIndex < entries.length; entryIndex++) {
            expect(decoded![entryIndex].filePath).toBe(entries[entryIndex].filePath);
            expect(decoded![entryIndex].hash.toString('hex')).toBe(entries[entryIndex].hash.toString('hex'));
            expect(decoded![entryIndex].length).toBe(entries[entryIndex].length);
            expect(decoded![entryIndex].lastModified).toBe(entries[entryIndex].lastModified);
        }
    });

    test('round-trips an empty set of entries', () => {
        const decoded = decodeEntries(encodeEntries([]));

        expect(decoded).toEqual([]);
    });

    test('returns undefined for an absent file', () => {
        expect(decodeEntries(undefined)).toBeUndefined();
    });

    test('returns undefined for a buffer that is too small', () => {
        expect(decodeEntries(Buffer.alloc(39))).toBeUndefined();
    });

    test('returns undefined for an unsupported version', () => {
        const encoded = encodeEntries([makeEntry('a/one.txt')]);

        // Bump the version, then re-checksum so only the version makes it unusable.
        const dataWithoutChecksum = encoded.subarray(0, encoded.length - 32);
        dataWithoutChecksum.writeUInt32LE(99, 0);
        const rechecksummed = Buffer.concat([dataWithoutChecksum, crypto.createHash('sha256').update(dataWithoutChecksum).digest()]);

        expect(decodeEntries(rechecksummed)).toBeUndefined();
    });

    test('returns undefined when the checksum does not match', () => {
        const encoded = encodeEntries([makeEntry('a/one.txt')]);

        // Corrupt a byte in the middle of the entries without touching the checksum.
        encoded[20] = encoded[20] ^ 0xff;

        expect(decodeEntries(encoded)).toBeUndefined();
    });

    test('returns undefined when an entry runs past the end of the data', () => {
        const encoded = encodeEntries([makeEntry('a/one.txt')]);

        // Claim a second entry that is not there, then re-checksum so only the truncation is wrong.
        const dataWithoutChecksum = encoded.subarray(0, encoded.length - 32);
        dataWithoutChecksum.writeUInt32LE(2, 4);
        const rechecksummed = Buffer.concat([dataWithoutChecksum, crypto.createHash('sha256').update(dataWithoutChecksum).digest()]);

        expect(decodeEntries(rechecksummed)).toBeUndefined();
    });
});

describe('HashCache concurrent saves', () => {
    let cacheDir: string;

    beforeEach(() => {
        cacheDir = createTestTempDir('hash-cache-concurrent-test');
    });

    //
    // Reads and decodes the cache file written to the shared directory.
    //
    async function readCacheFile(): Promise<IHashCacheEntry[] | undefined> {
        return decodeEntries(await fs.readFile(path.join(cacheDir, 'hash-cache-x.dat')));
    }

    //
    // Writes a cache file containing the supplied entries, as if another instance had saved it.
    //
    async function writeCacheFile(entries: IHashCacheEntry[]): Promise<void> {
        await fs.mkdir(cacheDir, { recursive: true });
        await fs.writeFile(path.join(cacheDir, 'hash-cache-x.dat'), encodeEntries(entries));
    }

    test('merges its own additions onto entries already on disk', async () => {
        await writeCacheFile([makeEntry('a/one.txt'), makeEntry('b/two.txt')]);

        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        const added = makeEntry('c/three.txt');
        hashCache.addHash(added.filePath, { hash: added.hash, length: added.length, lastModified: new Date(added.lastModified) });
        await hashCache.save();

        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.filePath)).toEqual(['a/one.txt', 'b/two.txt', 'c/three.txt']);
    });

    test('keeps entries another instance added after this one loaded', async () => {
        // Both instances load the same (empty) cache, so neither knows about the other's entries.
        const firstCache = new HashCache(cacheDir);
        const secondCache = new HashCache(cacheDir);
        await firstCache.load();
        await secondCache.load();

        const firstEntry = makeEntry('first/file.txt');
        firstCache.addHash(firstEntry.filePath, { hash: firstEntry.hash, length: firstEntry.length, lastModified: new Date(firstEntry.lastModified) });
        await firstCache.save();

        const secondEntry = makeEntry('second/file.txt');
        secondCache.addHash(secondEntry.filePath, { hash: secondEntry.hash, length: secondEntry.length, lastModified: new Date(secondEntry.lastModified) });
        await secondCache.save();

        // Before merge-on-save the second save overwrote the first instance's entry.
        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.filePath)).toEqual(['first/file.txt', 'second/file.txt']);

        // The saving instance also picks up the entry it merged in.
        expect(secondCache.getHash('first/file.txt')).toBeDefined();
        expect(secondCache.getEntryCount()).toBe(2);
    });

    test('loses no entries when many instances load together and save one after another', async () => {
        const writerCount = 10;
        const caches: HashCache[] = [];

        // Every instance loads before any of them saves, the situation that used to lose entries.
        for (let writerIndex = 0; writerIndex < writerCount; writerIndex++) {
            const cache = new HashCache(cacheDir);
            await cache.load();
            caches.push(cache);
        }

        for (let writerIndex = 0; writerIndex < writerCount; writerIndex++) {
            const entry = makeEntry(`writer${writerIndex}/file.txt`);
            caches[writerIndex].addHash(entry.filePath, { hash: entry.hash, length: entry.length, lastModified: new Date(entry.lastModified) });
            await caches[writerIndex].save();
        }

        const onDisk = await readCacheFile();
        expect(onDisk!.length).toBe(writerCount);
        for (let writerIndex = 0; writerIndex < writerCount; writerIndex++) {
            expect(onDisk!.some(entry => entry.filePath === `writer${writerIndex}/file.txt`)).toBe(true);
        }
    });

    test('applies removals to the on-disk cache instead of resurrecting them', async () => {
        await writeCacheFile([makeEntry('a/one.txt'), makeEntry('b/two.txt')]);

        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        expect(hashCache.removeHash('a/one.txt')).toBe(true);
        await hashCache.save();

        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.filePath)).toEqual(['b/two.txt']);
    });

    test('never publishes a corrupt file when saves overlap', async () => {
        // Overlapping saves used to share one temp file path and interleave their bytes into it,
        // so the published file failed its checksum and the whole cache was discarded on load.
        const writerCount = 8;
        const savePromises: Promise<void>[] = [];

        for (let writerIndex = 0; writerIndex < writerCount; writerIndex++) {
            const cache = new HashCache(cacheDir);
            await cache.load();
            const entry = makeEntry(`overlap${writerIndex}/file.txt`);
            cache.addHash(entry.filePath, { hash: entry.hash, length: entry.length, lastModified: new Date(entry.lastModified) });
            savePromises.push(cache.save());
        }

        await Promise.all(savePromises);

        // The file is always a complete, checksum-valid cache, whichever save published last.
        const onDisk = await readCacheFile();
        expect(onDisk).toBeDefined();
        expect(onDisk!.length).toBeGreaterThan(0);
    });

    test('clears the changeset after a save so later saves only apply later changes', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        const firstEntry = makeEntry('first/file.txt');
        hashCache.addHash(firstEntry.filePath, { hash: firstEntry.hash, length: firstEntry.length, lastModified: new Date(firstEntry.lastModified) });
        await hashCache.save();

        // Another instance replaces the file wholesale, dropping the first entry.
        await writeCacheFile([makeEntry('other/file.txt')]);

        const secondEntry = makeEntry('second/file.txt');
        hashCache.addHash(secondEntry.filePath, { hash: secondEntry.hash, length: secondEntry.length, lastModified: new Date(secondEntry.lastModified) });
        await hashCache.save();

        // Only the change made since the last save is applied, not the whole in-memory snapshot.
        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.filePath)).toEqual(['other/file.txt', 'second/file.txt']);
    });

    test('clears the changeset on load so pre-load changes are not re-applied', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        const discardedEntry = makeEntry('discarded/file.txt');
        hashCache.addHash(discardedEntry.filePath, { hash: discardedEntry.hash, length: discardedEntry.length, lastModified: new Date(discardedEntry.lastModified) });

        // Reloading throws away everything that was not saved.
        await hashCache.load();

        const keptEntry = makeEntry('kept/file.txt');
        hashCache.addHash(keptEntry.filePath, { hash: keptEntry.hash, length: keptEntry.length, lastModified: new Date(keptEntry.lastModified) });
        await hashCache.save();

        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.filePath)).toEqual(['kept/file.txt']);
    });
});

