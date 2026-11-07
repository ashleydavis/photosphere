import * as crypto from 'crypto';
import * as os from 'os';
import * as path from 'path';
import * as fs from 'fs/promises';
import { getHashCacheDir, HashCache, IHashCacheEntry } from '../../lib/hash-cache';
import { getDatabaseCacheDir } from '../../lib/database-cache-dir';
import { createTestTempDir, getCacheDir, getProcessTmpDir } from 'node-utils';

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
        key: filePath,
        hash: createHash(`content of ${filePath}`),
        length: filePath.length,
        lastModified: new Date(2024, 0, 1).getTime(),
        assetId: undefined,
        keyedBySourceId: false,
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
            expect(decoded![entryIndex].key).toBe(entries[entryIndex].key);
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
        hashCache.addHash(added.key, { hash: added.hash, length: added.length, lastModified: new Date(added.lastModified) });
        await hashCache.save();

        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.key)).toEqual(['a/one.txt', 'b/two.txt', 'c/three.txt']);
    });

    test('keeps entries another instance added after this one loaded', async () => {
        // Both instances load the same (empty) cache, so neither knows about the other's entries.
        const firstCache = new HashCache(cacheDir);
        const secondCache = new HashCache(cacheDir);
        await firstCache.load();
        await secondCache.load();

        const firstEntry = makeEntry('first/file.txt');
        firstCache.addHash(firstEntry.key, { hash: firstEntry.hash, length: firstEntry.length, lastModified: new Date(firstEntry.lastModified) });
        await firstCache.save();

        const secondEntry = makeEntry('second/file.txt');
        secondCache.addHash(secondEntry.key, { hash: secondEntry.hash, length: secondEntry.length, lastModified: new Date(secondEntry.lastModified) });
        await secondCache.save();

        // Before merge-on-save the second save overwrote the first instance's entry.
        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.key)).toEqual(['first/file.txt', 'second/file.txt']);

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
            caches[writerIndex].addHash(entry.key, { hash: entry.hash, length: entry.length, lastModified: new Date(entry.lastModified) });
            await caches[writerIndex].save();
        }

        const onDisk = await readCacheFile();
        expect(onDisk!.length).toBe(writerCount);
        for (let writerIndex = 0; writerIndex < writerCount; writerIndex++) {
            expect(onDisk!.some(entry => entry.key === `writer${writerIndex}/file.txt`)).toBe(true);
        }
    });

    test('applies removals to the on-disk cache instead of resurrecting them', async () => {
        await writeCacheFile([makeEntry('a/one.txt'), makeEntry('b/two.txt')]);

        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        expect(hashCache.removeHash('a/one.txt')).toBe(true);
        await hashCache.save();

        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.key)).toEqual(['b/two.txt']);
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
            cache.addHash(entry.key, { hash: entry.hash, length: entry.length, lastModified: new Date(entry.lastModified) });
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
        hashCache.addHash(firstEntry.key, { hash: firstEntry.hash, length: firstEntry.length, lastModified: new Date(firstEntry.lastModified) });
        await hashCache.save();

        // Another instance replaces the file wholesale, dropping the first entry.
        await writeCacheFile([makeEntry('other/file.txt')]);

        const secondEntry = makeEntry('second/file.txt');
        hashCache.addHash(secondEntry.key, { hash: secondEntry.hash, length: secondEntry.length, lastModified: new Date(secondEntry.lastModified) });
        await hashCache.save();

        // Only the change made since the last save is applied, not the whole in-memory snapshot.
        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.key)).toEqual(['other/file.txt', 'second/file.txt']);
    });

    test('clears the changeset on load so pre-load changes are not re-applied', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        const discardedEntry = makeEntry('discarded/file.txt');
        hashCache.addHash(discardedEntry.key, { hash: discardedEntry.hash, length: discardedEntry.length, lastModified: new Date(discardedEntry.lastModified) });

        // Reloading throws away everything that was not saved.
        await hashCache.load();

        const keptEntry = makeEntry('kept/file.txt');
        hashCache.addHash(keptEntry.key, { hash: keptEntry.hash, length: keptEntry.length, lastModified: new Date(keptEntry.lastModified) });
        await hashCache.save();

        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.key)).toEqual(['kept/file.txt']);
    });
});


