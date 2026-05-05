// Mock node-utils fs helpers so tests don't touch the real filesystem.
const mockPathExists = jest.fn();
const mockReadToml = jest.fn();
const mockWriteToml = jest.fn();
const mockReadJson = jest.fn();
const mockRemove = jest.fn();

jest.mock('node-utils', () => ({
    pathExists: mockPathExists,
    readToml: mockReadToml,
    writeToml: mockWriteToml,
    readJson: mockReadJson,
    remove: mockRemove,
}));

import {
    loadDatabasesConfig,
    saveDatabasesConfig,
    getDatabases,
    addDatabaseEntry,
    updateDatabaseEntry,
    removeDatabaseEntry,
    getRecentDatabases,
    markDatabaseOpened,
    removeRecentDatabaseName,
    findDatabase,
} from '../../lib/databases-config';
import type { IDatabaseEntry } from 'electron-defs';

//
// Helper to build a minimal database entry.
//
function makeEntry(dbPath: string, name = 'db'): IDatabaseEntry {
    return { name, description: '', path: dbPath } as IDatabaseEntry;
}

//
// Helper to build a minimal TOML-shaped database entry (snake_case).
//
function makeTomlEntry(dbPath: string, name = 'db'): object {
    return { name, description: '', path: dbPath };
}

describe('loadDatabasesConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns default config when no file exists', async () => {
        mockPathExists.mockResolvedValue(false);

        const config = await loadDatabasesConfig();

        expect(config.databases).toEqual([]);
        expect(config.recentDatabaseNames).toEqual([]);
        expect(mockReadToml).not.toHaveBeenCalled();
    });

    test('returns config from TOML when file exists', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: ['alpha'],
        });

        const config = await loadDatabasesConfig();

        expect(config.databases).toHaveLength(1);
        expect(config.databases[0].path).toBe('/a');
        expect(config.recentDatabaseNames).toEqual(['alpha']);
    });

    test('coerces missing databases to []', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ recent_database_names: ['alpha'] });

        const config = await loadDatabasesConfig();

        expect(config.databases).toEqual([]);
    });

    test('coerces missing recent_database_names to []', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [makeTomlEntry('/a')] });

        const config = await loadDatabasesConfig();

        expect(config.recentDatabaseNames).toEqual([]);
    });

    test('converts snake_case TOML fields to camelCase TypeScript fields', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [{ name: 'test', description: '', path: '/a', s3_key: 'myKey', encryption_key: 'encKey', geocoding_key: 'geoKey' }],
            recent_database_names: [],
        });

        const config = await loadDatabasesConfig();

        expect(config.databases[0].s3Key).toBe('myKey');
        expect(config.databases[0].encryptionKey).toBe('encKey');
        expect(config.databases[0].geocodingKey).toBe('geoKey');
    });
});

describe('loadDatabasesConfig migration', () => {
    beforeEach(() => jest.clearAllMocks());

    test('migrates from JSON when TOML does not exist but JSON does', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.json'));
        mockReadJson.mockResolvedValue({
            databases: [makeEntry('/a', 'alpha')],
            recentDatabasePaths: ['/a'],
        });

        const config = await loadDatabasesConfig();

        expect(config.databases).toHaveLength(1);
        expect(config.databases[0].path).toBe('/a');
        expect(config.recentDatabaseNames).toEqual(['alpha']);
        expect(mockWriteToml).toHaveBeenCalled();
        expect(mockRemove).toHaveBeenCalledWith(expect.stringContaining('databases.json'));
    });

    test('coerces missing arrays when migrating from JSON', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.json'));
        mockReadJson.mockResolvedValue({});

        const config = await loadDatabasesConfig();

        expect(config.databases).toEqual([]);
        expect(config.recentDatabaseNames).toEqual([]);
    });

    test('migrates legacy recent_database_paths to recent_database_names and rewrites the file', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha'), makeTomlEntry('/b', 'beta')],
            recent_database_paths: ['/b', '/a'],
        });

        const config = await loadDatabasesConfig();

        expect(config.recentDatabaseNames).toEqual(['beta', 'alpha']);
        expect(mockWriteToml).toHaveBeenCalledTimes(1);
        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_database_names).toEqual(['beta', 'alpha']);
        expect(tomlArg.recent_database_paths).toBeUndefined();
    });

    test('drops legacy paths that no longer match any database during migration', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_paths: ['/missing', '/a'],
        });

        const config = await loadDatabasesConfig();

        expect(config.recentDatabaseNames).toEqual(['alpha']);
    });
});

