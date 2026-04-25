// Mock heavy workspace packages that have ESM-only transitive dependencies.
jest.mock('node-utils', () => ({
    exit: jest.fn(),
    pathExists: jest.fn(),
    TestUuidGenerator: jest.fn(),
    TestTimestampProvider: jest.fn(),
    registerTerminationCallback: jest.fn(),
}));
jest.mock('api', () => ({
    getDatabases: jest.fn().mockResolvedValue([]),
}));
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

// Mock node:crypto so key operations don't require real keys.
jest.mock('node:crypto', () => ({
    createPrivateKey: jest.fn().mockReturnValue({}),
    createPublicKey: jest.fn().mockReturnValue({}),
}));

// Mock fs/promises so file reads are controllable in tests.
jest.mock('fs/promises', () => ({
    readFile: jest.fn(),
}));

// Mock clack prompts to control interactive prompts in tests.
// Note: moduleNameMapper maps './clack/prompts' to the same resolved path,
// so this mock is shared between the test and init-cmd.ts.
jest.mock('./clack/prompts', () => ({
    select: jest.fn(),
    text: jest.fn(),
    multiline: jest.fn(),
    isCancel: jest.fn().mockReturnValue(false),
    outro: jest.fn(),
    confirm: jest.fn(),
    password: jest.fn(),
}));

// Mock fuzzy-match so tests don't depend on the real Levenshtein implementation.
jest.mock('fuzzy-match', () => ({
    fuzzyMatch: jest.fn().mockReturnValue([]),
}));

import { getDefaultS3Config, promptToAddKey, promptToGenerateOrAddKey, resolveKeyPemsWithPrompt, findSimilarDatabaseNames, findSimilarSecretNames, findSimilarKeyNames } from '../../lib/init-cmd';
import { getVault } from 'vault';
import { fuzzyMatch } from 'fuzzy-match';
import { generateKeyPair, exportPublicKeyToPem } from 'storage';
import * as fsPromises from 'fs/promises';
import { getDatabases } from 'api';

const mockGetVault = getVault as jest.Mock;
const mockGenerateKeyPair = generateKeyPair as jest.Mock;
const mockExportPublicKeyToPem = exportPublicKeyToPem as jest.Mock;
const mockFsReadFile = fsPromises.readFile as jest.MockedFunction<typeof fsPromises.readFile>;
const mockGetDatabases = getDatabases as jest.Mock;
const mockFuzzyMatch = fuzzyMatch as jest.Mock;

// Access the clack prompt mocks via jest.requireMock since the moduleNameMapper
// redirects './clack/prompts' to the shared mock file.
const clackMock = jest.requireMock('./clack/prompts') as {
    select: jest.Mock;
    text: jest.Mock;
    multiline: jest.Mock;
    isCancel: jest.Mock;
    outro: jest.Mock;
};

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

describe('promptToAddKey', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        clackMock.isCancel.mockReturnValue(false);
        mockExportPublicKeyToPem.mockReturnValue('---PUBLIC---');
    });

    test('returns undefined in non-interactive mode', async () => {
        const result = await promptToAddKey('my-key', true);

        expect(result).toBeUndefined();
        expect(clackMock.select).not.toHaveBeenCalled();
    });

    test('returns undefined when user selects cancel', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        clackMock.select.mockResolvedValue('cancel');

        const result = await promptToAddKey('my-key', false);

        expect(result).toBeUndefined();
        expect(mockVault.set).not.toHaveBeenCalled();
    });

    test('stores PEM in vault and returns key pair when user pastes PEM', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        clackMock.select.mockResolvedValue('paste');
        clackMock.multiline.mockResolvedValue('test-private-pem');

        const result = await promptToAddKey('my-key', false);

        expect(mockVault.set).toHaveBeenCalledWith({
            name: 'my-key',
            type: 'encryption-key',
            value: 'test-private-pem',
        });
        expect(result).toEqual({ privateKeyPem: 'test-private-pem', publicKeyPem: '---PUBLIC---' });
    });

    test('reads PEM from file and stores in vault when user imports from file', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        clackMock.select.mockResolvedValue('import');
        clackMock.text.mockResolvedValue('/tmp/test.key');
        mockFsReadFile.mockResolvedValue('file-private-pem' as never);

        const result = await promptToAddKey('my-key', false);

        expect(mockFsReadFile).toHaveBeenCalledWith('/tmp/test.key', 'utf-8');
        expect(mockVault.set).toHaveBeenCalledWith({
            name: 'my-key',
            type: 'encryption-key',
            value: 'file-private-pem',
        });
        expect(result).toEqual({ privateKeyPem: 'file-private-pem', publicKeyPem: '---PUBLIC---' });
    });
});