//
// Puts an environment variable back to what it was, including back to not being set at all.
//
function restoreEnvironmentVariable(name: string, originalValue: string | undefined): void {
    if (originalValue === undefined) {
        delete process.env[name];
    }
    else {
        process.env[name] = originalValue;
    }
}

describe('getHashCacheDir', () => {
    //
    // Two of these tests point the cache and scratch directories at somewhere of their own, so the
    // settings are put back afterwards rather than left for whatever runs next in this file.
    //
    let originalCacheDir: string | undefined;
    let originalTmpDir: string | undefined;

    beforeEach(() => {
        originalCacheDir = process.env.PHOTOSPHERE_CACHE_DIR;
        originalTmpDir = process.env.PHOTOSPHERE_TMP_DIR;
    });

    afterEach(() => {
        restoreEnvironmentVariable('PHOTOSPHERE_CACHE_DIR', originalCacheDir);
        restoreEnvironmentVariable('PHOTOSPHERE_TMP_DIR', originalTmpDir);
    });

    test('gives two databases two different cache directories', () => {
        // An entry records the id its file has in the database, and the same photo imported into two
        // databases has two ids, so one cache cannot serve both.
        expect(getHashCacheDir('/photos/one')).not.toBe(getHashCacheDir('/photos/two'));
    });

    test('gives the same database the same cache directory every time', () => {
        expect(getHashCacheDir('/photos/one')).toBe(getHashCacheDir('/photos/one'));
    });

    test('names the hash cache apart from anything else kept about the database', () => {
        // The database's cache directory is shared with whatever else this machine works out about
        // it, so the hash cache has a name of its own inside rather than being the directory itself.
        expect(path.basename(getHashCacheDir('/photos/one'))).toBe('hash-cache');
    });

    test('makes a directory name out of a database path that could never be one', () => {
        // An S3 database path has colons and slashes in it, which cannot be pasted into a directory
        // name on any platform.
        expect(path.basename(getDatabaseCacheDir('s3:my-bucket:/photos/db'))).toMatch(/^[0-9a-f]+$/);
    });

    test('sits under the platform cache directory, not the process temp directory', () => {
        // Everything the cache knows can be recomputed, but recomputing it for a photo library means
        // copying and hashing every photo already imported. Under the process temp directory that
        // happened at every reboot on Linux, and after a few untouched days on macOS, with nothing
        // to say it had.
        const runRoot = createTestTempDir('hash-cache-home-check');
        process.env.PHOTOSPHERE_CACHE_DIR = path.join(runRoot, 'cache');
        process.env.PHOTOSPHERE_TMP_DIR = path.join(runRoot, 'scratch');

        const cacheDir = getHashCacheDir('/photos/one');

        expect(cacheDir.startsWith(getCacheDir())).toBe(true);
        expect(cacheDir.startsWith(getProcessTmpDir())).toBe(false);
    });

    test('sits inside the database cache directory, which is where anything else about a database goes', () => {
        expect(path.dirname(getHashCacheDir('/photos/one'))).toBe(getDatabaseCacheDir('/photos/one'));
    });

    test('is still found once the process temp directory has been taken away', async () => {
        // This is the restart, as far as a test can stage one: the scratch directory is gone and the
        // cache is read back anyway. Every platform gets this, because every platform's temp
        // directory is swept by something the app never hears about.
        const runRoot = createTestTempDir('hash-cache-survives-temp');
        process.env.PHOTOSPHERE_CACHE_DIR = path.join(runRoot, 'cache');
        process.env.PHOTOSPHERE_TMP_DIR = path.join(runRoot, 'scratch');
        await fs.mkdir(getProcessTmpDir(), { recursive: true });

        const writer = new HashCache(getHashCacheDir('/photos/one'));
        await writer.load();
        writer.addSourceHash('device-item-1', {
            hash: crypto.createHash('sha256').update('photo').digest(),
            length: 4096,
            lastModified: new Date(1700000000000),
        });
        await writer.save();

        // The process temp directory itself goes, exactly as a boot-time sweep of /tmp takes it.
        // Nothing put anything in it, so removing the directory alone is the whole of it.
        await fs.rmdir(getProcessTmpDir());

        const reader = new HashCache(getHashCacheDir('/photos/one'));
        await reader.load();

        expect(reader.getHash('device-item-1')!.length).toBe(4096);
    });
});

