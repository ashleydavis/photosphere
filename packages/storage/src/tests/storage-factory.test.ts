import path from 'node:path';
import { pathJoin, createStorage } from '../lib/storage-factory';
import { StoragePrefixWrapper } from '../lib/storage-prefix-wrapper';
import { generateKeyPair, hashPublicKey } from '../lib/key-utils';

describe('pathJoin', () => {
    test('joins multiple segments with forward slashes', () => {
        expect(pathJoin('a', 'b', 'c')).toBe('a/b/c');
    });

    test('filters out empty string segments', () => {
        expect(pathJoin('a', '', 'b')).toBe('a/b');
    });

    test('removes trailing slash', () => {
        expect(pathJoin('a', 'b/')).toBe('a/b');
    });

    test('collapses consecutive slashes', () => {
        expect(pathJoin('a//b')).toBe('a/b');
    });

    test('returns empty string when all segments are empty', () => {
        expect(pathJoin('', '')).toBe('');
    });

    test('returns empty string when called with no arguments', () => {
        expect(pathJoin()).toBe('');
    });

    test('handles a single segment with no slashes', () => {
        expect(pathJoin('foo')).toBe('foo');
    });

    test('handles a protocol-style prefix followed by a path', () => {
        expect(pathJoin('fs:', '/some/path')).toBe('fs:/some/path');
    });
});

describe('createStorage', () => {
    test('throws when rootPath is an empty string', () => {
        expect(() => createStorage('')).toThrow('Path is required');
    });

    describe('fs: prefix', () => {
        test('returns type "fs"', () => {
            const { type } = createStorage('fs:/some/path');
            expect(type).toBe('fs');
        });

        test('normalizedPath resolves the path after stripping the prefix', () => {
            const { normalizedPath } = createStorage('fs:/some/path');
            expect(normalizedPath).toBe(path.resolve('/some/path').replace(/\\/g, '/'));
        });

        test('storage is a StoragePrefixWrapper', () => {
            const { storage } = createStorage('fs:/some/path');
            expect(storage).toBeInstanceOf(StoragePrefixWrapper);
        });

        test('rawStorage is a StoragePrefixWrapper', () => {
            const { rawStorage } = createStorage('fs:/some/path');
            expect(rawStorage).toBeInstanceOf(StoragePrefixWrapper);
        });

        test('storage and rawStorage have the same location', () => {
            const { storage, rawStorage } = createStorage('fs:/some/path');
            expect(storage.location).toBe(rawStorage.location);
        });
    });

    describe('s3: prefix', () => {
        test('returns type "s3"', () => {
            const { type } = createStorage('s3:my-bucket/my-prefix');
            expect(type).toBe('s3');
        });

        test('normalizedPath strips the s3: prefix without resolving', () => {
            const { normalizedPath } = createStorage('s3:my-bucket/my-prefix');
            expect(normalizedPath).toBe('my-bucket/my-prefix');
        });

        test('storage is a StoragePrefixWrapper', () => {
            const { storage } = createStorage('s3:my-bucket/my-prefix');
            expect(storage).toBeInstanceOf(StoragePrefixWrapper);
        });

        test('storage and rawStorage have the same location', () => {
            const { storage, rawStorage } = createStorage('s3:my-bucket/my-prefix');
            expect(storage.location).toBe(rawStorage.location);
        });
    });

    describe('no prefix (bare path)', () => {
        test('returns type "fs" for a bare absolute path', () => {
            const { type } = createStorage('/absolute/path');
            expect(type).toBe('fs');
        });

        test('normalizedPath resolves the bare path', () => {
            const { normalizedPath } = createStorage('/absolute/path');
            expect(normalizedPath).toBe(path.resolve('/absolute/path').replace(/\\/g, '/'));
        });

        test('storage and rawStorage have the same location', () => {
            const { storage, rawStorage } = createStorage('/absolute/path');
            expect(storage.location).toBe(rawStorage.location);
        });
    });

    describe('with encryption options', () => {
        const keyPair = generateKeyPair();
        const keyMap = {
            default: keyPair.privateKey,
            [hashPublicKey(keyPair.publicKey).toString('hex')]: keyPair.privateKey,
        };

        test('returns type "encrypted-fs" when both keys are provided', () => {
            const { type } = createStorage('fs:/some/path', undefined, {
                encryptionPublicKey: keyPair.publicKey,
                decryptionKeyMap: keyMap,
            });
            expect(type).toBe('encrypted-fs');
        });

        test('returns type "encrypted-s3" for s3 path with encryption', () => {
            const { type } = createStorage('s3:my-bucket/path', undefined, {
                encryptionPublicKey: keyPair.publicKey,
                decryptionKeyMap: keyMap,
            });
            expect(type).toBe('encrypted-s3');
        });

        test('storage and rawStorage have the same location when encrypted', () => {
            const { storage, rawStorage } = createStorage('fs:/some/path', undefined, {
                encryptionPublicKey: keyPair.publicKey,
                decryptionKeyMap: keyMap,
            });
            expect(storage.location).toBe(rawStorage.location);
        });

        test('rawStorage is a StoragePrefixWrapper', () => {
            const { rawStorage } = createStorage('fs:/some/path', undefined, {
                encryptionPublicKey: keyPair.publicKey,
                decryptionKeyMap: keyMap,
            });
            expect(rawStorage).toBeInstanceOf(StoragePrefixWrapper);
        });

        test('does not encrypt when only decryptionKeyMap is provided', () => {
            const { type } = createStorage('fs:/some/path', undefined, {
                decryptionKeyMap: keyMap,
            });
            expect(type).toBe('fs');
        });

        test('does not encrypt when only encryptionPublicKey is provided', () => {
            const { type } = createStorage('fs:/some/path', undefined, {
                encryptionPublicKey: keyPair.publicKey,
            });
            expect(type).toBe('fs');
        });
    });
});
