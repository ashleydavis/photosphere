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
jest.mock('lan-share-network', () => ({
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

    test('--raw writes only the bare value to stdout', async () => {
        const multiLineValue = '-----BEGIN PRIVATE KEY-----\nABC\n-----END PRIVATE KEY-----';
        const mockVault = makeMockVault({ name: 'enc-key', type: 'encryption-key', value: multiLineValue });
        mockGetVault.mockReturnValue(mockVault);
        const writeSpy = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);

        await secretsView({ yes: true, name: 'enc-key', raw: true });

        expect(writeSpy).toHaveBeenCalledWith(multiLineValue);
        // No labels, so the captured output can be fed straight to another program.
        expect(mockLogInfo).not.toHaveBeenCalled();

        writeSpy.mockRestore();
    });

    test('without --raw the value is logged with labels rather than written to stdout', async () => {
        const mockVault = makeMockVault({ name: 'enc-key', type: 'encryption-key', value: 'the-value' });
        mockGetVault.mockReturnValue(mockVault);
        const writeSpy = jest.spyOn(process.stdout, 'write').mockImplementation(() => true);

        await secretsView({ yes: true, name: 'enc-key' });

        expect(writeSpy).not.toHaveBeenCalled();
        expect(mockLogInfo).toHaveBeenCalledWith(expect.stringContaining('the-value'));

        writeSpy.mockRestore();
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
