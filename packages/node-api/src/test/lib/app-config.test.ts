// Mock node-utils fs helpers so tests don't touch the real filesystem.
const mockReadYaml = jest.fn();
const mockWriteYaml = jest.fn();

jest.mock('node-utils', () => ({
    readYaml: mockReadYaml,
    writeYaml: mockWriteYaml,
    // Where config.yaml sits. Named here so the module under test resolves a path at import time
    // without reaching for a real home directory.
    getConfigDir: () => '/test-config',
    // Mirror the real updateYaml as a read-modify-write over the mocked fs helpers, so the
    // config mutators (which go through updateAppConfig -> updateYaml) still exercise
    // the mocked readYaml/writeYaml the assertions rely on.
    updateYaml: async (filePath: string, fallback: any, mutator: (current: any) => any) => {
        const read = await mockReadYaml(filePath);
        const current = read === undefined ? fallback : read;
        const updated = mutator(current);
        await mockWriteYaml(filePath, updated);
    },
}));

import {
    loadAppConfig,
    updateLastFolder,
    getTheme,
    setTheme,
    updateLastDownloadFolder,
    getRecentSearches,
    addRecentSearch,
    removeRecentSearch,
    updateAppConfig,
    yamlToAppConfig,
    appConfigToYaml,
    asFolderConfigKey,
    getFolderPath,
    updateFolderPath,
    FOLDER_CONFIG_KEYS,
    MAX_RECENT_SEARCHES,
} from '../../lib/app-config';
import { getConfigPath } from '../../lib/config-file';

describe('getConfigPath', () => {
    test('returns a string ending with config.yaml', () => {
        const result = getConfigPath();

        expect(typeof result).toBe('string');
        expect(result).toMatch(/config\.yaml$/);
    });
});

describe('loadAppConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns {} when no file exists', async () => {
        mockReadYaml.mockResolvedValue(undefined);

        const config = await loadAppConfig();

        expect(config).toEqual({});
    });

    test('returns config from the document when the file exists', async () => {
        mockReadYaml.mockResolvedValue({
            theme: 'dark',
            desktop: { last_folder: '/photos' },
        });

        const config = await loadAppConfig();

        expect(config.theme).toBe('dark');
        expect(config.lastFolder).toBe('/photos');
    });

    test('converts snake_case document keys to camelCase TypeScript fields', async () => {
        mockReadYaml.mockResolvedValue({
            desktop: {
                last_folder: '/folder',
                recent_searches: ['cats'],
                last_download_folder: '/downloads',
                show_fps_indicator: true,
            },
            auto_import: {
                default_database_path: '/db',
            },
        });

        const config = await loadAppConfig();

        expect(config.lastFolder).toBe('/folder');
        expect(config.recentSearches).toEqual(['cats']);
        expect(config.lastDownloadFolder).toBe('/downloads');
        expect(config.defaultDatabasePath).toBe('/db');
        expect(config.showFpsIndicator).toBe(true);
    });
});

//
// Loading is a read and nothing else. It used to migrate an old desktop.json, write the file and
// delete the JSON, so a read could take a lock, write a file and remove another. That is gone.
//
describe('loadAppConfig does not write', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns defaults and writes nothing when the file is absent', async () => {
        mockReadYaml.mockResolvedValue(undefined);

        const config = await loadAppConfig();

        expect(config).toEqual({});
        expect(mockWriteYaml).not.toHaveBeenCalled();
    });
});

describe('updateAppConfig writes snake_case sections', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes the theme at the top level', async () => {
        await updateAppConfig(config => { config.theme = 'light'; });

        expect(mockWriteYaml).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ theme: 'light' })
        );
    });

    test('converts camelCase fields to snake_case keys in their own sections', async () => {
        await updateAppConfig(config => {
            config.lastFolder = '/folder';
            config.recentSearches = ['cats'];
            config.lastDownloadFolder = '/downloads';
            config.defaultDatabasePath = '/db';
            config.showFpsIndicator = true;
        });

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.last_folder).toBe('/folder');
        expect(document.desktop.recent_searches).toEqual(['cats']);
        expect(document.desktop.last_download_folder).toBe('/downloads');
        expect(document.auto_import.default_database_path).toBe('/db');
        expect(document.desktop.show_fps_indicator).toBe(true);
        expect(document.desktop.lastFolder).toBeUndefined();
        expect(document.last_folder).toBeUndefined();
    });
});

