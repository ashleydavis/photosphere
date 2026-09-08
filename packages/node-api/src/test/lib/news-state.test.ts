// Mock the node-utils fs helpers so tests don't touch the real filesystem. The news state now lives
// in the `news` section of state.yaml rather than in a news.yaml of its own, so what is mocked is
// the YAML document reader and writer the state file goes through.
const mockReadYaml = jest.fn();
const mockWriteYaml = jest.fn();

jest.mock('node-utils', () => ({
    readYaml: mockReadYaml,
    writeYaml: mockWriteYaml,
    getConfigDir: () => '/test-config',
    // Mirror the real updateYaml as a read-modify-write over the mocked helpers.
    updateYaml: async (filePath: string, fallback: any, mutator: (current: any) => any) => {
        const read = await mockReadYaml(filePath);
        const current = read === undefined ? fallback : read;
        const updated = mutator(current);
        await mockWriteYaml(filePath, updated);
    },
}));

import {
    loadNewsState,
    saveNewsState,
    getShownNewsIds,
    addShownNewsIds,
    getLastShownUpdateVersion,
    setLastShownUpdateVersion,
} from '../../lib/news-state';
import { getStatePath } from '../../lib/state-file';

//
// The document written by the call under test.
//
function writtenDocument(): any {
    return mockWriteYaml.mock.calls[0][1];
}

describe('where the news state lives', () => {
    test('is the state file, not a news.yaml of its own', () => {
        expect(getStatePath().endsWith('state.yaml')).toBe(true);
    });
});

describe('loadNewsState', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns empty state when the file does not exist', async () => {
        mockReadYaml.mockResolvedValue(undefined);

        const state = await loadNewsState();

        expect(state).toEqual({ shownNewsIds: [], feed: [] });
    });

    test('returns empty state when the state file has no news section', async () => {
        mockReadYaml.mockResolvedValue({ theme: 'dark' });

        const state = await loadNewsState();

        expect(state).toEqual({ shownNewsIds: [], feed: [] });
    });

    test('returns empty state when the news section is malformed', async () => {
        mockReadYaml.mockResolvedValue({ news: 'not a section' });

        const state = await loadNewsState();

        expect(state.shownNewsIds).toEqual([]);
    });

    test('parses shown_news_ids from the news section', async () => {
        mockReadYaml.mockResolvedValue({ news: { shown_news_ids: ['a', 'b'] } });

        const state = await loadNewsState();

        expect(state.shownNewsIds).toEqual(['a', 'b']);
        expect(state.lastShownUpdateVersion).toBeUndefined();
    });

    test('parses last_shown_update_version from the news section', async () => {
        mockReadYaml.mockResolvedValue({ news: { shown_news_ids: [], last_shown_update_version: '1.2.3' } });

        const state = await loadNewsState();

        expect(state.lastShownUpdateVersion).toBe('1.2.3');
    });

    test('omits last_shown_update_version when empty string', async () => {
        mockReadYaml.mockResolvedValue({ news: { last_shown_update_version: '' } });

        const state = await loadNewsState();

        expect(state.lastShownUpdateVersion).toBeUndefined();
    });

    //
    // A read that throws must not stop the app. The failure is reported rather than swallowed, but
    // the caller still gets an empty state.
    //
    test('returns empty state when the state file cannot be read at all', async () => {
        mockReadYaml.mockRejectedValue(new Error('the disk went away'));

        const state = await loadNewsState();

        expect(state).toEqual({ shownNewsIds: [], feed: [] });
    });
});

