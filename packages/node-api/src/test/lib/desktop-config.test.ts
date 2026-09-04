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
    // Where desktop.toml sits. Named here so the module under test resolves a path at import time
    // without reaching for a real home directory.
    getConfigDir: () => '/test-config',
    // Mirror the real updateToml as a read-modify-write over the mocked fs helpers, so the
    // config mutators (which now go through updateDesktopConfig -> updateToml) still exercise
    // the mocked readToml/writeToml the existing assertions rely on.
    updateToml: async (filePath: string, fallback: any, mutator: (current: any) => any) => {
        const current = await mockPathExists(filePath) ? await mockReadToml(filePath) : fallback;
        const updated = mutator(current);
        await mockWriteToml(filePath, updated);
    },
}));

import {
    getConfigPath,
    loadDesktopConfig,
    updateLastFolder,
    getTheme,
    setTheme,
    updateLastDownloadFolder,
    getRecentSearches,
    addRecentSearch,
    removeRecentSearch,
    updateDesktopConfig,
    tomlToDesktopConfig,
    desktopConfigToToml,
    asFolderConfigKey,
    getFolderPath,
    updateFolderPath,
    FOLDER_CONFIG_KEYS,
    MAX_RECENT_SEARCHES,
} from '../../lib/desktop-config';

describe('getConfigPath', () => {
    test('returns a string ending with desktop.toml', () => {
        const result = getConfigPath();

        expect(typeof result).toBe('string');
        expect(result).toMatch(/desktop\.toml$/);
    });
});

describe('loadDesktopConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns {} when no file exists', async () => {
        mockPathExists.mockResolvedValue(false);

        const config = await loadDesktopConfig();

        expect(config).toEqual({});
        expect(mockReadToml).not.toHaveBeenCalled();
    });

    test('returns config from TOML when file exists', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ theme: 'dark', last_folder: '/photos' });

        const config = await loadDesktopConfig();

        expect(config.theme).toBe('dark');
        expect(config.lastFolder).toBe('/photos');
    });

    test('converts snake_case TOML keys to camelCase TypeScript fields', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({
            last_folder: '/folder',
            recent_searches: ['cats'],
            last_download_folder: '/downloads',
            last_database: '/db',
            show_fps_indicator: true,
        });

        const config = await loadDesktopConfig();

        expect(config.lastFolder).toBe('/folder');
        expect(config.recentSearches).toEqual(['cats']);
        expect(config.lastDownloadFolder).toBe('/downloads');
        expect(config.lastDatabase).toBe('/db');
        expect(config.showFpsIndicator).toBe(true);
    });
});

//
// Loading is a read and nothing else. It used to migrate an old desktop.json, write the TOML and
// delete the JSON, so a read could take a lock, write a file and remove another. That is gone.
//
describe('loadDesktopConfig does not write', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns defaults and writes nothing when the file is absent', async () => {
        mockPathExists.mockResolvedValue(false);

        const config = await loadDesktopConfig();

        expect(config).toEqual({});
        expect(mockWriteToml).not.toHaveBeenCalled();
        expect(mockRemove).not.toHaveBeenCalled();
    });
});

describe('updateDesktopConfig writes snake_case TOML', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes TOML with snake_case keys', async () => {
        await updateDesktopConfig(config => { config.theme = 'light'; });

        expect(mockWriteToml).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ theme: 'light' })
        );
    });

    test('converts camelCase fields to snake_case in TOML', async () => {
        await updateDesktopConfig(config => {
            config.lastFolder = '/folder';
            config.recentSearches = ['cats'];
            config.lastDownloadFolder = '/downloads';
            config.lastDatabase = '/db';
            config.showFpsIndicator = true;
        });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.last_folder).toBe('/folder');
        expect(tomlArg.recent_searches).toEqual(['cats']);
        expect(tomlArg.last_download_folder).toBe('/downloads');
        expect(tomlArg.last_database).toBe('/db');
        expect(tomlArg.show_fps_indicator).toBe(true);
        expect(tomlArg.lastFolder).toBeUndefined();
    });
});

