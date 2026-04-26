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
    markDatabaseOpenedByPath,
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
        expect(config.recentDatabasePaths).toEqual([]);
        expect(mockReadToml).not.toHaveBeenCalled();
    });

    test('returns config from TOML when file exists', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a')],
            recent_database_paths: ['/a'],
        });

        const config = await loadDatabasesConfig();

        expect(config.databases).toHaveLength(1);
        expect(config.databases[0].path).toBe('/a');
        expect(config.recentDatabasePaths).toEqual(['/a']);
    });

    test('coerces missing databases to []', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ recent_database_paths: ['/a'] });

        const config = await loadDatabasesConfig();

        expect(config.databases).toEqual([]);
    });

    test('coerces missing recent_database_paths to []', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [makeTomlEntry('/a')] });

        const config = await loadDatabasesConfig();

        expect(config.recentDatabasePaths).toEqual([]);
    });

    test('converts snake_case TOML fields to camelCase TypeScript fields', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [{ name: 'test', description: '', path: '/a', s3_key: 'myKey', encryption_key: 'encKey', geocoding_key: 'geoKey' }],
            recent_database_paths: [],
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
            databases: [makeEntry('/a')],
            recentDatabasePaths: ['/a'],
        });

        const config = await loadDatabasesConfig();

        expect(config.databases).toHaveLength(1);
        expect(config.databases[0].path).toBe('/a');
        expect(config.recentDatabasePaths).toEqual(['/a']);
        expect(mockWriteToml).toHaveBeenCalled();
        expect(mockRemove).toHaveBeenCalledWith(expect.stringContaining('databases.json'));
    });

    test('coerces missing arrays when migrating from JSON', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.json'));
        mockReadJson.mockResolvedValue({});

        const config = await loadDatabasesConfig();

        expect(config.databases).toEqual([]);
        expect(config.recentDatabasePaths).toEqual([]);
    });
});

describe('saveDatabasesConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes TOML with snake_case keys', async () => {
        const config = { databases: [makeEntry('/a')], recentDatabasePaths: [] };

        await saveDatabasesConfig(config);

        expect(mockWriteToml).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ recent_database_paths: [] })
        );
    });

    test('converts camelCase entry fields to snake_case in TOML', async () => {
        const entry: IDatabaseEntry = { name: 'test', description: '', path: '/a', s3Key: 'myKey', encryptionKey: 'encKey', geocodingKey: 'geoKey' };
        const config = { databases: [entry], recentDatabasePaths: [] };

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
        expect(config.recentDatabasePaths).toEqual([]);
    });
});

describe('getDatabases', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns the databases array from config', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        const entries = [makeTomlEntry('/a'), makeTomlEntry('/b')];
        mockReadToml.mockResolvedValue({ databases: entries, recent_database_paths: [] });

        const result = await getDatabases();

        expect(result).toHaveLength(2);
        expect(result[0].path).toBe('/a');
        expect(result[1].path).toBe('/b');
    });
});

describe('addDatabaseEntry', () => {
    beforeEach(() => jest.clearAllMocks());

    test('appends entry and saves', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [makeTomlEntry('/a')], recent_database_paths: [] });

        await addDatabaseEntry(makeEntry('/b'));

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.databases).toHaveLength(2);
        expect(tomlArg.databases[1].path).toBe('/b');
    });
});

describe('updateDatabaseEntry', () => {
    beforeEach(() => jest.clearAllMocks());

    test('replaces matched entry by path and saves', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [{ name: 'old', description: '', path: '/a' }], recent_database_paths: [] });

        await updateDatabaseEntry({ name: 'new', description: '', path: '/a' });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.databases[0].name).toBe('new');
    });
});

describe('removeDatabaseEntry', () => {
    beforeEach(() => jest.clearAllMocks());

    test('filters out entry by path and saves', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a'), makeTomlEntry('/b')],
            recent_database_paths: [],
        });

        await removeDatabaseEntry('/a');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.databases).toHaveLength(1);
        expect(tomlArg.databases[0].path).toBe('/b');
    });
});

describe('getRecentDatabases', () => {
    beforeEach(() => jest.clearAllMocks());

    test('resolves paths to full entries', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a'), makeTomlEntry('/b')],
            recent_database_paths: ['/b', '/a'],
        });

        const result = await getRecentDatabases();

        expect(result).toHaveLength(2);
        expect(result[0].path).toBe('/b');
        expect(result[1].path).toBe('/a');
    });

    test('skips unknown paths', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a')],
            recent_database_paths: ['/unknown', '/a'],
        });

        const result = await getRecentDatabases();

        expect(result).toHaveLength(1);
        expect(result[0].path).toBe('/a');
    });
});

describe('markDatabaseOpenedByPath', () => {
    beforeEach(() => jest.clearAllMocks());

    test('moves path to front of recent list', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: [makeTomlEntry('/a'), makeTomlEntry('/b')],
            recent_database_paths: ['/b'],
        });

        await markDatabaseOpenedByPath('/a');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_database_paths[0]).toBe('/a');
        expect(tomlArg.recent_database_paths[1]).toBe('/b');
    });

    test('caps recent list at 5 entries', async () => {
        const entries = ['/a', '/b', '/c', '/d', '/e', '/f'].map(dbPath => makeTomlEntry(dbPath));
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            databases: entries,
            recent_database_paths: ['/b', '/c', '/d', '/e', '/f'],
        });

        await markDatabaseOpenedByPath('/a');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_database_paths).toHaveLength(5);
        expect(tomlArg.recent_database_paths[0]).toBe('/a');
    });

    test('skips unknown paths without saving', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ databases: [], recent_database_paths: [] });

        await markDatabaseOpenedByPath('/unknown');

        expect(mockWriteToml).not.toHaveBeenCalled();
    });
});