describe('asset ids and source-keyed entries', () => {
    let cacheDir: string;

    beforeEach(() => {
        cacheDir = createTestTempDir('hash-cache-asset-id-test');
    });

    //
    // Reads the cache file back the way another process would.
    //
    async function readCacheFile(): Promise<IHashCacheEntry[] | undefined> {
        return decodeEntries(await fs.readFile(path.join(cacheDir, 'hash-cache-x.dat')));
    }

    test('a new entry has no asset id until one is recorded', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();

        hashCache.addHash('photos/one.jpg', { hash: createHash('one'), length: 10, lastModified: new Date(1000) });

        expect(hashCache.getHash('photos/one.jpg')!.assetId).toBeUndefined();
    });

    test('records an asset id against an entry', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addHash('photos/one.jpg', { hash: createHash('one'), length: 10, lastModified: new Date(1000) });

        expect(hashCache.setAssetId('photos/one.jpg', '2f1c4a2e-0000-4000-8000-00000000abcd')).toBe(true);

        expect(hashCache.getHash('photos/one.jpg')!.assetId).toBe('2f1c4a2e-0000-4000-8000-00000000abcd');
    });

    test('an asset id survives a save and a load, which is the whole point of recording it', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addHash('photos/one.jpg', { hash: createHash('one'), length: 10, lastModified: new Date(1000) });
        hashCache.setAssetId('photos/one.jpg', '2f1c4a2e-0000-4000-8000-00000000abcd');
        await hashCache.save();

        const reloaded = new HashCache(cacheDir);
        await reloaded.load();

        expect(reloaded.getHash('photos/one.jpg')!.assetId).toBe('2f1c4a2e-0000-4000-8000-00000000abcd');
    });

    test('reports that nothing was recorded when there is no entry to record it against', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();

        expect(hashCache.setAssetId('photos/missing.jpg', 'some-asset-id')).toBe(false);
    });

    test('re-hashing a file clears its asset id, because the id described the old content', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addHash('photos/one.jpg', { hash: createHash('one'), length: 10, lastModified: new Date(1000) });
        hashCache.setAssetId('photos/one.jpg', '2f1c4a2e-0000-4000-8000-00000000abcd');

        hashCache.addHash('photos/one.jpg', { hash: createHash('one changed'), length: 20, lastModified: new Date(2000) });

        expect(hashCache.getHash('photos/one.jpg')!.assetId).toBeUndefined();
    });

    test('refuses an asset id too long to fit the space the format reserves', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addHash('photos/one.jpg', { hash: createHash('one'), length: 10, lastModified: new Date(1000) });

        expect(() => hashCache.setAssetId('photos/one.jpg', 'x'.repeat(37))).toThrow(/does not fit/);
    });

    test('files an item under its source id, and finds it there', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();

        // A MediaStore id, which is what a source id looks like on Android. There is no path here at
        // all: the photo has not been copied out of the library and never will be.
        hashCache.addSourceHash('1000000042', { hash: createHash('library photo'), length: 4096, lastModified: new Date(1700000000000) });

        const found = hashCache.getHash('1000000042');
        expect(found).toBeDefined();
        expect(found!.hash.toString('hex')).toBe(createHash('library photo').toString('hex'));
    });

    test('remembers which entries are keyed by a source id and which by a path', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addSourceHash('1000000042', { hash: createHash('library photo'), length: 4096, lastModified: new Date(1700000000000) });
        hashCache.addHash('photos/one.jpg', { hash: createHash('one'), length: 10, lastModified: new Date(1000) });
        await hashCache.save();

        const onDisk = await readCacheFile();

        expect(onDisk!.find(entry => entry.key === '1000000042')!.keyedBySourceId).toBe(true);
        expect(onDisk!.find(entry => entry.key === 'photos/one.jpg')!.keyedBySourceId).toBe(false);
    });

    test('drops source-keyed entries the library no longer holds', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addSourceHash('still-here', { hash: createHash('a'), length: 1, lastModified: new Date(1000) });
        hashCache.addSourceHash('deleted-from-device', { hash: createHash('b'), length: 2, lastModified: new Date(2000) });

        const removed = hashCache.removeSourceEntriesNotIn(new Set(['still-here']));

        expect(removed).toBe(1);
        expect(hashCache.getHash('deleted-from-device')).toBeUndefined();
        expect(hashCache.getHash('still-here')).toBeDefined();
    });

    test('never drops a path-keyed entry, however absent it is from the library', async () => {
        // This is the case that would throw away the desktop's whole cache the first time automatic
        // import walked a folder: a manual import's entries are not photo library items and cannot be
        // judged by whether the library still lists them.
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addHash('photos/manual-import.jpg', { hash: createHash('a'), length: 1, lastModified: new Date(1000) });

        const removed = hashCache.removeSourceEntriesNotIn(new Set(['nothing-matching']));

        expect(removed).toBe(0);
        expect(hashCache.getHash('photos/manual-import.jpg')).toBeDefined();
    });

    test('keeps an entry the walk saw at an absolute path', async () => {
        // A watched folder's source ids are absolute paths, and an entry is stored with its leading
        // slash taken off. Compared raw, the stored "photos/one.jpg" never matched the live
        // "/photos/one.jpg", so on Linux and macOS every entry automatic import wrote was swept at
        // the end of the very run that wrote it and the whole folder was hashed again on the next.
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addSourceHash('/photos/one.jpg', { hash: createHash('a'), length: 1, lastModified: new Date(1000) });

        const removed = hashCache.removeSourceEntriesNotIn(new Set(['/photos/one.jpg']));

        expect(removed).toBe(0);
        expect(hashCache.getHash('/photos/one.jpg')).toBeDefined();
    });

    test('keeps an entry the walk saw at a Windows path', async () => {
        // The same failure on the other separator: stored as "C:/photos/one.jpg", walked as
        // "C:\photos\one.jpg".
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addSourceHash('C:\\photos\\one.jpg', { hash: createHash('a'), length: 1, lastModified: new Date(1000) });

        const removed = hashCache.removeSourceEntriesNotIn(new Set(['C:\\photos\\one.jpg']));

        expect(removed).toBe(0);
        expect(hashCache.getHash('C:\\photos\\one.jpg')).toBeDefined();
    });

    test('still drops an absolute path the walk did not see', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addSourceHash('/photos/gone.jpg', { hash: createHash('a'), length: 1, lastModified: new Date(1000) });

        expect(hashCache.removeSourceEntriesNotIn(new Set(['/photos/one.jpg']))).toBe(1);
        expect(hashCache.getHash('/photos/gone.jpg')).toBeUndefined();
    });

    test('a sweep survives a save, so the dropped entries are gone for the next run too', async () => {
        const hashCache = new HashCache(cacheDir);
        await hashCache.load();
        hashCache.addSourceHash('still-here', { hash: createHash('a'), length: 1, lastModified: new Date(1000) });
        hashCache.addSourceHash('deleted-from-device', { hash: createHash('b'), length: 2, lastModified: new Date(2000) });
        await hashCache.save();

        hashCache.removeSourceEntriesNotIn(new Set(['still-here']));
        await hashCache.save();

        const onDisk = await readCacheFile();
        expect(onDisk!.map(entry => entry.key)).toEqual(['still-here']);
    });
});