describe('the automatic import settings', () => {
    beforeEach(() => jest.clearAllMocks());

    test('are written with snake_case keys', async () => {
        await updateDesktopConfig(config => {
            config.autoImportEnabled = true;
            config.defaultDatabasePath = '/home/someone/photosphere-default';
            config.autoImportSources = [{ type: 'folder', path: '/home/someone/Pictures', recurse: true }];
            config.autoImportCleanupEnabled = true;
        });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.auto_import_enabled).toBe(true);
        expect(tomlArg.default_database_path).toBe('/home/someone/photosphere-default');
        expect(tomlArg.auto_import_sources).toEqual([{ type: 'folder', path: '/home/someone/Pictures', recurse: true }]);
        expect(tomlArg.auto_import_cleanup_enabled).toBe(true);
        expect(tomlArg.autoImportEnabled).toBeUndefined();
    });

    test('round-trip through the TOML shape', () => {
        const config = {
            autoImportEnabled: true,
            defaultDatabasePath: '/photos',
            autoImportSources: [{ type: 'folder' as const, path: '/photos', recurse: false }],
            autoImportCleanupEnabled: false,
        };

        expect(tomlToDesktopConfig(desktopConfigToToml(config))).toEqual(config);
    });

    test('are absent from a config that does not mention them', () => {
        const config = tomlToDesktopConfig({ theme: 'dark' });

        expect(config.autoImportEnabled).toBeUndefined();
        expect(config.defaultDatabasePath).toBeUndefined();
        expect(config.autoImportSources).toBeUndefined();
        expect(config.autoImportCleanupEnabled).toBeUndefined();
    });
});

describe('updateLastFolder', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets lastFolder and saves', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({});

        await updateLastFolder('/new/folder');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.last_folder).toBe('/new/folder');
    });
});

describe('getTheme', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns system when theme is unset', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({});

        const result = await getTheme();

        expect(result).toBe('system');
    });

    test('returns stored value', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ theme: 'dark' });

        const result = await getTheme();

        expect(result).toBe('dark');
    });
});

describe('setTheme', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets theme and saves', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({});

        await setTheme('light');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.theme).toBe('light');
    });
});

describe('showFpsIndicator config round-trip', () => {
    beforeEach(() => jest.clearAllMocks());

    test('loadDesktopConfig reads show_fps_indicator from toml', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ show_fps_indicator: true });

        const config = await loadDesktopConfig();

        expect(config.showFpsIndicator).toBe(true);
    });

    test('updateDesktopConfig writes showFpsIndicator to show_fps_indicator', async () => {
        await updateDesktopConfig(config => { config.showFpsIndicator = true; });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.show_fps_indicator).toBe(true);
    });
});

describe('devToolsOpen config round-trip', () => {
    beforeEach(() => jest.clearAllMocks());

    test('loadDesktopConfig reads dev_tools_open from toml', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ dev_tools_open: true });

        const config = await loadDesktopConfig();

        expect(config.devToolsOpen).toBe(true);
    });

    test('updateDesktopConfig writes devToolsOpen to dev_tools_open', async () => {
        await updateDesktopConfig(config => { config.devToolsOpen = true; });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.dev_tools_open).toBe(true);
    });
});

describe('sync settings config round-trip', () => {
    beforeEach(() => jest.clearAllMocks());

    test('loadDesktopConfig reads sync_enabled and sync_only_on_wifi from toml', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ sync_enabled: false, sync_only_on_wifi: false });

        const config = await loadDesktopConfig();

        expect(config.syncEnabled).toBe(false);
        expect(config.syncOnlyOnWifi).toBe(false);
    });

    test('updateDesktopConfig writes sync settings to snake_case toml keys', async () => {
        await updateDesktopConfig(config => { config.syncEnabled = true; config.syncOnlyOnWifi = false; });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.sync_enabled).toBe(true);
        expect(tomlArg.sync_only_on_wifi).toBe(false);
    });

    test('loadDesktopConfig leaves sync settings undefined when absent so the UI applies defaults', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({});

        const config = await loadDesktopConfig();

        expect(config.syncEnabled).toBeUndefined();
        expect(config.syncOnlyOnWifi).toBeUndefined();
    });
});

describe('updateLastDownloadFolder', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets lastDownloadFolder and saves', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({});

        await updateLastDownloadFolder('/downloads');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.last_download_folder).toBe('/downloads');
    });
});

describe('getRecentSearches', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns [] when recent_searches is unset', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({});

        const result = await getRecentSearches();

        expect(result).toEqual([]);
    });

    test('returns stored list', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ recent_searches: ['cats', 'dogs'] });

        const result = await getRecentSearches();

        expect(result).toEqual(['cats', 'dogs']);
    });
});

