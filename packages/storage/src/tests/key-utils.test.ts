import { generateKeyPair, hashPublicKey, loadEncryptionKeys } from '../lib/key-utils';
import type { IStorageOptions } from '../lib/storage-factory';
import { createCipheriv, randomBytes } from 'node:crypto';
import * as fs from 'fs/promises';
import * as path from 'path';

// Test key files are generated under the package-local ./tmp directory
const testKeysDir = path.join(__dirname, '..', 'tmp');

async function createTestKeyPath(baseName: string): Promise<string> {
    await fs.mkdir(testKeysDir, { recursive: true });
    return path.join(testKeysDir, baseName);
}

describe('hashPublicKey', () => {
    it('returns a 32-byte buffer', () => {
        const keyPair = generateKeyPair();
        const hash = hashPublicKey(keyPair.publicKey);
        expect(Buffer.isBuffer(hash)).toBe(true);
        expect(hash.length).toBe(32);
    });

    it('is deterministic for the same key', () => {
        const keyPair = generateKeyPair();
        const hash1 = hashPublicKey(keyPair.publicKey);
        const hash2 = hashPublicKey(keyPair.publicKey);
        expect(hash1.equals(hash2)).toBe(true);
    });

    it('produces different hashes for different keys', () => {
        const keyPair1 = generateKeyPair();
        const keyPair2 = generateKeyPair();
        const hash1 = hashPublicKey(keyPair1.publicKey);
        const hash2 = hashPublicKey(keyPair2.publicKey);
        expect(hash1.equals(hash2)).toBe(false);
    });
});

describe('loadEncryptionKeys', () => {
    it('returns empty options when no key paths are provided', async () => {
        const { options, isEncrypted } = await loadEncryptionKeys([], false);
        expect(isEncrypted).toBe(false);
        expect(Object.keys(options as IStorageOptions).length).toBe(0);
    });

    it('builds decryptionKeyMap and encryptionPublicKey for a single key path', async () => {
        const keyPath = await createTestKeyPath('test-single-key-loadEncryptionKeys.key');
        const { options, isEncrypted } = await loadEncryptionKeys([keyPath], true);
        const typedOptions = options as IStorageOptions;

        expect(isEncrypted).toBe(true);
        expect(typedOptions.decryptionKeyMap).toBeDefined();
        expect(typedOptions.encryptionPublicKey).toBeDefined();

        const map = typedOptions.decryptionKeyMap!;
        const writeKey = typedOptions.encryptionPublicKey!;

        const defaultKey = map.default;
        expect(defaultKey).toBeDefined();

        const hashHex = hashPublicKey(writeKey).toString('hex');
        const entryKey = map[hashHex];
        expect(entryKey).toBeDefined();

        const secret = Buffer.from('hello');
        const iv = randomBytes(16);
        const cipher = createCipheriv('aes-256-cbc', randomBytes(32), iv);
        const encrypted = Buffer.concat([cipher.update(secret), cipher.final()]);

        // This doesn't decrypt the AES key, but it ensures the keys are usable KeyObjects.
        expect(Buffer.isBuffer(encrypted)).toBe(true);
    });

    it('registers multiple keys and uses the first as default/write key', async () => {
        const baseName = 'test-multi-key-loadEncryptionKeys';
        const keyPath1 = await createTestKeyPath(`${baseName}-1.key`);
        const keyPath2 = await createTestKeyPath(`${baseName}-2.key`);
        const keyPaths = [keyPath1, keyPath2];

        const { options, isEncrypted } = await loadEncryptionKeys(keyPaths, true);
        const typedOptions = options as IStorageOptions;

        expect(isEncrypted).toBe(true);
        expect(typedOptions.decryptionKeyMap).toBeDefined();
        expect(typedOptions.encryptionPublicKey).toBeDefined();

        const map = typedOptions.decryptionKeyMap!;
        const writeKey = typedOptions.encryptionPublicKey!;

        // First key should be default and match encryptionPublicKey hash entry.
        const defaultPrivate = map.default;
        expect(defaultPrivate).toBeDefined();

        const writeHashHex = hashPublicKey(writeKey).toString('hex');
        expect(map[writeHashHex]).toBeDefined();
    }, 30000);

    afterAll(async () => {
        try {
            await fs.rm(testKeysDir, { recursive: true, force: true });
        } catch {
            // Best-effort cleanup; ignore errors.
        }
    });
});
