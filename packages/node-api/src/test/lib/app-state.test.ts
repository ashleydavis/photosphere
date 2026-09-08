// Mock node-utils fs helpers so tests don't touch the real filesystem.
const mockReadYaml = jest.fn();
const mockWriteYaml = jest.fn();

jest.mock('node-utils', () => ({
    readYaml: mockReadYaml,
    writeYaml: mockWriteYaml,
    // Where state.yaml sits, beside config.yaml. Named here so the module under test resolves a path
    // at import time without reaching for a real home directory.
    getConfigDir: () => '/test-config',
    // Mirror the real updateYaml as a read-modify-write over the mocked fs helpers, so the state
    // mutators (which go through updateAppState -> updateYaml) still exercise the mocked
    // readYaml/writeYaml the assertions rely on.
    updateYaml: async (filePath: string, fallback: any, mutator: (current: any) => any) => {
        const read = await mockReadYaml(filePath);
        const current = read === undefined ? fallback : read;
        const updated = mutator(current);
        await mockWriteYaml(filePath, updated);
    },
}));

import {
    loadAppState,
    updateAppState,
    updateLastFolder,
    updateLastDownloadFolder,
    getRecentSearches,
    addRecentSearch,
    removeRecentSearch,
    asFolderStateKey,
    getFolderPath,
    updateFolderPath,
    FOLDER_STATE_KEYS,
    MAX_RECENT_SEARCHES,
    yamlToAppState,
    appStateToYaml,
    getAppStateValue,
    setAppStateValue,
    appStateSettings,
} from '../../lib/app-state';
import { getStatePath } from '../../lib/state-file';

//
// The state file is what the app remembered so the interface comes back the way it was left. It sits
// beside config.yaml, which is what the user chose, and the split is the point: only one of the two is
// worth documenting or carrying to another machine.
//
describe('getStatePath', () => {
    test('returns a string ending with state.yaml, beside the config file', () => {
        const result = getStatePath();

        expect(typeof result).toBe('string');
        expect(result).toMatch(/state\.yaml$/);
    });
});

describe('loadAppState', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns {} when no file exists', async () => {
        mockReadYaml.mockResolvedValue(undefined);

        expect(await loadAppState()).toEqual({});
    });

    test('converts snake_case document keys to camelCase fields', async () => {
        mockReadYaml.mockResolvedValue({
            desktop: {
                last_folder: '/folder',
                last_download_folder: '/downloads',
                dev_tools_open: true,
            },
            searches: { recent: ['cats'] },
            gallery: { sort: 'name', row_height: 240 },
        });

        const state = await loadAppState();

        expect(state.lastFolder).toBe('/folder');
        expect(state.lastDownloadFolder).toBe('/downloads');
        expect(state.devToolsOpen).toBe(true);
        expect(state.recentSearches).toEqual(['cats']);
        expect(state.gallerySort).toBe('name');
        expect(state.galleryRowHeight).toBe(240);
    });

    test('reads nothing and writes nothing when the file is absent', async () => {
        mockReadYaml.mockResolvedValue(undefined);

        await loadAppState();

        expect(mockWriteYaml).not.toHaveBeenCalled();
    });
});

describe('updateLastFolder', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets lastFolder and saves', async () => {
        mockReadYaml.mockResolvedValue({});

        await updateLastFolder('/new/folder');

        expect(mockWriteYaml.mock.calls[0][1].desktop.last_folder).toBe('/new/folder');
    });
});

describe('updateLastDownloadFolder', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets lastDownloadFolder and saves', async () => {
        mockReadYaml.mockResolvedValue({});

        await updateLastDownloadFolder('/downloads');

        expect(mockWriteYaml.mock.calls[0][1].desktop.last_download_folder).toBe('/downloads');
    });
});

describe('devToolsOpen state round-trip', () => {
    beforeEach(() => jest.clearAllMocks());

    test('loadAppState reads dev_tools_open from the desktop section', async () => {
        mockReadYaml.mockResolvedValue({ desktop: { dev_tools_open: true } });

        expect((await loadAppState()).devToolsOpen).toBe(true);
    });

    test('updateAppState writes devToolsOpen to dev_tools_open', async () => {
        await updateAppState(state => { state.devToolsOpen = true; });

        expect(mockWriteYaml.mock.calls[0][1].desktop.dev_tools_open).toBe(true);
    });
});

