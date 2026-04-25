// Mock heavy workspace packages that have ESM-only transitive dependencies.
jest.mock('api', () => ({}));
jest.mock('storage', () => ({ createStorage: jest.fn(), loadEncryptionKeysFromPem: jest.fn(), generateKeyPair: jest.fn(), exportPublicKeyToPem: jest.fn(), pathJoin: jest.fn() }));
jest.mock('task-queue', () => ({ setQueueBackend: jest.fn() }));
jest.mock('merkle-tree', () => ({}));
jest.mock('../../lib/worker-pool-bun', () => ({ WorkerPoolBun: jest.fn() }));
jest.mock('../../lib/directory-picker', () => ({ getDirectoryForCommand: jest.fn() }));

// Mock the vault module so tests don't touch the real keychain.
jest.mock('vault', () => ({
    getVault: jest.fn(),
    getDefaultVaultType: jest.fn().mockReturnValue('plaintext'),
}));

import { getDefaultS3Config } from '../../lib/init-cmd';
import { getVault } from 'vault';

const mockGetVault = getVault as jest.Mock;

//
// Builds a minimal vault mock whose get() resolves to the given secret or undefined.
//
function makeMockVault(secret: { name: string; type: string; value: string } | undefined) {
    return {
        get: jest.fn().mockResolvedValue(secret),
        list: jest.fn(),
        set: jest.fn(),
        delete: jest.fn(),
        checkPrereqs: jest.fn(),
    };
}

describe('getDefaultS3Config', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('returns credentials when the default:s3 secret exists', async () => {
        const credentials = {
            region: 'us-east-1',
            accessKeyId: 'AKID123',
            secretAccessKey: 'secret123',
            endpoint: 'https://syd1.digitaloceanspaces.com',
        };
        const mockVault = makeMockVault({ name: 'default:s3', type: 's3-credentials', value: JSON.stringify(credentials) });
        mockGetVault.mockReturnValue(mockVault);

        const result = await getDefaultS3Config();

        expect(result).toEqual(credentials);
        expect(mockVault.get).toHaveBeenCalledWith('default:s3');
    });

    test('returns undefined when the default:s3 secret does not exist', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);

        const result = await getDefaultS3Config();

        expect(result).toBeUndefined();
    });

    test('returns credentials without endpoint when endpoint is not stored', async () => {
        const credentials = {
            region: 'us-east-1',
            accessKeyId: 'AKID123',
            secretAccessKey: 'secret123',
        };
        const mockVault = makeMockVault({ name: 'default:s3', type: 's3-credentials', value: JSON.stringify(credentials) });
        mockGetVault.mockReturnValue(mockVault);

        const result = await getDefaultS3Config();

        expect(result).toEqual({ ...credentials, endpoint: undefined });
    });
});