describe('saveDatabasesConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes TOML with snake_case keys', async () => {
        const config = { databases: [makeEntry('/a')], recentDatabaseNames: [] };

        await saveDatabasesConfig(config);

        expect(mockWriteToml).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ recent_database_names: [] })
        );
    });

    test('converts camelCase entry fields to snake_case in TOML', async () => {
        const entry: IDatabaseEntry = { name: 'test', description: '', path: '/a', s3Key: 'myKey', encryptionKey: 'encKey', geocodingKey: 'geoKey' };
        const config = { databases: [entry], recentDatabaseNames: [] };

        await saveDatabasesConfig(config);

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.databases[0].s3_key).toBe('myKey');
        expect(tomlArg.databases[0].encryption_key).toBe('encKey');
        expect(tomlArg.databases[0].geocoding_key).toBe('geoKey');
        expect(tomlArg.databases[0].s3Key).toBeUndefined();
    });

    test('coerces missing arrays before writing', async () => {
        const config = {} as any;

        await saveDatabasesConfig(config);

        expect(config.databases).toEqual([]);
        expect(config.recentDatabaseNames).toEqual([]);
    });
});

describe('getDatabases', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns the databases array from config', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        const entries = [makeTomlEntry('/a'), makeTomlEntry('/b')];
        mockReadToml.mockResolvedValue({ databases: entries, recent_database_names: [] });

        const result = await getDatabases();

        expect(result).toHaveLength(2);
        expect(result[0].path).toBe('/a');
        expect(result[1].path).toBe('/b');
    });
});

describe('findDatabase', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns undefined when no entry matches', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [makeTomlEntry('/a', 'alpha')], recent_database_names: [] });

        const result = await findDatabase('beta');

        expect(result).toBeUndefined();
    });

    test('returns entry on case-insensitive match', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [makeTomlEntry('/a', 'Alpha')], recent_database_names: [] });

        const result = await findDatabase('ALPHA');

        expect(result).toBeDefined();
        expect(result!.name).toBe('Alpha');
    });
});

describe('addDatabaseEntry', () => {
    beforeEach(() => jest.clearAllMocks());

    test('appends entry and saves', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [makeTomlEntry('/a', 'alpha')], recent_database_names: [] });

        await addDatabaseEntry(makeEntry('/b', 'beta'));

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.databases).toHaveLength(2);
        expect(tomlArg.databases[1].path).toBe('/b');
    });

    test('throws on case-insensitive name collision', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [makeTomlEntry('/a', 'Alpha')], recent_database_names: [] });

        await expect(addDatabaseEntry(makeEntry('/b', 'ALPHA'))).rejects.toThrow();
        expect(mockWriteToml).not.toHaveBeenCalled();
    });
});

describe('updateDatabaseEntry', () => {
    beforeEach(() => jest.clearAllMocks());

    test('replaces matched entry by originalName and saves', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [{ name: 'alpha', description: '', path: '/a' }], recent_database_names: [] });

        await updateDatabaseEntry('alpha', { name: 'alpha', description: 'changed', path: '/a' });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.databases[0].description).toBe('changed');
    });

    test('rewrites the matching recent slot when renaming', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [{ name: 'alpha', description: '', path: '/a' }, { name: 'beta', description: '', path: '/b' }],
            recent_database_names: ['beta', 'alpha'],
        });

        await updateDatabaseEntry('alpha', { name: 'gamma', description: '', path: '/a' });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.databases[0].name).toBe('gamma');
        expect(tomlArg.recent_database_names).toEqual(['beta', 'gamma']);
    });

    test('throws when rename collides with another entry', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [{ name: 'alpha', description: '', path: '/a' }, { name: 'beta', description: '', path: '/b' }],
            recent_database_names: [],
        });

        await expect(updateDatabaseEntry('alpha', { name: 'BETA', description: '', path: '/a' })).rejects.toThrow();
        expect(mockWriteToml).not.toHaveBeenCalled();
    });

    test('throws when no entry matches originalName', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [], recent_database_names: [] });

        await expect(updateDatabaseEntry('missing', { name: 'missing', description: '', path: '/x' })).rejects.toThrow();
    });
});

