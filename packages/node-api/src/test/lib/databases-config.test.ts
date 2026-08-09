// Mock node-utils fs helpers so tests do not touch the real filesystem.
//
// Every edit goes through updateToml, which hands the mutator the file's CURRENT contents and writes
// what it returns. The mock does the same, using whatever readToml was told the file holds, so a
// test asserts on what would actually land on disk rather than on what a caller intended. The result
// is left in writtenToml, and setFileContents below sets what the file is pretending to hold.
const mockPathExists = jest.fn();
const mockReadToml = jest.fn();
let fileContents: any;
let writtenToml: any;

const mockUpdateToml = jest.fn(async (_filePath: string, fallback: any, mutator: (current: any) => any) => {
    writtenToml = mutator(fileContents === undefined ? fallback : fileContents);
    fileContents = writtenToml;
});

jest.mock('node-utils', () => ({
    pathExists: mockPathExists,
    readToml: mockReadToml,
    updateToml: mockUpdateToml,
}));

import {
    loadDatabasesConfig,
    updateDatabasesConfig,
    tomlToDatabasesConfig,
    databasesConfigToToml,
    namesMatch,
    getDatabases,
    addDatabaseEntry,
    updateDatabaseEntry,
    removeDatabaseEntry,
    getRecentDatabases,
    markDatabaseOpened,
    removeRecentDatabaseName,
    findDatabase,
    MAX_RECENT_DATABASES,
} from '../../lib/databases-config';
import type { IDatabaseEntry } from '../../lib/databases-config';

//
// Sets what the config file is pretending to hold, for both the read path and the mutator the write
// path is handed.
//
function setFileContents(toml: any): void {
    fileContents = toml;
    mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
    mockReadToml.mockResolvedValue(toml);
}

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
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('returns default config when no file exists', async () => {
        mockPathExists.mockResolvedValue(false);

        const config = await loadDatabasesConfig();

        expect(config.databases).toEqual([]);
        expect(config.recentDatabaseNames).toEqual([]);
        expect(mockReadToml).not.toHaveBeenCalled();
    });

    test('returns config from TOML when file exists', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: ['alpha'],
        });

        const config = await loadDatabasesConfig();

        expect(config.databases).toHaveLength(1);
        expect(config.databases[0].path).toBe('/a');
        expect(config.recentDatabaseNames).toEqual(['alpha']);
    });

    test('coerces missing databases to []', async () => {
        setFileContents({ recent_database_names: ['alpha'] });

        const config = await loadDatabasesConfig();

        expect(config.databases).toEqual([]);
    });

    test('coerces missing recent_database_names to []', async () => {
        setFileContents({ databases: [makeTomlEntry('/a')] });

        const config = await loadDatabasesConfig();

        expect(config.recentDatabaseNames).toEqual([]);
    });

    test('converts snake_case TOML fields to camelCase TypeScript fields', async () => {
        setFileContents({
            databases: [{ name: 'test', description: '', path: '/a', s3_key: 'myKey', encryption_key: 'encKey', geocoding_key: 'geoKey' }],
            recent_database_names: [],
        });

        const config = await loadDatabasesConfig();

        expect(config.databases[0].s3Key).toBe('myKey');
        expect(config.databases[0].encryptionKey).toBe('encKey');
        expect(config.databases[0].geocodingKey).toBe('geoKey');
    });
});

//
// Loading is a read and nothing else. It used to migrate a legacy `recent_database_paths` field and
// rewrite the file, which meant a read could take a lock and write; that is gone, so a file holding
// anything this code does not recognise is simply read past.
//
describe('loadDatabasesConfig ignores keys it does not know', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('reads the file without writing to it', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: ['alpha'],
        });

        const config = await loadDatabasesConfig();

        expect(config.recentDatabaseNames).toEqual(['alpha']);
        expect(mockUpdateToml).not.toHaveBeenCalled();
    });

    test('an unrecognised key leaves the recents empty and still writes nothing', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_paths: ['/a'],
        });

        const config = await loadDatabasesConfig();

        expect(config.databases).toHaveLength(1);
        expect(config.recentDatabaseNames).toEqual([]);
        expect(mockUpdateToml).not.toHaveBeenCalled();
    });
});