describe('the gallery view state', () => {
    beforeEach(() => jest.clearAllMocks());

    test('is written with snake_case keys under gallery', async () => {
        await updateAppState(state => {
            state.gallerySort = 'name';
            state.galleryRowHeight = 240;
        });

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.gallery.sort).toBe('name');
        expect(document.gallery.row_height).toBe(240);
        expect(document.gallery.gallerySort).toBeUndefined();
    });

    test('a row height that is not a number is dropped rather than handed to the interface', () => {
        expect(yamlToAppState({ gallery: { row_height: 'tall' } as any }).galleryRowHeight).toBeUndefined();
    });
});

describe('getRecentSearches', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns [] when recent is unset', async () => {
        mockReadYaml.mockResolvedValue({});

        expect(await getRecentSearches()).toEqual([]);
    });

    test('returns stored list', async () => {
        mockReadYaml.mockResolvedValue({ searches: { recent: ['cats', 'dogs'] } });

        expect(await getRecentSearches()).toEqual(['cats', 'dogs']);
    });
});

describe('addRecentSearch', () => {
    beforeEach(() => jest.clearAllMocks());

    test('deduplicates and prepends', async () => {
        mockReadYaml.mockResolvedValue({ searches: { recent: ['cats', 'dogs'] } });

        await addRecentSearch('cats');

        expect(mockWriteYaml.mock.calls[0][1].searches.recent).toEqual(['cats', 'dogs']);
    });

    test('prepends new search at front', async () => {
        mockReadYaml.mockResolvedValue({ searches: { recent: ['cats'] } });

        await addRecentSearch('dogs');

        expect(mockWriteYaml.mock.calls[0][1].searches.recent[0]).toBe('dogs');
    });

    test('caps list at MAX_RECENT_SEARCHES entries', async () => {
        const existing = Array.from({ length: MAX_RECENT_SEARCHES }, (_unused, index) => `search${index}`);
        mockReadYaml.mockResolvedValue({ searches: { recent: existing } });

        await addRecentSearch('newest');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.searches.recent).toHaveLength(MAX_RECENT_SEARCHES);
        expect(document.searches.recent[0]).toBe('newest');
        expect(document.searches.recent).not.toContain(existing[MAX_RECENT_SEARCHES - 1]);
    });
});

describe('removeRecentSearch', () => {
    beforeEach(() => jest.clearAllMocks());

    test('filters out given search', async () => {
        mockReadYaml.mockResolvedValue({ searches: { recent: ['cats', 'dogs', 'birds'] } });

        await removeRecentSearch('dogs');

        expect(mockWriteYaml.mock.calls[0][1].searches.recent).toEqual(['cats', 'birds']);
    });
});