describe('the automatic import settings', () => {
    beforeEach(() => jest.clearAllMocks());

    test('are written with snake_case keys under auto_import', async () => {
        await updateAppConfig(config => {
            config.autoImportEnabled = true;
            config.defaultDatabasePath = '/home/someone/photosphere-default';
            config.autoImportSources = [{ type: 'folder', path: '/home/someone/Pictures', recurse: true }];
            config.autoImportCleanupEnabled = true;
        });

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.auto_import.enabled).toBe(true);
        expect(document.auto_import.default_database_path).toBe('/home/someone/photosphere-default');
        expect(document.auto_import.sources).toEqual([{ type: 'folder', path: '/home/someone/Pictures', recurse: true }]);
        expect(document.auto_import.cleanup_enabled).toBe(true);
        expect(document.auto_import.autoImportEnabled).toBeUndefined();
    });

    test('round-trip through the document', () => {
        const config = {
            autoImportEnabled: true,
            defaultDatabasePath: '/photos',
            autoImportSources: [{ type: 'folder' as const, path: '/photos', recurse: false }],
            autoImportCleanupEnabled: false,
        };

        expect(yamlToAppConfig(appConfigToYaml(config, {}))).toEqual(config);
    });

    test('are absent from a config that does not mention them', () => {
        const config = yamlToAppConfig({ theme: 'dark' });

        expect(config.autoImportEnabled).toBeUndefined();
        expect(config.defaultDatabasePath).toBeUndefined();
        expect(config.autoImportSources).toBeUndefined();
        expect(config.autoImportCleanupEnabled).toBeUndefined();
    });

    test('a malformed watched place is dropped and the rest are kept', () => {
        const config = yamlToAppConfig({
            auto_import: {
                sources: [
                    { type: 'folder', path: '/photos', recurse: false },
                    { type: 'folder' },
                    { type: 'device-album', album_id: 'all' },
                ],
            },
        });

        expect(config.autoImportSources).toEqual([
            { type: 'folder', path: '/photos', recurse: false },
            { type: 'device-album', albumId: 'all' },
        ]);
    });
});

describe('updateLastFolder', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets lastFolder and saves', async () => {
        mockReadYaml.mockResolvedValue({});

        await updateLastFolder('/new/folder');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.last_folder).toBe('/new/folder');
    });
});

describe('getTheme', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns system when theme is unset', async () => {
        mockReadYaml.mockResolvedValue({});

        const result = await getTheme();

        expect(result).toBe('system');
    });

    test('returns stored value', async () => {
        mockReadYaml.mockResolvedValue({ theme: 'dark' });

        const result = await getTheme();

        expect(result).toBe('dark');
    });

    test('returns system when the file names a theme nobody defined', async () => {
        mockReadYaml.mockResolvedValue({ theme: 'neon' });

        const result = await getTheme();

        expect(result).toBe('system');
    });
});

describe('setTheme', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets theme and saves', async () => {
        mockReadYaml.mockResolvedValue({});

        await setTheme('light');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.theme).toBe('light');
    });
});

describe('showFpsIndicator config round-trip', () => {
    beforeEach(() => jest.clearAllMocks());

    test('loadAppConfig reads show_fps_indicator from the desktop section', async () => {
        mockReadYaml.mockResolvedValue({ desktop: { show_fps_indicator: true } });

        const config = await loadAppConfig();

        expect(config.showFpsIndicator).toBe(true);
    });

    test('updateAppConfig writes showFpsIndicator to show_fps_indicator', async () => {
        await updateAppConfig(config => { config.showFpsIndicator = true; });

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.show_fps_indicator).toBe(true);
    });
});

describe('devToolsOpen config round-trip', () => {
    beforeEach(() => jest.clearAllMocks());

    test('loadAppConfig reads dev_tools_open from the desktop section', async () => {
        mockReadYaml.mockResolvedValue({ desktop: { dev_tools_open: true } });

        const config = await loadAppConfig();

        expect(config.devToolsOpen).toBe(true);
    });

    test('updateAppConfig writes devToolsOpen to dev_tools_open', async () => {
        await updateAppConfig(config => { config.devToolsOpen = true; });

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.dev_tools_open).toBe(true);
    });
});

