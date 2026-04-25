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
    getConfigPath,
    loadDesktopConfig,
    saveDesktopConfig,
    updateLastFolder,
    getTheme,
    setTheme,
    updateLastDownloadFolder,
    getRecentSearches,
    addRecentSearch,
    removeRecentSearch,
} from '../../lib/desktop-config';

describe('getConfigPath', () => {
    test('returns a string ending with desktop.json', () => {
        const result = getConfigPath();

        expect(typeof result).toBe('string');
        expect(result).toMatch(/desktop\.json$/);
    });
});

describe('loadDesktopConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns {} when file does not exist', async () => {
        mockPathExists.mockResolvedValue(false);

        const config = await loadDesktopConfig();

        expect(config).toEqual({});
        expect(mockReadJson).not.toHaveBeenCalled();
    });

    test('returns config from disk when file exists', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ theme: 'dark', lastFolder: '/photos' });

        const config = await loadDesktopConfig();

        expect(config.theme).toBe('dark');
        expect(config.lastFolder).toBe('/photos');
    });
});

describe('saveDesktopConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes config JSON', async () => {
        const config = { theme: 'light' as const };

        await saveDesktopConfig(config);

        expect(mockWriteJson).toHaveBeenCalledWith(
            expect.any(String),
            config,
            { spaces: 2 }
        );
    });
});

describe('updateLastFolder', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets lastFolder and saves', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({});

        await updateLastFolder('/new/folder');

        expect(mockWriteJson).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ lastFolder: '/new/folder' }),
            { spaces: 2 }
        );
    });
});

describe('getTheme', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns system when theme is unset', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({});

        const result = await getTheme();

        expect(result).toBe('system');
    });

    test('returns stored value', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ theme: 'dark' });

        const result = await getTheme();

        expect(result).toBe('dark');
    });
});

describe('setTheme', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets theme and saves', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({});

        await setTheme('light');

        expect(mockWriteJson).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ theme: 'light' }),
            { spaces: 2 }
        );
    });
});

describe('updateLastDownloadFolder', () => {
    beforeEach(() => jest.clearAllMocks());

    test('sets lastDownloadFolder and saves', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({});

        await updateLastDownloadFolder('/downloads');

        expect(mockWriteJson).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ lastDownloadFolder: '/downloads' }),
            { spaces: 2 }
        );
    });
});

describe('getRecentSearches', () => {
    beforeEach(() => jest.clearAllMocks());

    test('returns [] when recentSearches is unset', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({});

        const result = await getRecentSearches();

        expect(result).toEqual([]);
    });

    test('returns stored list', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ recentSearches: ['cats', 'dogs'] });

        const result = await getRecentSearches();

        expect(result).toEqual(['cats', 'dogs']);
    });
});

describe('addRecentSearch', () => {
    beforeEach(() => jest.clearAllMocks());

    test('deduplicates and prepends', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ recentSearches: ['cats', 'dogs'] });

        await addRecentSearch('cats');

        const written = mockWriteJson.mock.calls[0][1];
        expect(written.recentSearches).toEqual(['cats', 'dogs']);
    });

    test('prepends new search at front', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ recentSearches: ['cats'] });

        await addRecentSearch('dogs');

        const written = mockWriteJson.mock.calls[0][1];
        expect(written.recentSearches[0]).toBe('dogs');
    });

    test('caps list at 10 entries', async () => {
        const existing = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10'];
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ recentSearches: existing });

        await addRecentSearch('new');

        const written = mockWriteJson.mock.calls[0][1];
        expect(written.recentSearches).toHaveLength(10);
        expect(written.recentSearches[0]).toBe('new');
    });
});

describe('removeRecentSearch', () => {
    beforeEach(() => jest.clearAllMocks());

    test('filters out given search', async () => {
        mockPathExists.mockResolvedValue(true);
        mockReadJson.mockResolvedValue({ recentSearches: ['cats', 'dogs', 'birds'] });

        await removeRecentSearch('dogs');

        const written = mockWriteJson.mock.calls[0][1];
        expect(written.recentSearches).toEqual(['cats', 'birds']);
    });
});