describe('promptToGenerateOrAddKey', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        clackMock.isCancel.mockReturnValue(false);
        mockExportPublicKeyToPem.mockReturnValue('---PUBLIC---');
    });

    test('returns undefined in non-interactive mode', async () => {
        const result = await promptToGenerateOrAddKey('my-key', true);

        expect(result).toBeUndefined();
        expect(clackMock.select).not.toHaveBeenCalled();
    });

    test('generates key pair, stores in vault, and returns it when user selects generate', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        clackMock.select.mockResolvedValue('generate');
        mockGenerateKeyPair.mockReturnValue({
            privateKey: { export: jest.fn().mockReturnValue('generated-private-pem') },
            publicKey: {},
        });

        const result = await promptToGenerateOrAddKey('my-key', false);

        expect(mockVault.set).toHaveBeenCalledWith({
            name: 'my-key',
            type: 'encryption-key',
            value: 'generated-private-pem',
        });
        expect(result).toEqual({ privateKeyPem: 'generated-private-pem', publicKeyPem: '---PUBLIC---' });
    });
});

describe('resolveKeyPemsWithPrompt', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        clackMock.isCancel.mockReturnValue(false);
        mockExportPublicKeyToPem.mockReturnValue('---PUBLIC---');
    });

    test('returns empty array when no key name is given', async () => {
        const result = await resolveKeyPemsWithPrompt(undefined, false, false);

        expect(result).toEqual([]);
        expect(clackMock.select).not.toHaveBeenCalled();
    });

    test('returns key pems from vault when key is found without prompting', async () => {
        const mockVault = makeMockVault({ name: 'my-key', type: 'encryption-key', value: 'stored-pem' });
        mockGetVault.mockReturnValue(mockVault);

        const result = await resolveKeyPemsWithPrompt('my-key', false, false);

        expect(result).toEqual([{ privateKeyPem: 'stored-pem', publicKeyPem: '---PUBLIC---' }]);
        expect(clackMock.select).not.toHaveBeenCalled();
    });

    test('calls promptToAddKey when key is missing and canGenerate is false', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        clackMock.select.mockResolvedValue('cancel');

        const result = await resolveKeyPemsWithPrompt('missing-key', false, false);

        expect(clackMock.select).toHaveBeenCalled();
        expect(result).toEqual([]);
    });

    test('calls promptToGenerateOrAddKey when key is missing and canGenerate is true', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        clackMock.select.mockResolvedValue('generate');
        mockGenerateKeyPair.mockReturnValue({
            privateKey: { export: jest.fn().mockReturnValue('new-private-pem') },
            publicKey: {},
        });

        const result = await resolveKeyPemsWithPrompt('missing-key', false, true);

        expect(mockVault.set).toHaveBeenCalledWith({
            name: 'missing-key',
            type: 'encryption-key',
            value: 'new-private-pem',
        });
        expect(result).toEqual([{ privateKeyPem: 'new-private-pem', publicKeyPem: '---PUBLIC---' }]);
    });
});