describe('sync settings config round-trip', () => {
    beforeEach(() => jest.clearAllMocks());

    test('loadAppConfig reads enabled and only_on_wifi from the sync section', async () => {
        mockReadYaml.mockResolvedValue({ sync: { enabled: false, only_on_wifi: false } });

        const config = await loadAppConfig();

        expect(config.syncEnabled).toBe(false);
        expect(config.syncOnlyOnWifi).toBe(false);
    });

    test('updateAppConfig writes sync settings into the sync section', async () => {
        await updateAppConfig(config => { config.syncEnabled = true; config.syncOnlyOnWifi = false; });

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.sync.enabled).toBe(true);
        expect(document.sync.only_on_wifi).toBe(false);
    });

    //
    // The interface applies its own defaults (syncing on, Wi-Fi only) to a setting nobody has
    // touched, so an absent value has to arrive as undefined. Handing back the file reader's
    // defaults instead would silently switch syncing off on a fresh install.
    //
    test('loadAppConfig leaves sync settings undefined when absent so the UI applies defaults', async () => {
        mockReadYaml.mockResolvedValue({});

        const config = await loadAppConfig();

        expect(config.syncEnabled).toBeUndefined();
        expect(config.syncOnlyOnWifi).toBeUndefined();
    });

    test('loadAppConfig leaves sync settings undefined when the file has no sync section at all', async () => {
        mockReadYaml.mockResolvedValue({ theme: 'dark' });

        const config = await loadAppConfig();

        expect(config.syncEnabled).toBeUndefined();
        expect(config.syncOnlyOnWifi).toBeUndefined();
    });
});

describe('updateLastDownloadFolder', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets lastDownloadFolder and saves', async () => {
        mockReadYaml.mockResolvedValue({});

        await updateLastDownloadFolder('/downloads');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.last_download_folder).toBe('/downloads');
    });
});

describe('getRecentSearches', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns [] when recent_searches is unset', async () => {
        mockReadYaml.mockResolvedValue({});

        const result = await getRecentSearches();

        expect(result).toEqual([]);
    });

    test('returns stored list', async () => {
        mockReadYaml.mockResolvedValue({ desktop: { recent_searches: ['cats', 'dogs'] } });

        const result = await getRecentSearches();

        expect(result).toEqual(['cats', 'dogs']);
    });
});

describe('addRecentSearch', () => {
    beforeEach(() => jest.clearAllMocks());

    test('deduplicates and prepends', async () => {
        mockReadYaml.mockResolvedValue({ desktop: { recent_searches: ['cats', 'dogs'] } });

        await addRecentSearch('cats');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.recent_searches).toEqual(['cats', 'dogs']);
    });

    test('prepends new search at front', async () => {
        mockReadYaml.mockResolvedValue({ desktop: { recent_searches: ['cats'] } });

        await addRecentSearch('dogs');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.recent_searches[0]).toBe('dogs');
    });

    test('caps list at MAX_RECENT_SEARCHES entries', async () => {
        const existing = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10'];
        mockReadYaml.mockResolvedValue({ desktop: { recent_searches: existing } });

        await addRecentSearch('new');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.recent_searches).toHaveLength(MAX_RECENT_SEARCHES);
        expect(document.desktop.recent_searches[0]).toBe('new');
    });
});

describe('removeRecentSearch', () => {
    beforeEach(() => jest.clearAllMocks());

    test('filters out given search', async () => {
        mockReadYaml.mockResolvedValue({ desktop: { recent_searches: ['cats', 'dogs', 'birds'] } });

        await removeRecentSearch('dogs');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.recent_searches).toEqual(['cats', 'birds']);
    });
});

describe('developerMode persistence', () => {
    beforeEach(() => jest.clearAllMocks());

    test('reads developer_mode from the document into developerMode', async () => {
        mockReadYaml.mockResolvedValue({ developer_mode: true });

        const config = await loadAppConfig();

        expect(config.developerMode).toBe(true);
    });

    test('writes developerMode to the document as developer_mode', async () => {
        await updateAppConfig(config => { config.developerMode = true; });

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.developer_mode).toBe(true);
    });

    test('round-trips developerMode through save and load', async () => {
        await updateAppConfig(config => { config.developerMode = true; });
        const saved = mockWriteYaml.mock.calls[0][1];

        mockReadYaml.mockResolvedValue(saved);
        const loaded = await loadAppConfig();

        expect(loaded.developerMode).toBe(true);
    });
});

