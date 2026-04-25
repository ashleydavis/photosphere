jest.mock('node-utils', () => ({
    exit: jest.fn().mockResolvedValue(undefined),
    getDatabases: jest.fn().mockResolvedValue([]),
    addDatabaseEntry: jest.fn().mockResolvedValue(undefined),
    TestUuidGenerator: jest.fn(),
    TestTimestampProvider: jest.fn(),
    registerTerminationCallback: jest.fn(),
    pathExists: jest.fn(),
}));
jest.mock('vault', () => ({
    getVault: jest.fn(),
    getDefaultVaultType: jest.fn().mockReturnValue('plaintext'),
}));
jest.mock('lan-share', () => ({
    LanShareSender: jest.fn(),
    LanShareReceiver: jest.fn(),
    resolveSecretSharePayload: jest.fn(),
    importSecretPayload: jest.fn(),
}));
jest.mock('fs/promises', () => ({ readFile: jest.fn(), writeFile: jest.fn(), stat: jest.fn() }));
jest.mock('../../lib/init-cmd', () => ({
    findSimilarSecretNames: jest.fn().mockResolvedValue([]),
}));

import { secretsView, secretsEdit, secretsRemove, secretsSend } from '../../cmd/secrets';
import { getVault } from 'vault';
import { exit } from 'node-utils';
import { log } from 'utils';
import { findSimilarSecretNames } from '../../lib/init-cmd';

const mockGetVault = getVault as jest.Mock;
const mockExit = exit as jest.Mock;
const mockFindSimilarSecretNames = findSimilarSecretNames as jest.Mock;
const mockLogInfo = log.info as jest.Mock;
const mockLogError = log.error as jest.Mock;

function makeMockVault(secret: { name: string; type: string; value: string } | undefined) {
    return {
        get: jest.fn().mockResolvedValue(secret),
        list: jest.fn().mockResolvedValue([]),
        set: jest.fn(),
        delete: jest.fn(),
        checkPrereqs: jest.fn().mockResolvedValue({ ok: true }),
    };
}

beforeEach(() => {
    jest.clearAllMocks();
    mockExit.mockResolvedValue(undefined);
});

describe('secretsView', () => {
    test('logs Did you mean hint when secret not found and suggestions exist', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        mockFindSimilarSecretNames.mockResolvedValue(['my-secret']);

        await secretsView({ yes: true, name: 'my-secrt' });

        expect(mockFindSimilarSecretNames).toHaveBeenCalledWith('my-secrt');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('Did you mean'));
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-secret'));
    });

    test('does not log hint when no suggestions exist', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        mockFindSimilarSecretNames.mockResolvedValue([]);

        await secretsView({ yes: true, name: 'my-secrt' });

        expect(mockLogInfo).not.toHaveBeenCalledWith(expect.stringContaining('Did you mean'));
    });
});

describe('secretsEdit', () => {
    test('logs Did you mean hint when secret not found and suggestions exist', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        mockFindSimilarSecretNames.mockResolvedValue(['my-secret']);

        await secretsEdit({ yes: true, name: 'my-secrt' });

        expect(mockFindSimilarSecretNames).toHaveBeenCalledWith('my-secrt');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('Did you mean'));
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-secret'));
    });
});

describe('secretsRemove', () => {
    test('logs Did you mean hint when secret not found and suggestions exist', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        mockFindSimilarSecretNames.mockResolvedValue(['my-secret']);

        await secretsRemove({ yes: true, name: 'my-secrt' });

        expect(mockFindSimilarSecretNames).toHaveBeenCalledWith('my-secrt');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('Did you mean'));
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-secret'));
    });
});

describe('secretsSend', () => {
    test('logs Did you mean hint when secret not found and suggestions exist', async () => {
        const mockVault = makeMockVault(undefined);
        mockGetVault.mockReturnValue(mockVault);
        mockFindSimilarSecretNames.mockResolvedValue(['my-secret']);

        await secretsSend({ yes: true, name: 'my-secrt' });

        expect(mockFindSimilarSecretNames).toHaveBeenCalledWith('my-secrt');
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('Did you mean'));
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('my-secret'));
    });

    test('does not call findSimilarSecretNames when no name is provided', async () => {
        const mockVault = makeMockVault(undefined);
        mockVault.list.mockResolvedValue([]);
        mockGetVault.mockReturnValue(mockVault);

        await secretsSend({ yes: true });

        expect(mockFindSimilarSecretNames).not.toHaveBeenCalled();
    });
});