describe('findSimilarDatabaseNames', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('returns empty array when fuzzyMatch returns nothing', async () => {
        mockGetDatabases.mockResolvedValue([{ name: 'mydb', path: '/path' }]);
        mockFuzzyMatch.mockReturnValue([]);

        const result = await findSimilarDatabaseNames('my-database');

        expect(result).toEqual([]);
    });

    test('returns names returned by fuzzyMatch', async () => {
        mockGetDatabases.mockResolvedValue([
            { name: 'my-db', path: '/path1' },
            { name: 'my-database', path: '/path2' },
        ]);
        mockFuzzyMatch.mockReturnValue(['my-db']);

        const result = await findSimilarDatabaseNames('my-databse');

        expect(result).toEqual(['my-db']);
    });

    test('calls fuzzyMatch with the query string and database names array', async () => {
        mockGetDatabases.mockResolvedValue([{ name: 'mydb', path: '/path' }]);
        mockFuzzyMatch.mockReturnValue([]);

        await findSimilarDatabaseNames('my-query');

        expect(mockFuzzyMatch).toHaveBeenCalledWith('my-query', ['mydb']);
    });

    test('returns empty array when no databases are registered', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockFuzzyMatch.mockReturnValue([]);

        const result = await findSimilarDatabaseNames('my-database');

        expect(result).toEqual([]);
    });
});

describe('findSimilarSecretNames', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('returns names from fuzzyMatch when no type filter is provided', async () => {
        const mockVault = {
            get: jest.fn(),
            list: jest.fn().mockResolvedValue([
                { name: 'my-secret', type: 'api-key', value: 'val' },
                { name: 'other-secret', type: 'encryption-key', value: 'val' },
            ]),
            set: jest.fn(),
            delete: jest.fn(),
            checkPrereqs: jest.fn(),
        };
        mockGetVault.mockReturnValue(mockVault);
        mockFuzzyMatch.mockReturnValue(['my-secrt']);

        const result = await findSimilarSecretNames('my-secrt');

        expect(result).toEqual(['my-secrt']);
        expect(mockFuzzyMatch).toHaveBeenCalledWith('my-secrt', expect.anything());
    });

    test('filters by type when type is provided', async () => {
        const mockVault = {
            get: jest.fn(),
            list: jest.fn().mockResolvedValue([
                { name: 'my-key', type: 'encryption-key', value: 'pem' },
                { name: 'my-s3', type: 's3-credentials', value: 'creds' },
            ]),
            set: jest.fn(),
            delete: jest.fn(),
            checkPrereqs: jest.fn(),
        };
        mockGetVault.mockReturnValue(mockVault);
        mockFuzzyMatch.mockReturnValue([]);

        await findSimilarSecretNames('my-ke', 'encryption-key');

        expect(mockFuzzyMatch).toHaveBeenCalledWith('my-ke', ['my-key']);
    });

    test('returns empty array when no secrets match', async () => {
        const mockVault = {
            get: jest.fn(),
            list: jest.fn().mockResolvedValue([]),
            set: jest.fn(),
            delete: jest.fn(),
            checkPrereqs: jest.fn(),
        };
        mockGetVault.mockReturnValue(mockVault);
        mockFuzzyMatch.mockReturnValue([]);

        const result = await findSimilarSecretNames('anything');

        expect(result).toEqual([]);
    });
});

describe('findSimilarKeyNames', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('only passes encryption-key entries as candidates', async () => {
        const mockVault = {
            get: jest.fn(),
            list: jest.fn().mockResolvedValue([
                { name: 'my-key', type: 'encryption-key', value: 'pem' },
                { name: 'my-s3', type: 's3-credentials', value: 'creds' },
                { name: 'my-api', type: 'api-key', value: 'key' },
            ]),
            set: jest.fn(),
            delete: jest.fn(),
            checkPrereqs: jest.fn(),
        };
        mockGetVault.mockReturnValue(mockVault);
        mockFuzzyMatch.mockReturnValue([]);

        await findSimilarKeyNames('my-ke');

        expect(mockFuzzyMatch).toHaveBeenCalledWith('my-ke', ['my-key']);
    });

    test('returns names returned by fuzzyMatch', async () => {
        const mockVault = {
            get: jest.fn(),
            list: jest.fn().mockResolvedValue([
                { name: 'my-photos', type: 'encryption-key', value: 'pem' },
            ]),
            set: jest.fn(),
            delete: jest.fn(),
            checkPrereqs: jest.fn(),
        };
        mockGetVault.mockReturnValue(mockVault);
        mockFuzzyMatch.mockReturnValue(['my-photos']);

        const result = await findSimilarKeyNames('my-phtos');

        expect(result).toEqual(['my-photos']);
    });
});
