// Mock all heavy dependencies before importing the module under test.
jest.mock('node-utils', () => ({
    exit: jest.fn().mockResolvedValue(undefined),
    getDatabases: jest.fn().mockResolvedValue([]),
    addDatabaseEntry: jest.fn().mockResolvedValue(undefined),
    updateDatabaseEntry: jest.fn().mockResolvedValue(undefined),
    removeDatabaseEntry: jest.fn().mockResolvedValue(undefined),
    TestUuidGenerator: jest.fn(),
    TestTimestampProvider: jest.fn(),
    registerTerminationCallback: jest.fn(),
    pathExists: jest.fn(),
}));
jest.mock('vault', () => ({
    getVault: jest.fn(),
    getDefaultVaultType: jest.fn().mockReturnValue('plaintext'),
}));
jest.mock('storage', () => ({
    generateKeyPair: jest.fn(),
    exportPublicKeyToPem: jest.fn(),
}));
jest.mock('lan-share', () => ({
    LanShareSender: jest.fn(),
    LanShareReceiver: jest.fn(),
    resolveDatabaseSharePayload: jest.fn(),
    importDatabasePayload: jest.fn(),
}));
jest.mock('../../lib/init-cmd', () => ({
    findSimilarDatabaseNames: jest.fn().mockResolvedValue([]),
    findSimilarKeyNames: jest.fn().mockResolvedValue([]),
    findSimilarSecretNames: jest.fn().mockResolvedValue([]),
    fuzzyMatch: jest.fn(function*() {}),
}));

import { dbsView, dbsAdd, dbsEdit, dbsRemove, dbsSend } from '../../cmd/dbs';
import { getDatabases, exit, addDatabaseEntry } from 'node-utils';
import { log } from 'utils';
import { getVault } from 'vault';
import { findSimilarDatabaseNames, findSimilarKeyNames, findSimilarSecretNames } from '../../lib/init-cmd';

const mockGetDatabases = getDatabases as jest.Mock;
const mockExit = exit as jest.Mock;
const mockAddDatabaseEntry = addDatabaseEntry as jest.Mock;
const mockGetVault = getVault as jest.Mock;
const mockFindSimilarDatabaseNames = findSimilarDatabaseNames as jest.Mock;
const mockFindSimilarKeyNames = findSimilarKeyNames as jest.Mock;
const mockFindSimilarSecretNames = findSimilarSecretNames as jest.Mock;
const mockLogInfo = (log.info as jest.Mock);
const mockLogError = (log.error as jest.Mock);

//
// Builds a minimal vault mock.
//
function makeMockVault(secret: { name: string; type: string; value: string } | undefined) {
    return {
        get: jest.fn().mockResolvedValue(secret),
        list: jest.fn().mockResolvedValue([]),
        set: jest.fn(),
        delete: jest.fn(),
        checkPrereqs: jest.fn(),
    };
}

beforeEach(() => {
    jest.clearAllMocks();
    mockGetDatabases.mockResolvedValue([]);
    mockExit.mockResolvedValue(undefined);
    mockAddDatabaseEntry.mockResolvedValue(undefined);
});

describe('dbsView', () => {
    test('logs Did you mean hint when name lookup fails and suggestions exist', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockFindSimilarDatabaseNames.mockResolvedValue(['my-db']);

        await dbsView({ yes: true, name: 'my-ddb' });

        expect(mockFindSimilarDatabaseNames).toHaveBeenCalledWith('my-ddb');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('Did you mean'));
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-db'));
    });

    test('does not call findSimilarDatabaseNames when no name is given', async () => {
        await dbsView({ yes: true });

        expect(mockFindSimilarDatabaseNames).not.toHaveBeenCalled();
    });
});

describe('dbsEdit', () => {
    test('logs Did you mean hint when name lookup fails and suggestions exist', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockFindSimilarDatabaseNames.mockResolvedValue(['my-db']);

        await dbsEdit({ yes: true, name: 'my-ddb' });

        expect(mockFindSimilarDatabaseNames).toHaveBeenCalledWith('my-ddb');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('Did you mean'));
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-db'));
    });

    test('shows no hint when no similar names exist', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockFindSimilarDatabaseNames.mockResolvedValue([]);

        await dbsEdit({ yes: true, name: 'my-ddb' });

        expect(mockLogInfo).not.toHaveBeenCalledWith(expect.stringContaining('Did you mean'));
    });
});

describe('dbsRemove', () => {
    test('logs Did you mean hint when name lookup fails and suggestions exist', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockFindSimilarDatabaseNames.mockResolvedValue(['my-db']);

        await dbsRemove({ yes: true, name: 'my-ddb' });

        expect(mockFindSimilarDatabaseNames).toHaveBeenCalledWith('my-ddb');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('Did you mean'));
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-db'));
    });
});

describe('dbsSend', () => {
    test('logs Did you mean hint when name lookup fails and suggestions exist', async () => {
        mockGetDatabases.mockResolvedValue([]);
        mockFindSimilarDatabaseNames.mockResolvedValue(['my-db']);

        await dbsSend({ yes: true, name: 'my-ddb' });

        expect(mockFindSimilarDatabaseNames).toHaveBeenCalledWith('my-ddb');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('Did you mean'));
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-db'));
    });
});

describe('dbsAdd --yes with unknown encryption-key', () => {
    test('calls findSimilarKeyNames and logs hint when encryption key is not in vault', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        mockFindSimilarKeyNames.mockResolvedValue(['my-key']);

        await dbsAdd({ yes: true, name: 'newdb', path: '/some/path', encryptionKey: 'my-kye' });

        expect(mockLogError).toHaveBeenCalledWith(expect.stringContaining('my-kye'));
        expect(mockFindSimilarKeyNames).toHaveBeenCalledWith('my-kye');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-key'));
    });
});

describe('dbsAdd --yes with unknown s3-cred', () => {
    test('calls findSimilarSecretNames and logs hint when s3 credential is not in vault', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        mockFindSimilarSecretNames.mockResolvedValue(['my-s3']);

        await dbsAdd({ yes: true, name: 'newdb', path: '/some/path', s3Cred: 'my-s33' });

        expect(mockLogError).toHaveBeenCalledWith(expect.stringContaining('my-s33'));
        expect(mockFindSimilarSecretNames).toHaveBeenCalledWith('my-s33', 's3-credentials');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-s3'));
    });
});

describe('dbsEdit --yes with unknown encryption-key', () => {
    test('calls findSimilarKeyNames and logs hint when encryption key is not in vault', async () => {
        mockGetDatabases.mockResolvedValue([{ name: 'mydb', path: '/some/path', description: '' }]);
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        mockFindSimilarKeyNames.mockResolvedValue(['my-key']);

        await dbsEdit({ yes: true, name: 'mydb', encryptionKey: 'my-kye' });

        expect(mockLogError).toHaveBeenCalledWith(expect.stringContaining('my-kye'));
        expect(mockFindSimilarKeyNames).toHaveBeenCalledWith('my-kye');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-key'));
    });
});
