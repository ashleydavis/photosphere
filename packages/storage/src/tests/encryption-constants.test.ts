import {
    ENCRYPTION_TAG,
    ENCRYPTION_FORMAT_VERSION,
    ENCRYPTION_TYPE,
    PUBLIC_KEY_HASH_LENGTH,
} from '../lib/encryption-constants';

describe('encryption constants', () => {
    it('ENCRYPTION_TAG is 4 bytes and equals PSEN', () => {
        expect(ENCRYPTION_TAG.length).toBe(4);
        expect(ENCRYPTION_TAG.toString('ascii')).toBe('PSEN');
    });

    it('ENCRYPTION_FORMAT_VERSION is 1', () => {
        expect(ENCRYPTION_FORMAT_VERSION).toBe(1);
    });

    it('ENCRYPTION_TYPE is 4-character string A2CB', () => {
        expect(ENCRYPTION_TYPE).toBe('A2CB');
        expect(ENCRYPTION_TYPE.length).toBe(4);
    });

    it('PUBLIC_KEY_HASH_LENGTH is 32', () => {
        expect(PUBLIC_KEY_HASH_LENGTH).toBe(32);
    });
});