describe('updateAppConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('reads current config, applies the mutation, and writes it back nested', async () => {
        mockReadYaml.mockResolvedValue({ theme: 'dark' });

        await updateAppConfig(config => {
            config.developerMode = true;
        });

        const document = mockWriteYaml.mock.calls[0][1];
        // The pre-existing value survives and the mutation is applied.
        expect(document.theme).toBe('dark');
        expect(document.developer_mode).toBe(true);
    });

    //
    // The flat view owns only some of the file. The mobile loops' pacing, the database the mobile
    // sync pushes and the news state are all in the same document and appear nowhere in this view,
    // so a desktop write that rebuilt the document from the flat view alone would delete them.
    //
    test('leaves the parts of the file this view does not own exactly as they were', async () => {
        mockReadYaml.mockResolvedValue({
            auto_import: {
                enabled: true,
                pause_between_runs_ms: 5000,
                sources: [{ type: 'device-album', album_id: 'all' }],
            },
            sync: {
                enabled: true,
                database_path: 'photosphere-default',
                pause_between_runs_ms: 300000,
            },
            news: {
                shown_news_ids: ['release-1'],
                last_shown_update_version: '1.2.3',
            },
        });

        await updateAppConfig(config => {
            config.lastFolder = '/new/folder';
        });

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.last_folder).toBe('/new/folder');
        expect(document.auto_import.pause_between_runs_ms).toBe(5000);
        expect(document.auto_import.sources).toEqual([{ type: 'device-album', album_id: 'all' }]);
        expect(document.sync.database_path).toBe('photosphere-default');
        expect(document.sync.pause_between_runs_ms).toBe(300000);
        expect(document.news).toEqual({
            shown_news_ids: ['release-1'],
            last_shown_update_version: '1.2.3',
        });
    });
});

