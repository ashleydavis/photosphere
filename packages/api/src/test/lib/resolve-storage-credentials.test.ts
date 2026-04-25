// ── module mocks ─────────────────────────────────────────────────────────────

const mockVaultGet = jest.fn();

jest.mock('vault', () => ({
    getDefaultVaultType: () => 'plaintext',
    getVault: () => ({ get: mockVaultGet }),
}));

jest.mock('../../lib/databases-config', () => ({
    getDatabases: jest.fn(),
}));

jest.mock('fs/promises', () => ({
    access: jest.fn().mockRejectedValue(new Error('ENOENT')),
    readFile: jest.fn(),
}));

jest.mock('node:crypto', () => ({
    createPrivateKey: jest.fn().mockReturnValue({}),
    createPublicKey: jest.fn().mockReturnValue({}),
}));

jest.mock('storage', () => ({
    exportPublicKeyToPem: jest.fn().mockReturnValue('-----PUBLIC-----'),
}));

jest.mock('utils', () => ({
    log: { verbose: jest.fn(), error: jest.fn(), exception: jest.fn(), info: jest.fn() },
}));

// ── imports after mocks ───────────────────────────────────────────────────────

import { resolveStorageCredentials } from '../../lib/resolve-storage-credentials';
import { getDatabases } from '../../lib/databases-config';
import * as fsPromises from 'fs/promises';

const mockGetDatabases = getDatabases as jest.MockedFunction<typeof getDatabases>;
const mockFsAccess = fsPromises.access as jest.MockedFunction<typeof fsPromises.access>;
const mockFsReadFile = fsPromises.readFile as jest.MockedFunction<typeof fsPromises.readFile>;

// ── helpers ───────────────────────────────────────────────────────────────────

//
// Clears env vars set during tests to avoid cross-test pollution.
//
function clearEnvVars() {
    delete process.env.AWS_ACCESS_KEY_ID;
    delete process.env.AWS_SECRET_ACCESS_KEY;
    delete process.env.AWS_REGION;
    delete process.env.AWS_ENDPOINT;
    delete process.env.PSI_ENCRYPTION_KEY;
    delete process.env.GOOGLE_API_KEY;
}

// ── tests ─────────────────────────────────────────────────────────────────────