describe('saveNewsState', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes shown_news_ids in snake_case under the news section', async () => {
        mockReadYaml.mockResolvedValue(undefined);

        await saveNewsState({ shownNewsIds: ['a', 'b'], feed: [] });

        const writtenPath = mockWriteYaml.mock.calls[0][0];
        expect(writtenPath.endsWith('state.yaml')).toBe(true);
        expect(writtenDocument().news.shown_news_ids).toEqual(['a', 'b']);
        expect(writtenDocument().news.last_shown_update_version).toBeUndefined();
    });

    test('writes last_shown_update_version when set', async () => {
        mockReadYaml.mockResolvedValue(undefined);

        await saveNewsState({ shownNewsIds: [], lastShownUpdateVersion: '1.2.3', feed: [] });

        expect(writtenDocument().news.last_shown_update_version).toBe('1.2.3');
    });

    //
    // The news state shares its file with every setting the app has, so writing it must not disturb
    // any of them. This is the whole hazard of folding it in.
    //
    test('leaves every other section of the state file alone', async () => {
        mockReadYaml.mockResolvedValue({
            desktop: { last_folder: '/home/someone/photos' },
            searches: { recent: ['beach'] },
            gallery: { sort: 'name', row_height: 240 },
            ui: { 'sidebar-collapsed-databases': true },
        });

        await saveNewsState({ shownNewsIds: ['a'], feed: [] });

        const document = writtenDocument();
        expect(document.desktop.last_folder).toBe('/home/someone/photos');
        expect(document.searches.recent).toEqual(['beach']);
        expect(document.gallery.sort).toBe('name');
        expect(document.gallery.row_height).toBe(240);
        expect(document.ui).toEqual({ 'sidebar-collapsed-databases': true });
        expect(document.news.shown_news_ids).toEqual(['a']);
    });
});

describe('addShownNewsIds', () => {
    beforeEach(() => jest.clearAllMocks());

    test('is a no-op for empty input', async () => {
        await addShownNewsIds([]);

        expect(mockWriteYaml).not.toHaveBeenCalled();
    });

    test('appends new ids to the existing list', async () => {
        mockReadYaml.mockResolvedValue({ news: { shown_news_ids: ['a'] } });

        await addShownNewsIds(['b', 'c']);

        expect(writtenDocument().news.shown_news_ids).toEqual(['a', 'b', 'c']);
    });

    test('dedupes ids preserving first-seen order', async () => {
        mockReadYaml.mockResolvedValue({ news: { shown_news_ids: ['a', 'b'] } });

        await addShownNewsIds(['b', 'c', 'a']);

        expect(writtenDocument().news.shown_news_ids).toEqual(['a', 'b', 'c']);
    });

    test('preserves last_shown_update_version when only news ids are added', async () => {
        mockReadYaml.mockResolvedValue({ news: { shown_news_ids: [], last_shown_update_version: '1.2.3' } });

        await addShownNewsIds(['a']);

        expect(writtenDocument().news.last_shown_update_version).toBe('1.2.3');
    });
});

describe('update version persistence', () => {
    beforeEach(() => jest.clearAllMocks());

    test('getLastShownUpdateVersion returns undefined when unset', async () => {
        mockReadYaml.mockResolvedValue({ news: { shown_news_ids: [] } });

        const result = await getLastShownUpdateVersion();

        expect(result).toBeUndefined();
    });

    test('getLastShownUpdateVersion returns the stored version', async () => {
        mockReadYaml.mockResolvedValue({ news: { last_shown_update_version: '1.2.3' } });

        const result = await getLastShownUpdateVersion();

        expect(result).toBe('1.2.3');
    });

    test('setLastShownUpdateVersion overwrites the previous value', async () => {
        mockReadYaml.mockResolvedValue({ news: { last_shown_update_version: '1.2.2' } });

        await setLastShownUpdateVersion('1.2.3');

        expect(writtenDocument().news.last_shown_update_version).toBe('1.2.3');
    });

    test('setLastShownUpdateVersion preserves existing shown news ids', async () => {
        mockReadYaml.mockResolvedValue({ news: { shown_news_ids: ['a', 'b'] } });

        await setLastShownUpdateVersion('1.2.3');

        const document = writtenDocument();
        expect(document.news.shown_news_ids).toEqual(['a', 'b']);
        expect(document.news.last_shown_update_version).toBe('1.2.3');
    });
});

describe('getShownNewsIds', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns the stored list', async () => {
        mockReadYaml.mockResolvedValue({ news: { shown_news_ids: ['a', 'b'] } });

        const result = await getShownNewsIds();

        expect(result).toEqual(['a', 'b']);
    });

    test('returns [] when the file does not exist', async () => {
        mockReadYaml.mockResolvedValue(undefined);

        const result = await getShownNewsIds();

        expect(result).toEqual([]);
    });
});
