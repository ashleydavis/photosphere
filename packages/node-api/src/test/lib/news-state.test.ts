// Mock fs/promises so tests don't touch the real filesystem.
const mockReadFile = jest.fn();
const mockWriteFile = jest.fn();
const mockMkdir = jest.fn();

jest.mock('fs/promises', () => ({
    readFile: mockReadFile,
    writeFile: mockWriteFile,
    mkdir: mockMkdir,
}));

import yaml from 'js-yaml';
import {
    getNewsStatePath,
    loadNewsState,
    saveNewsState,
    getShownNewsIds,
    addShownNewsIds,
    getLastShownUpdateVersion,
    setLastShownUpdateVersion,
} from '../../lib/news-state';

describe('getNewsStatePath', () => {
    test('returns a string ending with news.yaml', () => {
        const result = getNewsStatePath();

        expect(typeof result).toBe('string');
        expect(result.endsWith('news.yaml')).toBe(true);
    });
});

describe('loadNewsState', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns empty state when the file does not exist', async () => {
        mockReadFile.mockRejectedValue(Object.assign(new Error('ENOENT'), { code: 'ENOENT' }));

        const state = await loadNewsState();

        expect(state).toEqual({ shownNewsIds: [] });
    });

    test('returns empty state on YAML parse error', async () => {
        mockReadFile.mockResolvedValue(':::not yaml:::');

        const state = await loadNewsState();

        expect(state.shownNewsIds).toEqual([]);
    });

    test('parses shown_news_ids from YAML', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ shown_news_ids: ['a', 'b'] }));

        const state = await loadNewsState();

        expect(state.shownNewsIds).toEqual(['a', 'b']);
        expect(state.lastShownUpdateVersion).toBeUndefined();
    });

    test('parses last_shown_update_version from YAML', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ shown_news_ids: [], last_shown_update_version: '1.2.3' }));

        const state = await loadNewsState();

        expect(state.lastShownUpdateVersion).toBe('1.2.3');
    });

    test('omits last_shown_update_version when empty string', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ last_shown_update_version: '' }));

        const state = await loadNewsState();

        expect(state.lastShownUpdateVersion).toBeUndefined();
    });
});

describe('saveNewsState', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes shown_news_ids in snake_case yaml form', async () => {
        await saveNewsState({ shownNewsIds: ['a', 'b'] });

        const writtenPath = mockWriteFile.mock.calls[0][0];
        const writtenYaml = yaml.load(mockWriteFile.mock.calls[0][1] as string) as Record<string, unknown>;
        expect(writtenPath.endsWith('news.yaml')).toBe(true);
        expect(writtenYaml.shown_news_ids).toEqual(['a', 'b']);
        expect(writtenYaml.last_shown_update_version).toBeUndefined();
    });

    test('writes last_shown_update_version when set', async () => {
        await saveNewsState({ shownNewsIds: [], lastShownUpdateVersion: '1.2.3' });

        const writtenYaml = yaml.load(mockWriteFile.mock.calls[0][1] as string) as Record<string, unknown>;
        expect(writtenYaml.last_shown_update_version).toBe('1.2.3');
    });

    test('creates the config directory before writing', async () => {
        await saveNewsState({ shownNewsIds: [] });

        expect(mockMkdir).toHaveBeenCalled();
    });
});

describe('addShownNewsIds', () => {
    beforeEach(() => jest.clearAllMocks());

    test('is a no-op for empty input', async () => {
        await addShownNewsIds([]);

        expect(mockWriteFile).not.toHaveBeenCalled();
    });

    test('appends new ids to the existing list', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ shown_news_ids: ['a'] }));

        await addShownNewsIds(['b', 'c']);

        const writtenYaml = yaml.load(mockWriteFile.mock.calls[0][1] as string) as Record<string, unknown>;
        expect(writtenYaml.shown_news_ids).toEqual(['a', 'b', 'c']);
    });

    test('dedupes ids preserving first-seen order', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ shown_news_ids: ['a', 'b'] }));

        await addShownNewsIds(['b', 'c', 'a']);

        const writtenYaml = yaml.load(mockWriteFile.mock.calls[0][1] as string) as Record<string, unknown>;
        expect(writtenYaml.shown_news_ids).toEqual(['a', 'b', 'c']);
    });

    test('preserves last_shown_update_version when only news ids are added', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ shown_news_ids: [], last_shown_update_version: '1.2.3' }));

        await addShownNewsIds(['a']);

        const writtenYaml = yaml.load(mockWriteFile.mock.calls[0][1] as string) as Record<string, unknown>;
        expect(writtenYaml.last_shown_update_version).toBe('1.2.3');
    });
});

describe('update version persistence', () => {
    beforeEach(() => jest.clearAllMocks());

    test('getLastShownUpdateVersion returns undefined when unset', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ shown_news_ids: [] }));

        const result = await getLastShownUpdateVersion();

        expect(result).toBeUndefined();
    });

    test('getLastShownUpdateVersion returns the stored version', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ last_shown_update_version: '1.2.3' }));

        const result = await getLastShownUpdateVersion();

        expect(result).toBe('1.2.3');
    });

    test('setLastShownUpdateVersion overwrites the previous value', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ last_shown_update_version: '1.2.2' }));

        await setLastShownUpdateVersion('1.2.3');

        const writtenYaml = yaml.load(mockWriteFile.mock.calls[0][1] as string) as Record<string, unknown>;
        expect(writtenYaml.last_shown_update_version).toBe('1.2.3');
    });

    test('setLastShownUpdateVersion preserves existing shown news ids', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ shown_news_ids: ['a', 'b'] }));

        await setLastShownUpdateVersion('1.2.3');

        const writtenYaml = yaml.load(mockWriteFile.mock.calls[0][1] as string) as Record<string, unknown>;
        expect(writtenYaml.shown_news_ids).toEqual(['a', 'b']);
        expect(writtenYaml.last_shown_update_version).toBe('1.2.3');
    });
});

describe('getShownNewsIds', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns the stored list', async () => {
        mockReadFile.mockResolvedValue(yaml.dump({ shown_news_ids: ['a', 'b'] }));

        const result = await getShownNewsIds();

        expect(result).toEqual(['a', 'b']);
    });

    test('returns [] when the file does not exist', async () => {
        mockReadFile.mockRejectedValue(Object.assign(new Error('ENOENT'), { code: 'ENOENT' }));

        const result = await getShownNewsIds();

        expect(result).toEqual([]);
    });
});