describe('resolveStorageCredentials', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        clearEnvVars();
        mockGetDatabases.mockResolvedValue([]);
        mockFsAccess.mockRejectedValue(new Error('ENOENT'));
    });

    afterEach(() => {
        clearEnvVars();
    });

    test('returns empty credentials for a local path with no database entry', async () => {
        const result = await resolveStorageCredentials('/local/db');

        expect(result.s3Config).toBeUndefined();
        expect(result.encryptionKeyPems).toEqual([]);
        expect(result.googleApiKey).toBeUndefined();
    });

    test('does not look up S3 credentials for a non-s3: path', async () => {
        mockGetDatabases.mockResolvedValue([
            { name: 'db', description: '', path: '/local/db', s3Key: 'my-s3-secret' } as any,
        ]);

        const result = await resolveStorageCredentials('/local/db');

        expect(mockVaultGet).not.toHaveBeenCalledWith('my-s3-secret');
        expect(result.s3Config).toBeUndefined();
    });

    test('loads S3 credentials from vault for an s3: path', async () => {
        mockGetDatabases.mockResolvedValue([
            { name: 'db', description: '', path: 's3:my-bucket:/photos', s3Key: 's3secret' } as any,
        ]);
        mockVaultGet.mockResolvedValue({
            name: 's3secret',
            type: 's3-credentials',
            value: JSON.stringify({
                region: 'us-west-2',
                accessKeyId: 'AKID',
                secretAccessKey: 'SECRET',
                endpoint: 'https://s3.example.com',
            }),
        });

        const result = await resolveStorageCredentials('s3:my-bucket:/photos');

        expect(result.s3Config).toBeDefined();
        expect(result.s3Config!.region).toBe('us-west-2');
        expect(result.s3Config!.accessKeyId).toBe('AKID');
        expect(result.s3Config!.secretAccessKey).toBe('SECRET');
        expect(result.s3Config!.endpoint).toBe('https://s3.example.com');
    });

    test('falls back to AWS env vars for s3: path when vault entry is missing', async () => {
        mockGetDatabases.mockResolvedValue([]);
        process.env.AWS_ACCESS_KEY_ID = 'ENV_AKID';
        process.env.AWS_SECRET_ACCESS_KEY = 'ENV_SECRET';
        process.env.AWS_REGION = 'eu-central-1';

        const result = await resolveStorageCredentials('s3:my-bucket:/photos');

        expect(result.s3Config).toBeDefined();
        expect(result.s3Config!.accessKeyId).toBe('ENV_AKID');
        expect(result.s3Config!.secretAccessKey).toBe('ENV_SECRET');
        expect(result.s3Config!.region).toBe('eu-central-1');
    });

    test('vault entry takes priority over AWS env vars for S3 credentials', async () => {
        mockGetDatabases.mockResolvedValue([
            { name: 'db', description: '', path: 's3:my-bucket:/photos', s3Key: 's3secret' } as any,
        ]);
        mockVaultGet.mockResolvedValue({
            name: 's3secret',
            type: 's3-credentials',
            value: JSON.stringify({ region: 'us-west-2', accessKeyId: 'VAULT_AKID', secretAccessKey: 'VAULT_SECRET' }),
        });
        process.env.AWS_ACCESS_KEY_ID = 'ENV_AKID';
        process.env.AWS_SECRET_ACCESS_KEY = 'ENV_SECRET';

        const result = await resolveStorageCredentials('s3:my-bucket:/photos');

        expect(result.s3Config!.accessKeyId).toBe('VAULT_AKID');
    });

    test('loads encryption key from vault when database entry has encryptionKey (JSON format)', async () => {
        mockGetDatabases.mockResolvedValue([
            { name: 'db', description: '', path: '/local/db', encryptionKey: 'enc-secret' } as any,
        ]);
        mockVaultGet.mockResolvedValue({
            name: 'enc-secret',
            type: 'encryption-key',
            value: JSON.stringify({
                label: 'My Key',
                privateKeyPem: '-----PRIVATE-----',
                publicKeyPem: '-----PUBLIC-----',
            }),
        });

        const result = await resolveStorageCredentials('/local/db');

        expect(result.encryptionKeyPems).toHaveLength(1);
        expect(result.encryptionKeyPems[0].privateKeyPem).toBe('-----PRIVATE-----');
        expect(result.encryptionKeyPems[0].publicKeyPem).toBe('-----PUBLIC-----');
    });

    test('throws when database entry encryptionKey is set but vault entry is missing', async () => {
        mockGetDatabases.mockResolvedValue([
            { name: 'db', description: '', path: '/local/db', encryptionKey: 'missing-enc' } as any,
        ]);
        mockVaultGet.mockResolvedValue(undefined);

        await expect(resolveStorageCredentials('/local/db')).rejects.toThrow(
            'Encryption key "missing-enc" not found in vault'
        );
    });

    test('resolves encryptionKey param as a vault secret name when it is not a file path', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockVaultGet.mockResolvedValue({
            name: 'my-enc-secret',
            type: 'encryption-key',
            value: JSON.stringify({
                label: 'Key',
                privateKeyPem: '-----PRIV-----',
                publicKeyPem: '-----PUB-----',
            }),
        });

        const result = await resolveStorageCredentials('/local/db', 'my-enc-secret');

        expect(result.encryptionKeyPems).toHaveLength(1);
        expect(result.encryptionKeyPems[0].privateKeyPem).toBe('-----PRIV-----');
    });

    test('resolves encryptionKey param as a file path when the file exists', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockFsAccess.mockResolvedValue(undefined);
        mockFsReadFile.mockResolvedValue('-----FILE-PRIVATE-----' as any);

        const result = await resolveStorageCredentials('/local/db', '/path/to/key.pem');

        expect(mockFsReadFile).toHaveBeenCalledWith('/path/to/key.pem', 'utf-8');
        expect(result.encryptionKeyPems).toHaveLength(1);
        expect(result.encryptionKeyPems[0].privateKeyPem).toBe('-----FILE-PRIVATE-----');
    });

    test('encryptionKey param takes priority over database entry encryptionKey', async () => {
        mockGetDatabases.mockResolvedValue([
            { name: 'db', description: '', path: '/local/db', encryptionKey: 'entry-enc' } as any,
        ]);
        mockVaultGet.mockImplementation(async (name: string) => {
            if (name === 'param-enc') {
                return {
                    name: 'param-enc',
                    type: 'encryption-key',
                    value: JSON.stringify({ label: 'Param', privateKeyPem: '-----PARAM-----', publicKeyPem: '-----PUB-----' }),
                };
            }
            return undefined;
        });

        const result = await resolveStorageCredentials('/local/db', 'param-enc');

        expect(result.encryptionKeyPems[0].privateKeyPem).toBe('-----PARAM-----');
    });

    test('loads encryption key from PSI_ENCRYPTION_KEY env var (vault secret name) when no other source set', async () => {
        mockGetDatabases.mockResolvedValue([]);
        process.env.PSI_ENCRYPTION_KEY = 'env-enc-secret';
        mockVaultGet.mockResolvedValue({
            name: 'env-enc-secret',
            type: 'encryption-key',
            value: JSON.stringify({ label: 'Env Key', privateKeyPem: '-----ENV-----', publicKeyPem: '-----PUB-----' }),
        });

        const result = await resolveStorageCredentials('/local/db');

        expect(result.encryptionKeyPems).toHaveLength(1);
        expect(result.encryptionKeyPems[0].privateKeyPem).toBe('-----ENV-----');
    });

    test('loads geocoding key from vault when database entry has geocodingKey', async () => {
        mockGetDatabases.mockResolvedValue([
            { name: 'db', description: '', path: '/local/db', geocodingKey: 'geo-secret' } as any,
        ]);
        mockVaultGet.mockResolvedValue({
            name: 'geo-secret',
            type: 'api-key',
            value: JSON.stringify({ label: 'Geocoding', apiKey: 'geo-api-key-123' }),
        });

        const result = await resolveStorageCredentials('/local/db');

        expect(result.googleApiKey).toBe('geo-api-key-123');
    });

    test('falls back to GOOGLE_API_KEY env var when geocoding vault entry is missing', async () => {
        mockGetDatabases.mockResolvedValue([]);
        process.env.GOOGLE_API_KEY = 'env-geo-key';

        const result = await resolveStorageCredentials('/local/db');

        expect(result.googleApiKey).toBe('env-geo-key');
    });

    test('vault geocoding entry takes priority over GOOGLE_API_KEY env var', async () => {
        mockGetDatabases.mockResolvedValue([
            { name: 'db', description: '', path: '/local/db', geocodingKey: 'geo-secret' } as any,
        ]);
        mockVaultGet.mockResolvedValue({
            name: 'geo-secret',
            type: 'api-key',
            value: JSON.stringify({ label: 'Geocoding', apiKey: 'vault-geo-key' }),
        });
        process.env.GOOGLE_API_KEY = 'env-geo-key';

        const result = await resolveStorageCredentials('/local/db');

        expect(result.googleApiKey).toBe('vault-geo-key');
    });

    test('throws when encryptionKey value is neither a file nor a vault secret', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockVaultGet.mockResolvedValue(undefined);

        await expect(resolveStorageCredentials('/local/db', 'nonexistent')).rejects.toThrow(
            'Encryption key "nonexistent" (via -k flag) is neither a file path nor a vault secret name'
        );
    });

    test('s3Config has undefined endpoint when not provided in vault value', async () => {
        mockGetDatabases.mockResolvedValue([
            { name: 'db', description: '', path: 's3:my-bucket:/photos', s3Key: 's3secret' } as any,
        ]);
        mockVaultGet.mockResolvedValue({
            name: 's3secret',
            type: 's3-credentials',
            value: JSON.stringify({ region: 'us-east-1', accessKeyId: 'AK', secretAccessKey: 'SK' }),
        });

        const result = await resolveStorageCredentials('s3:my-bucket:/photos');

        expect(result.s3Config!.endpoint).toBeUndefined();
    });

    test('resolves comma-separated encryptionKey param as multiple vault secrets', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockVaultGet.mockImplementation(async (name: string) => {
            if (name === 'key1') {
                return {
                    name: 'key1',
                    type: 'encryption-key',
                    value: JSON.stringify({ label: 'Key1', privateKeyPem: '-----PRIV1-----', publicKeyPem: '-----PUB1-----' }),
                };
            }
            if (name === 'key2') {
                return {
                    name: 'key2',
                    type: 'encryption-key',
                    value: JSON.stringify({ label: 'Key2', privateKeyPem: '-----PRIV2-----', publicKeyPem: '-----PUB2-----' }),
                };
            }
            return undefined;
        });

        const result = await resolveStorageCredentials('/local/db', 'key1,key2');

        expect(result.encryptionKeyPems).toHaveLength(2);
        expect(result.encryptionKeyPems[0].privateKeyPem).toBe('-----PRIV1-----');
        expect(result.encryptionKeyPems[1].privateKeyPem).toBe('-----PRIV2-----');
    });

    test('resolves comma-separated encryptionKey param with whitespace trimming', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockVaultGet.mockImplementation(async (name: string) => {
            if (name === 'key-a') {
                return {
                    name: 'key-a',
                    type: 'encryption-key',
                    value: JSON.stringify({ label: 'KeyA', privateKeyPem: '-----PRIVA-----', publicKeyPem: '-----PUBA-----' }),
                };
            }
            if (name === 'key-b') {
                return {
                    name: 'key-b',
                    type: 'encryption-key',
                    value: JSON.stringify({ label: 'KeyB', privateKeyPem: '-----PRIVB-----', publicKeyPem: '-----PUBB-----' }),
                };
            }
            return undefined;
        });

        const result = await resolveStorageCredentials('/local/db', ' key-a , key-b ');

        expect(result.encryptionKeyPems).toHaveLength(2);
        expect(mockVaultGet).toHaveBeenCalledWith('key-a');
        expect(mockVaultGet).toHaveBeenCalledWith('key-b');
    });
});