describe('an unrecognised file format', () => {
    let cacheDir: string;

    beforeEach(() => {
        cacheDir = createTestTempDir('hash-cache-version-test');
    });

    test('is discarded rather than read, whatever its version number says', async () => {
        // The cache is throwaway: everything in it can be recomputed, so a file written by any other
        // version of the format is thrown away and rebuilt rather than migrated. This is written as a
        // higher version deliberately: the rule is "not equal", not "older than".
        const entries = [makeEntry('a/one.txt')];
        const fileBytes = encodeEntries(entries);
        fileBytes.writeUInt32LE(999, 0);
        // The checksum covers the version, so it has to be recomputed or the file is rejected for
        // being corrupt instead, which would prove nothing about the version check.
        const dataWithoutChecksum = fileBytes.subarray(0, fileBytes.length - 32);
        const rewritten = Buffer.concat([dataWithoutChecksum, crypto.createHash('sha256').update(dataWithoutChecksum).digest()]);

        await fs.mkdir(cacheDir, { recursive: true });
        await fs.writeFile(path.join(cacheDir, 'hash-cache-x.dat'), rewritten);

        const hashCache = new HashCache(cacheDir);
        const loaded = await hashCache.load();

        expect(loaded).toBe(false);
        expect(hashCache.getEntryCount()).toBe(0);
    });
});
