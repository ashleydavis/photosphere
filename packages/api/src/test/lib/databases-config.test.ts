// Mock node-utils fs helpers so tests don't touch the real filesystem.
const mockPathExists = jest.fn();
const mockReadJson = jest.fn();
const mockWriteJson = jest.fn();

jest.mock('node-utils', () => ({
    pathExists: mockPathExists,
    readJson: mockReadJson,
    writeJson: mockWriteJson,
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

describe('loadDatabasesConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns default config when file does not exist', async () => {
        mockPathExists.mockResolvedValue(false);

        const config = await loadDatabasesConfig();

        expect(config.databases).toEqual([]);
        expect(config.recentDatabasePaths).toEqual([]);
        expect(mockReadJson).not.toHaveBeenCalled();
    });

    test('returns config from disk when file exists', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({
            databases: [makeEntry('/a')],
            recentDatabasePaths: ['/a'],
        });

        const config = await loadDatabasesConfig();

        expect(config.databases).toHaveLength(1);
        expect(config.recentDatabasePaths).toEqual(['/a']);
    });

    test('coerces missing databases to []', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ recentDatabasePaths: ['/a'] });

        const config = await loadDatabasesConfig();

        expect(config.databases).toEqual([]);
    });

    test('coerces missing recentDatabasePaths to []', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ databases: [makeEntry('/a')] });

        const config = await loadDatabasesConfig();

        expect(config.recentDatabasePaths).toEqual([]);
    });
});

describe('saveDatabasesConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes JSON with 2-space indent', async () => {
        const config = { databases: [makeEntry('/a')], recentDatabasePaths: [] };

        await saveDatabasesConfig(config);

        expect(mockWriteJson).toHaveBeenCalledWith(
            expect.any(String),
            config,
            { spaces: 2 }
        );
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
        mockPathExists.mockResolvedValue(true);
        const entries = [makeEntry('/a'), makeEntry('/b')];
        mockReadJson.mockResolvedValue({ databases: entries, recentDatabasePaths: [] });

        const result = await getDatabases();

        expect(result).toEqual(entries);
    });
});

describe('addDatabaseEntry', () => {
    beforeEach(() => jest.clearAllMocks());

    test('appends entry and saves', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ databases: [makeEntry('/a')], recentDatabasePaths: [] });

        await addDatabaseEntry(makeEntry('/b'));

        expect(mockWriteJson).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ databases: [makeEntry('/a'), makeEntry('/b')] }),
            { spaces: 2 }
        );
    });
});

describe('updateDatabaseEntry', () => {
    beforeEach(() => jest.clearAllMocks());

    test('replaces matched entry by path and saves', async () => {
        const original = { ...makeEntry('/a'), name: 'old' };
        const updated = { ...makeEntry('/a'), name: 'new' };
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ databases: [original], recentDatabasePaths: [] });

        await updateDatabaseEntry(updated);

        expect(mockWriteJson).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ databases: [updated] }),
            { spaces: 2 }
        );
    });
});

describe('removeDatabaseEntry', () => {
    beforeEach(() => jest.clearAllMocks());

    test('filters out entry by path and saves', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({
            databases: [makeEntry('/a'), makeEntry('/b')],
            recentDatabasePaths: [],
        });

        await removeDatabaseEntry('/a');

        expect(mockWriteJson).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ databases: [makeEntry('/b')] }),
            { spaces: 2 }
        );
    });
});

describe('getRecentDatabases', () => {
    beforeEach(() => jest.clearAllMocks());

    test('resolves paths to full entries', async () => {
        const entryA = makeEntry('/a');
        const entryB = makeEntry('/b');
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({
            databases: [entryA, entryB],
            recentDatabasePaths: ['/b', '/a'],
        });

        const result = await getRecentDatabases();

        expect(result).toEqual([entryB, entryA]);
    });

    test('skips unknown paths', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({
            databases: [makeEntry('/a')],
            recentDatabasePaths: ['/unknown', '/a'],
        });

        const result = await getRecentDatabases();

        expect(result).toHaveLength(1);
        expect(result[0].path).toBe('/a');
    });
});

describe('markDatabaseOpenedByPath', () => {
    beforeEach(() => jest.clearAllMocks());

    test('moves path to front of recent list', async () => {
        const entryA = makeEntry('/a');
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({
            databases: [entryA, makeEntry('/b')],
            recentDatabasePaths: ['/b'],
        });

        await markDatabaseOpenedByPath('/a');

        expect(mockWriteJson).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ recentDatabasePaths: ['/a', '/b'] }),
            { spaces: 2 }
        );
    });

    test('caps recent list at 5 entries', async () => {
        const entries = ['/a', '/b', '/c', '/d', '/e', '/f'].map(dbPath => makeEntry(dbPath));
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({
            databases: entries,
            recentDatabasePaths: ['/b', '/c', '/d', '/e', '/f'],
        });

        await markDatabaseOpenedByPath('/a');

        const written = mockWriteJson.mock.calls[0][1];
        expect(written.recentDatabasePaths).toHaveLength(5);
        expect(written.recentDatabasePaths[0]).toBe('/a');
    });

    test('skips unknown paths without saving', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ databases: [], recentDatabasePaths: [] });

        await markDatabaseOpenedByPath('/unknown');

        expect(mockWriteJson).not.toHaveBeenCalled();
    });
});