describe('addRecentSearch', () => {
    beforeEach(() => jest.clearAllMocks());

    test('deduplicates and prepends', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ recent_searches: ['cats', 'dogs'] });

        await addRecentSearch('cats');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_searches).toEqual(['cats', 'dogs']);
    });

    test('prepends new search at front', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ recent_searches: ['cats'] });

        await addRecentSearch('dogs');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_searches[0]).toBe('dogs');
    });

    test('caps list at 10 entries', async () => {
        const existing = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10'];
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ recent_searches: existing });

        await addRecentSearch('new');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_searches).toHaveLength(10);
        expect(tomlArg.recent_searches[0]).toBe('new');
    });
});

describe('removeRecentSearch', () => {
    beforeEach(() => jest.clearAllMocks());

    test('filters out given search', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ recent_searches: ['cats', 'dogs', 'birds'] });

        await removeRecentSearch('dogs');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_searches).toEqual(['cats', 'birds']);
    });
});

describe('developerMode persistence', () => {
    beforeEach(() => jest.clearAllMocks());

    test('reads developer_mode from TOML into developerMode', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ developer_mode: true });

        const config = await loadDesktopConfig();

        expect(config.developerMode).toBe(true);
    });

    test('writes developerMode to TOML as developer_mode', async () => {
        await updateDesktopConfig(config => { config.developerMode = true; });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.developer_mode).toBe(true);
    });

    test('round-trips developerMode through save and load', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));

        await updateDesktopConfig(config => { config.developerMode = true; });
        const savedToml = mockWriteToml.mock.calls[0][1];

        mockReadToml.mockResolvedValue(savedToml);
        const loaded = await loadDesktopConfig();

        expect(loaded.developerMode).toBe(true);
    });
});

describe('updateDesktopConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('reads current config, applies the mutation, and writes snake_case TOML', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ theme: 'dark' });

        await updateDesktopConfig(config => {
            config.developerMode = true;
        });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        // The pre-existing value survives and the mutation is applied, converted to snake_case.
        expect(tomlArg.theme).toBe('dark');
        expect(tomlArg.developer_mode).toBe(true);
    });
});


//
// The pure conversions between the on-disk TOML and the in-memory config. Both were private until
// every function in this module was exported.
//
describe('tomlToDesktopConfig', () => {
    test('converts every snake_case key to its camelCase field', () => {
        const config = tomlToDesktopConfig({
            last_folder: '/folder',
            theme: 'dark',
            recent_searches: ['cats'],
            last_download_folder: '/downloads',
            last_database: '/db',
            show_fps_indicator: true,
            developer_mode: true,
            dev_tools_open: true,
            sync_enabled: false,
            sync_only_on_wifi: false,
        });

        expect(config).toEqual({
            lastFolder: '/folder',
            theme: 'dark',
            recentSearches: ['cats'],
            lastDownloadFolder: '/downloads',
            lastDatabase: '/db',
            showFpsIndicator: true,
            developerMode: true,
            devToolsOpen: true,
            syncEnabled: false,
            syncOnlyOnWifi: false,
        });
    });

    test('leaves absent keys absent rather than filling in defaults', () => {
        // The UI applies its own defaults, so an unset value has to stay unset rather than becoming
        // false or an empty string here.
        expect(tomlToDesktopConfig({})).toEqual({});
    });
});

describe('desktopConfigToToml', () => {
    test('converts every camelCase field to its snake_case key', () => {
        const toml = desktopConfigToToml({
            lastFolder: '/folder',
            theme: 'dark',
            recentSearches: ['cats'],
            lastDownloadFolder: '/downloads',
            lastDatabase: '/db',
            showFpsIndicator: true,
            developerMode: true,
            devToolsOpen: true,
            syncEnabled: false,
            syncOnlyOnWifi: false,
        });

        expect(toml).toEqual({
            last_folder: '/folder',
            theme: 'dark',
            recent_searches: ['cats'],
            last_download_folder: '/downloads',
            last_database: '/db',
            show_fps_indicator: true,
            developer_mode: true,
            dev_tools_open: true,
            sync_enabled: false,
            sync_only_on_wifi: false,
        });
    });

    test('omits absent fields rather than writing them as null', () => {
        expect(desktopConfigToToml({})).toEqual({});
    });

    test('round trips a config through TOML and back unchanged', () => {
        const original = { lastFolder: '/folder', theme: 'light' as const, recentSearches: ['dogs'] };

        expect(tomlToDesktopConfig(desktopConfigToToml(original))).toEqual(original);
    });
});