describe('asFolderStateKey', () => {
    test('returns each of the keys a folder picker is allowed to use', () => {
        for (const folderKey of FOLDER_STATE_KEYS) {
            expect(asFolderStateKey(folderKey)).toBe(folderKey);
        }
    });

    test('throws on a key the state does not hold', () => {
        expect(() => asFolderStateKey('lastFolde')).toThrow(/Unknown folder state key "lastFolde"/);
    });

    test('names the keys it does accept, so the message says how to fix it', () => {
        expect(() => asFolderStateKey('theme')).toThrow(/lastFolder, lastDownloadFolder/);
    });

    test('throws on an empty key rather than treating it as the default', () => {
        expect(() => asFolderStateKey('')).toThrow(/Unknown folder state key/);
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

    test('returns undefined when there is no state file at all', async () => {
        mockReadYaml.mockResolvedValue(undefined);

        expect(await getFolderPath('lastFolder')).toBeUndefined();
    });

    test('throws on an unknown key without reading the file', async () => {
        await expect(getFolderPath('nonsense')).rejects.toThrow(/Unknown folder state key/);
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
    // A folder picker stays open for as long as the user takes to choose, so the file is written
    // against its current contents rather than a copy read before the dialog opened.
    //
    test('leaves everything else alone, including what changed while the dialog was open', async () => {
        mockReadYaml.mockResolvedValue({
            gallery: { sort: 'name' },
            news: { shown_news_ids: ['release-1'] },
        });

        await updateFolderPath('lastFolder', '/new/photos');

        const document = mockWriteYaml.mock.calls[0][1];
        expect(document.desktop.last_folder).toBe('/new/photos');
        expect(document.gallery.sort).toBe('name');
        expect(document.news.shown_news_ids).toEqual(['release-1']);
    });
});

//
// The pure conversions between the on-disk document and the in-memory flat state.
//
describe('yamlToAppState and appStateToYaml', () => {
    test('converts every snake_case key to its camelCase field', () => {
        expect(yamlToAppState({
            desktop: {
                last_folder: '/folder',
                last_download_folder: '/downloads',
                dev_tools_open: true,
            },
            searches: { recent: ['cats'] },
            gallery: { sort: 'name', row_height: 240 },
            ui: { 'sidebar-collapsed-databases': true },
        })).toEqual({
            lastFolder: '/folder',
            lastDownloadFolder: '/downloads',
            devToolsOpen: true,
            recentSearches: ['cats'],
            gallerySort: 'name',
            galleryRowHeight: 240,
            ui: { 'sidebar-collapsed-databases': true },
        });
    });

    test('leaves absent keys absent rather than filling in defaults', () => {
        expect(yamlToAppState({})).toEqual({});
    });

    test('round trips the whole state through the document and back unchanged', () => {
        const original = {
            lastFolder: '/folder',
            recentSearches: ['dogs'],
            gallerySort: 'date',
            ui: { 'sidebar-collapsed-databases': true },
        };

        expect(yamlToAppState(appStateToYaml(original, {}))).toEqual(original);
    });

    test('writes no empty section', () => {
        expect(appStateToYaml({}, {})).toEqual({});
    });

    test('a section that has been emptied is removed rather than left behind', () => {
        expect(appStateToYaml({}, { desktop: { last_folder: '/folder' } })).toEqual({});
    });

    //
    // The news state is in the same document and appears nowhere in the flat view, so a write that
    // rebuilt the document from the flat view alone would delete what the user had already been shown.
    //
    test('leaves the news state alone', () => {
        expect(appStateToYaml({ gallerySort: 'name' }, { news: { shown_news_ids: ['release-1'] } }))
            .toEqual({
                gallery: { sort: 'name' },
                news: { shown_news_ids: ['release-1'] },
            });
    });
});

//
// The flat namespace over state.yaml. Unlike the config half this one has a catch-all, because the
// interface invents keys as it goes: a collapsible section builds its own key from its id.
//
describe('reading and writing one state key by name', () => {

    test('a declared key is read from and written to its own field', () => {
        const state: any = {};
        setAppStateValue(state, 'gallerySort', 'name');

        expect(state.gallerySort).toBe('name');
        expect(state.ui).toBeUndefined();
        expect(getAppStateValue(state, 'gallerySort')).toBe('name');
    });

    test('a key the document does not declare is read from and written to the ui section', () => {
        const state: any = {};
        setAppStateValue(state, 'sidebar-collapsed-databases', true);

        expect(state.ui).toEqual({ 'sidebar-collapsed-databases': true });
        expect(getAppStateValue(state, 'sidebar-collapsed-databases')).toBe(true);
    });

    test('a key nothing has been stored under reads as undefined', () => {
        expect(getAppStateValue({}, 'gallerySort')).toBeUndefined();
        expect(getAppStateValue({}, 'sidebar-collapsed-databases')).toBeUndefined();
    });

    test('writing nothing removes a declared key rather than leaving it as it was', () => {
        const state: any = { gallerySort: 'name' };
        setAppStateValue(state, 'gallerySort', undefined);

        expect('gallerySort' in state).toBe(false);
    });

    test('writing nothing removes a ui key rather than leaving it as it was', () => {
        const state: any = {};
        setAppStateValue(state, 'sidebar-collapsed-databases', true);
        setAppStateValue(state, 'sidebar-collapsed-databases', undefined);

        expect(state.ui).toEqual({});
        expect(getAppStateValue(state, 'sidebar-collapsed-databases')).toBeUndefined();
    });

    test('clearing a ui key that was never set changes nothing', () => {
        const state: any = {};
        setAppStateValue(state, 'never-set', undefined);

        expect(state.ui).toBeUndefined();
    });

    test('every key that has a value is listed together under its own name', () => {
        const state: any = { gallerySort: 'name', devToolsOpen: true };
        setAppStateValue(state, 'sidebar-collapsed-databases', true);

        expect(appStateSettings(state)).toEqual({
            gallerySort: 'name',
            devToolsOpen: true,
            'sidebar-collapsed-databases': true,
        });
    });

    test('a key with no value is left out rather than listed as undefined', () => {
        expect(appStateSettings({})).toEqual({});
    });
});