//
// The pure conversions between the on-disk TOML and the in-memory config.
//
describe('tomlToDatabasesConfig', () => {
    test('converts snake_case fields to camelCase', () => {
        const config = tomlToDatabasesConfig({
            databases: [{ name: 'test', description: '', path: '/a', s3_key: 'myKey', encryption_key: 'encKey', geocoding_key: 'geoKey' }],
            recent_database_names: ['test'],
        });

        expect(config.databases[0].s3Key).toBe('myKey');
        expect(config.databases[0].encryptionKey).toBe('encKey');
        expect(config.databases[0].geocodingKey).toBe('geoKey');
        expect(config.recentDatabaseNames).toEqual(['test']);
    });

    test('coerces missing lists to empty ones', () => {
        const config = tomlToDatabasesConfig({});

        expect(config.databases).toEqual([]);
        expect(config.recentDatabaseNames).toEqual([]);
    });

    test('coerces lists that are not arrays to empty ones', () => {
        // A hand-edited file can hold anything. `[recent_database_names]` written as a TOML table
        // parses to an object, which must not become the recents list.
        const config = tomlToDatabasesConfig({ databases: {} as any, recent_database_names: {} as any });

        expect(config.databases).toEqual([]);
        expect(config.recentDatabaseNames).toEqual([]);
    });
});

describe('databasesConfigToToml', () => {
    test('converts camelCase fields to snake_case', () => {
        const entry: IDatabaseEntry = { name: 'test', description: '', path: '/a', s3Key: 'myKey', encryptionKey: 'encKey', geocodingKey: 'geoKey' };

        const toml = databasesConfigToToml({ databases: [entry], recentDatabaseNames: ['test'] });

        expect(toml.databases![0].s3_key).toBe('myKey');
        expect(toml.databases![0].encryption_key).toBe('encKey');
        expect(toml.databases![0].geocoding_key).toBe('geoKey');
        expect((toml.databases![0] as any).s3Key).toBeUndefined();
        expect(toml.recent_database_names).toEqual(['test']);
    });

    test('round trips a config through TOML and back unchanged', () => {
        const original = {
            databases: [makeEntry('/a', 'alpha'), makeEntry('/b', 'beta')],
            recentDatabaseNames: ['beta'],
        };

        expect(tomlToDatabasesConfig(databasesConfigToToml(original))).toEqual(original);
    });
});

describe('namesMatch', () => {
    test('matches regardless of case', () => {
        expect(namesMatch('Alpha', 'alpha')).toBe(true);
        expect(namesMatch('ALPHA', 'alpha')).toBe(true);
    });

    test('does not match different names', () => {
        expect(namesMatch('alpha', 'beta')).toBe(false);
        expect(namesMatch('alpha', 'alpha2')).toBe(false);
    });
});

//
// The one place every edit goes through. What matters is that the mutator is handed the file's
// current contents, so an edit made by someone else in the meantime is still there afterwards. The
// whole-config save this replaced could not do that: its callers read, changed and wrote back a
// snapshot, so the later of two overlapping edits discarded the earlier one.
//
describe('updateDatabasesConfig', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('hands the mutator the current contents of the file', async () => {
        setFileContents({ databases: [makeTomlEntry('/a', 'alpha')], recent_database_names: ['alpha'] });
        let seen: any;

        await updateDatabasesConfig(config => {
            seen = config;
            return config;
        });

        expect(seen.databases[0].name).toBe('alpha');
        expect(seen.recentDatabaseNames).toEqual(['alpha']);
    });

    test('hands the mutator an empty config when the file does not exist', async () => {
        fileContents = undefined;
        let seen: any;

        await updateDatabasesConfig(config => {
            seen = config;
            return config;
        });

        expect(seen).toEqual({ databases: [], recentDatabaseNames: [] });
    });

    test('writes what the mutator returns, converted to TOML', async () => {
        setFileContents({ databases: [], recent_database_names: [] });

        await updateDatabasesConfig(() => ({
            databases: [makeEntry('/a', 'alpha')],
            recentDatabaseNames: ['alpha'],
        }));

        expect(writtenToml.databases[0].path).toBe('/a');
        expect(writtenToml.recent_database_names).toEqual(['alpha']);
    });

    test('lets a throwing mutator through, writing nothing', async () => {
        setFileContents({ databases: [], recent_database_names: [] });

        await expect(updateDatabasesConfig(() => {
            throw new Error('no');
        })).rejects.toThrow('no');

        expect(writtenToml).toBeUndefined();
    });
});