//
// The point of routing every edit through updateDesktopConfig: a key set by someone else between
// this edit's read and its write is still there afterwards. The load-then-save this replaced wrote
// back a whole config read earlier, so it discarded anything changed in the meantime.
//
describe('updateDesktopConfig keeps concurrent changes', () => {
    beforeEach(() => jest.clearAllMocks());

    test('keeps a key written by someone else while this edit was being made', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ last_database: '/set-by-another-process' });

        await updateDesktopConfig(config => {
            config.theme = 'dark';
        });

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.theme).toBe('dark');
        expect(tomlArg.last_database).toBe('/set-by-another-process');
    });

    test('caps the recent searches at MAX_RECENT_SEARCHES', async () => {
        const existing = Array.from({ length: MAX_RECENT_SEARCHES }, (_unused, index) => `search${index}`);
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.toml'));
        mockReadToml.mockResolvedValue({ recent_searches: existing });

        await addRecentSearch('newest');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.recent_searches).toHaveLength(MAX_RECENT_SEARCHES);
        expect(tomlArg.recent_searches[0]).toBe('newest');
        expect(tomlArg.recent_searches).not.toContain(existing[MAX_RECENT_SEARCHES - 1]);
    });
});

describe('asFolderConfigKey', () => {
    test('returns each of the keys a folder picker is allowed to use', () => {
        for (const folderKey of FOLDER_CONFIG_KEYS) {
            expect(asFolderConfigKey(folderKey)).toBe(folderKey);
        }
    });

    test('throws on a key the config does not hold', () => {
        expect(() => asFolderConfigKey('lastFolde')).toThrow(/Unknown folder config key "lastFolde"/);
    });

    test('names the keys it does accept, so the message says how to fix it', () => {
        expect(() => asFolderConfigKey('theme')).toThrow(/lastFolder, lastDownloadFolder/);
    });

    test('throws on an empty key rather than treating it as the default', () => {
        expect(() => asFolderConfigKey('')).toThrow(/Unknown folder config key/);
    });
});

describe('getFolderPath', () => {
    beforeEach(() => jest.clearAllMocks());

    test('reads the folder remembered under the given key', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadToml.mockResolvedValue({ last_folder: '/photos', last_download_folder: '/downloads' });

        expect(await getFolderPath('lastFolder')).toBe('/photos');
        expect(await getFolderPath('lastDownloadFolder')).toBe('/downloads');
    });

    test('returns undefined when nothing is remembered under that key yet', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadToml.mockResolvedValue({ last_folder: '/photos' });

        expect(await getFolderPath('lastDownloadFolder')).toBeUndefined();
    });

    test('returns undefined when there is no config file at all', async () => {
        mockPathExists.mockResolvedValue(false);

        expect(await getFolderPath('lastFolder')).toBeUndefined();
    });

    test('throws on an unknown key without reading the config', async () => {
        await expect(getFolderPath('nonsense')).rejects.toThrow(/Unknown folder config key/);
        expect(mockReadToml).not.toHaveBeenCalled();
    });
});

describe('updateFolderPath', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes the chosen folder under the given key', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadToml.mockResolvedValue({});

        await updateFolderPath('lastDownloadFolder', '/new/downloads');

        expect(mockWriteToml.mock.calls[0][1].last_download_folder).toBe('/new/downloads');
    });

    test('replaces the folder previously remembered under that key', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadToml.mockResolvedValue({ last_folder: '/old' });

        await updateFolderPath('lastFolder', '/new');

        expect(mockWriteToml.mock.calls[0][1].last_folder).toBe('/new');
    });

    //
    // A folder picker stays open for as long as the user takes to choose, so the config is written
    // against its current contents rather than a copy read before the dialog opened.
    //
    test('leaves every other setting alone, including ones changed while the dialog was open', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadToml.mockResolvedValue({ theme: 'dark', last_database: '/set-while-dialog-was-open' });

        await updateFolderPath('lastFolder', '/new/photos');

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.last_folder).toBe('/new/photos');
        expect(tomlArg.theme).toBe('dark');
        expect(tomlArg.last_database).toBe('/set-while-dialog-was-open');
    });

    test('throws on an unknown key without writing anything', async () => {
        await expect(updateFolderPath('nonsense', '/somewhere')).rejects.toThrow(/Unknown folder config key/);
        expect(mockWriteToml).not.toHaveBeenCalled();
    });
});