//
// The pure conversions between the on-disk document and the in-memory flat config.
//
describe('yamlToAppConfig', () => {
    test('converts every snake_case key to its camelCase field', () => {
        const config = yamlToAppConfig({
            theme: 'dark',
            developer_mode: true,
            desktop: {
                last_folder: '/folder',
                recent_searches: ['cats'],
                last_download_folder: '/downloads',
                show_fps_indicator: true,
                dev_tools_open: true,
            },
            sync: {
                enabled: false,
                only_on_wifi: false,
            },
            auto_import: {
                default_database_path: '/db',
            },
        });

        expect(config).toEqual({
            lastFolder: '/folder',
            theme: 'dark',
            recentSearches: ['cats'],
            lastDownloadFolder: '/downloads',
            defaultDatabasePath: '/db',
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
        expect(yamlToAppConfig({})).toEqual({});
    });

    test('a malformed section is ignored without discarding the sections that parsed', () => {
        const config = yamlToAppConfig({
            theme: 'light',
            desktop: 'not a section' as any,
            sync: { enabled: true },
        });

        expect(config.theme).toBe('light');
        expect(config.syncEnabled).toBe(true);
        expect(config.lastFolder).toBeUndefined();
    });
});

describe('appConfigToYaml', () => {
    test('converts every camelCase field to its snake_case key in the right section', () => {
        const document = appConfigToYaml({
            lastFolder: '/folder',
            theme: 'dark',
            recentSearches: ['cats'],
            lastDownloadFolder: '/downloads',
            defaultDatabasePath: '/db',
            showFpsIndicator: true,
            developerMode: true,
            devToolsOpen: true,
            syncEnabled: false,
            syncOnlyOnWifi: false,
        }, {});

        expect(document).toEqual({
            theme: 'dark',
            developer_mode: true,
            desktop: {
                last_folder: '/folder',
                recent_searches: ['cats'],
                last_download_folder: '/downloads',
                show_fps_indicator: true,
                dev_tools_open: true,
            },
            sync: {
                enabled: false,
                only_on_wifi: false,
            },
            auto_import: {
                default_database_path: '/db',
            },
        });
    });

    test('omits absent fields rather than writing them as null', () => {
        expect(appConfigToYaml({}, {})).toEqual({
            desktop: {},
            sync: {},
            auto_import: {},
        });
    });

    test('round trips a config through the document and back unchanged', () => {
        const original = { lastFolder: '/folder', theme: 'light' as const, recentSearches: ['dogs'] };

        expect(yamlToAppConfig(appConfigToYaml(original, {}))).toEqual(original);
    });
});

//
// The point of routing every edit through updateAppConfig: a key set by someone else between
// this edit's read and its write is still there afterwards. The load-then-save this replaced wrote
// back a whole config read earlier, so it discarded anything changed in the meantime.
//
describe('updateAppConfig keeps concurrent changes', () => {
    beforeEach(() => jest.clearAllMocks());

    test('keeps a key written by someone else while this edit was being made', async () => {
        mockReadYaml.mockResolvedValue({ auto_import: { default_database_path: '/set-by-another-process' } });

        await updateAppConfig(config => {
            config.theme = 'dark';
        });

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.theme).toBe('dark');
        expect(document.auto_import.default_database_path).toBe('/set-by-another-process');
    });

    test('caps the recent searches at MAX_RECENT_SEARCHES', async () => {
        const existing = Array.from({ length: MAX_RECENT_SEARCHES }, (_unused, index) => `search${index}`);
        mockReadYaml.mockResolvedValue({ desktop: { recent_searches: existing } });

        await addRecentSearch('newest');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.recent_searches).toHaveLength(MAX_RECENT_SEARCHES);
        expect(document.desktop.recent_searches[0]).toBe('newest');
        expect(document.desktop.recent_searches).not.toContain(existing[MAX_RECENT_SEARCHES - 1]);
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
        mockReadYaml.mockResolvedValue({ desktop: { last_folder: '/photos', last_download_folder: '/downloads' } });

        expect(await getFolderPath('lastFolder')).toBe('/photos');
        expect(await getFolderPath('lastDownloadFolder')).toBe('/downloads');
    });

    test('returns undefined when nothing is remembered under that key yet', async () => {
        mockReadYaml.mockResolvedValue({ desktop: { last_folder: '/photos' } });

        expect(await getFolderPath('lastDownloadFolder')).toBeUndefined();
    });

    test('returns undefined when there is no config file at all', async () => {
        mockReadYaml.mockResolvedValue(undefined);

        expect(await getFolderPath('lastFolder')).toBeUndefined();
    });

    test('throws on an unknown key without reading the config', async () => {
        await expect(getFolderPath('nonsense')).rejects.toThrow(/Unknown folder config key/);
        expect(mockReadYaml).not.toHaveBeenCalled();
    });
});

describe('updateFolderPath', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes the chosen folder under the given key', async () => {
        mockReadYaml.mockResolvedValue({});

        await updateFolderPath('lastDownloadFolder', '/new/downloads');

        expect(mockWriteYaml.mock.calls[0][1].desktop.last_download_folder).toBe('/new/downloads');
    });

    test('replaces the folder previously remembered under that key', async () => {
        mockReadYaml.mockResolvedValue({ desktop: { last_folder: '/old' } });

        await updateFolderPath('lastFolder', '/new');

        expect(mockWriteYaml.mock.calls[0][1].desktop.last_folder).toBe('/new');
    });

    //
    // A folder picker stays open for as long as the user takes to choose, so the config is written
    // against its current contents rather than a copy read before the dialog opened.
    //
    test('leaves every other setting alone, including ones changed while the dialog was open', async () => {
        mockReadYaml.mockResolvedValue({
            theme: 'dark',
            auto_import: { default_database_path: '/set-while-dialog-was-open' },
        });

        await updateFolderPath('lastFolder', '/new/photos');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.last_folder).toBe('/new/photos');
        expect(document.theme).toBe('dark');
        expect(document.auto_import.default_database_path).toBe('/set-while-dialog-was-open');
    });

    test('throws on an unknown key without writing anything', async () => {
        await expect(updateFolderPath('nonsense', '/somewhere')).rejects.toThrow(/Unknown folder config key/);
        expect(mockWriteYaml).not.toHaveBeenCalled();
    });
});