describe('getDatabases', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('returns the databases array from config', async () => {
        const entries = [makeTomlEntry('/a'), makeTomlEntry('/b')];
        setFileContents({ databases: entries, recent_database_names: [] });

        const result = await getDatabases();

        expect(result).toHaveLength(2);
        expect(result[0].path).toBe('/a');
        expect(result[1].path).toBe('/b');
    });
});

describe('findDatabase', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('returns undefined when no entry matches', async () => {
        setFileContents({ databases: [makeTomlEntry('/a', 'alpha')], recent_database_names: [] });

        const result = await findDatabase('beta');

        expect(result).toBeUndefined();
    });

    test('returns entry on case-insensitive match', async () => {
        setFileContents({ databases: [makeTomlEntry('/a', 'Alpha')], recent_database_names: [] });

        const result = await findDatabase('ALPHA');

        expect(result).toBeDefined();
        expect(result!.name).toBe('Alpha');
    });
});

describe('addDatabaseEntry', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('appends entry and saves', async () => {
        setFileContents({ databases: [makeTomlEntry('/a', 'alpha')], recent_database_names: [] });

        await addDatabaseEntry(makeEntry('/b', 'beta'));

        const tomlArg = writtenToml;
        expect(tomlArg.databases).toHaveLength(2);
        expect(tomlArg.databases[1].path).toBe('/b');
    });

    test('throws on case-insensitive name collision', async () => {
        setFileContents({ databases: [makeTomlEntry('/a', 'Alpha')], recent_database_names: [] });

        await expect(addDatabaseEntry(makeEntry('/b', 'ALPHA'))).rejects.toThrow();
        // The mutator throws inside the lock, so nothing is written.
        expect(writtenToml).toBeUndefined();
    });
});

describe('updateDatabaseEntry', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('replaces matched entry by originalName and saves', async () => {
        setFileContents({ databases: [{ name: 'alpha', description: '', path: '/a' }], recent_database_names: [] });

        await updateDatabaseEntry('alpha', { name: 'alpha', description: 'changed', path: '/a' });

        const tomlArg = writtenToml;
        expect(tomlArg.databases[0].description).toBe('changed');
    });

    test('rewrites the matching recent slot when renaming', async () => {
        setFileContents({
            databases: [{ name: 'alpha', description: '', path: '/a' }, { name: 'beta', description: '', path: '/b' }],
            recent_database_names: ['beta', 'alpha'],
        });

        await updateDatabaseEntry('alpha', { name: 'gamma', description: '', path: '/a' });

        const tomlArg = writtenToml;
        expect(tomlArg.databases[0].name).toBe('gamma');
        expect(tomlArg.recent_database_names).toEqual(['beta', 'gamma']);
    });

    test('throws when rename collides with another entry', async () => {
        setFileContents({
            databases: [{ name: 'alpha', description: '', path: '/a' }, { name: 'beta', description: '', path: '/b' }],
            recent_database_names: [],
        });

        await expect(updateDatabaseEntry('alpha', { name: 'BETA', description: '', path: '/a' })).rejects.toThrow();
        // The mutator throws inside the lock, so nothing is written.
        expect(writtenToml).toBeUndefined();
    });

    test('throws when no entry matches originalName', async () => {
        setFileContents({ databases: [], recent_database_names: [] });

        await expect(updateDatabaseEntry('missing', { name: 'missing', description: '', path: '/x' })).rejects.toThrow();
    });
});

