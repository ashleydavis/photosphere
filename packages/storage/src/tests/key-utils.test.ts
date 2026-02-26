import { generateKeyPair, hashPublicKey } from '../lib/key-utils';

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