describe('removeDatabaseEntry', () => {
    beforeEach(() => jest.clearAllMocks());

    test('removes only the first matching entry by name and saves', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'dup'), makeTomlEntry('/b', 'dup'), makeTomlEntry('/c', 'unique')],
            recent_database_names: [],
        });

        await removeDatabaseEntry('dup');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.databases).toHaveLength(2);
        expect(tomlArg.databases[0].path).toBe('/b');
        expect(tomlArg.databases[1].path).toBe('/c');
    });

    test('also removes the name from recents', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha'), makeTomlEntry('/b', 'beta')],
            recent_database_names: ['alpha', 'beta'],
        });

        await removeDatabaseEntry('alpha');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_database_names).toEqual(['beta']);
    });

    test('idempotent when name not found and recents already clean', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: ['alpha'],
        });

        await removeDatabaseEntry('missing');

        expect(mockWriteToml).not.toHaveBeenCalled();
    });
});

describe('getRecentDatabases', () => {
    beforeEach(() => jest.clearAllMocks());

    test('resolves names to full entries', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha'), makeTomlEntry('/b', 'beta')],
            recent_database_names: ['beta', 'alpha'],
        });

        const result = await getRecentDatabases();

        expect(result).toHaveLength(2);
        expect(result[0].path).toBe('/b');
        expect(result[1].path).toBe('/a');
    });

    test('skips unknown names', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: ['unknown', 'alpha'],
        });

        const result = await getRecentDatabases();

        expect(result).toHaveLength(1);
        expect(result[0].path).toBe('/a');
    });
});

describe('markDatabaseOpened', () => {
    beforeEach(() => jest.clearAllMocks());

    test('moves name to front of recent list', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha'), makeTomlEntry('/b', 'beta')],
            recent_database_names: ['beta'],
        });

        await markDatabaseOpened('alpha');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_database_names[0]).toBe('alpha');
        expect(tomlArg.recent_database_names[1]).toBe('beta');
    });

    test('caps recent list at 5 entries', async () => {
        const names = ['alpha', 'beta', 'gamma', 'delta', 'epsilon', 'zeta'];
        const entries = names.map((entryName, idx) => makeTomlEntry(`/p${idx}`, entryName));
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: entries,
            recent_database_names: ['beta', 'gamma', 'delta', 'epsilon', 'zeta'],
        });

        await markDatabaseOpened('alpha');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_database_names).toHaveLength(5);
        expect(tomlArg.recent_database_names[0]).toBe('alpha');
    });

    test('skips unknown names without saving', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [], recent_database_names: [] });

        await markDatabaseOpened('unknown');

        expect(mockWriteToml).not.toHaveBeenCalled();
    });
});

describe('removeRecentDatabaseName', () => {
    beforeEach(() => jest.clearAllMocks());

    test('removes a name that exists in recent_database_names', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha'), makeTomlEntry('/b', 'beta')],
            recent_database_names: ['alpha', 'beta'],
        });

        await removeRecentDatabaseName('alpha');

        expect(mockWriteToml).toHaveBeenCalledTimes(1);
        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_database_names).toEqual(['beta']);
        expect(tomlArg.databases).toHaveLength(2);
    });

    test('no-op when the name is not in the recent list', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: [],
        });

        await removeRecentDatabaseName('alpha');

        expect(mockWriteToml).not.toHaveBeenCalled();
    });

    test('leaves the entry in databases untouched', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: ['alpha'],
        });

        await removeRecentDatabaseName('alpha');

        expect(mockWriteToml).toHaveBeenCalledTimes(1);
        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.databases).toHaveLength(1);
        expect(tomlArg.databases[0].path).toBe('/a');
    });
});