describe('removeDatabaseEntry', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('removes only the first matching entry by name and saves', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'dup'), makeTomlEntry('/b', 'dup'), makeTomlEntry('/c', 'unique')],
            recent_database_names: [],
        });

        await removeDatabaseEntry('dup');

        const tomlArg = writtenToml;
        expect(tomlArg.databases).toHaveLength(2);
        expect(tomlArg.databases[0].path).toBe('/b');
        expect(tomlArg.databases[1].path).toBe('/c');
    });

    test('also removes the name from recents', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha'), makeTomlEntry('/b', 'beta')],
            recent_database_names: ['alpha', 'beta'],
        });

        await removeDatabaseEntry('alpha');

        const tomlArg = writtenToml;
        expect(tomlArg.recent_database_names).toEqual(['beta']);
    });

    test('idempotent when name not found and recents already clean', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: ['alpha'],
        });

        await removeDatabaseEntry('missing');

        // Nothing to remove, so the contents come back unchanged.
        expect(writtenToml.databases).toHaveLength(1);
        expect(writtenToml.recent_database_names).toEqual(['alpha']);
    });
});

describe('getRecentDatabases', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('resolves names to full entries', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha'), makeTomlEntry('/b', 'beta')],
            recent_database_names: ['beta', 'alpha'],
        });

        const result = await getRecentDatabases();

        expect(result).toHaveLength(2);
        expect(result[0].path).toBe('/b');
        expect(result[1].path).toBe('/a');
    });

    test('skips unknown names', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: ['unknown', 'alpha'],
        });

        const result = await getRecentDatabases();

        expect(result).toHaveLength(1);
        expect(result[0].path).toBe('/a');
    });
});

describe('markDatabaseOpened', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('moves name to front of recent list', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha'), makeTomlEntry('/b', 'beta')],
            recent_database_names: ['beta'],
        });

        await markDatabaseOpened('alpha');

        const tomlArg = writtenToml;
        expect(tomlArg.recent_database_names[0]).toBe('alpha');
        expect(tomlArg.recent_database_names[1]).toBe('beta');
    });

    test('caps the recent list at MAX_RECENT_DATABASES entries', async () => {
        // One more than the cap, so opening another has to push one off the end.
        const alreadyRecent = Array.from({ length: MAX_RECENT_DATABASES }, (_unused, index) => `recent${index}`);
        const names = ['alpha', ...alreadyRecent];
        const entries = names.map((entryName, index) => makeTomlEntry(`/p${index}`, entryName));
        setFileContents({ databases: entries, recent_database_names: alreadyRecent });

        await markDatabaseOpened('alpha');

        expect(writtenToml.recent_database_names).toHaveLength(MAX_RECENT_DATABASES);
        expect(writtenToml.recent_database_names[0]).toBe('alpha');
        // The oldest one fell off rather than the list simply growing.
        expect(writtenToml.recent_database_names).not.toContain(alreadyRecent[MAX_RECENT_DATABASES - 1]);
    });

    test('skips unknown names without saving', async () => {
        setFileContents({ databases: [], recent_database_names: [] });

        await markDatabaseOpened('unknown');

        // No such database, so the recents are left exactly as they were.
        expect(writtenToml.recent_database_names).toEqual([]);
    });
});

describe('removeRecentDatabaseName', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        fileContents = undefined;
        writtenToml = undefined;
    });

    test('removes a name that exists in recent_database_names', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha'), makeTomlEntry('/b', 'beta')],
            recent_database_names: ['alpha', 'beta'],
        });

        await removeRecentDatabaseName('alpha');

        expect(mockUpdateToml).toHaveBeenCalledTimes(1);
        const tomlArg = writtenToml;
        expect(tomlArg.recent_database_names).toEqual(['beta']);
        expect(tomlArg.databases).toHaveLength(2);
    });

    test('no-op when the name is not in the recent list', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: [],
        });

        await removeRecentDatabaseName('alpha');

        // Not in the recents, so they are left exactly as they were.
        expect(writtenToml.recent_database_names).toEqual([]);
        expect(writtenToml.databases).toHaveLength(1);
    });

    test('leaves the entry in databases untouched', async () => {
        setFileContents({
            databases: [makeTomlEntry('/a', 'alpha')],
            recent_database_names: ['alpha'],
        });

        await removeRecentDatabaseName('alpha');

        expect(mockUpdateToml).toHaveBeenCalledTimes(1);
        const tomlArg = writtenToml;
        expect(tomlArg.databases).toHaveLength(1);
        expect(tomlArg.databases[0].path).toBe('/a');
    });
});
