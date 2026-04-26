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
        });

        const config = await loadDesktopConfig();

        expect(config.lastFolder).toBe('/folder');
        expect(config.recentSearches).toEqual(['cats']);
        expect(config.lastDownloadFolder).toBe('/downloads');
        expect(config.lastDatabase).toBe('/db');
    });
});

describe('loadDesktopConfig migration', () => {
    beforeEach(() => jest.clearAllMocks());

    test('migrates from JSON when TOML does not exist but JSON does', async () => {
        mockPathExists.mockImplementation((filePath: string) => filePath.endsWith('.json'));
        mockReadJson.mockResolvedValue({ theme: 'dark', lastFolder: '/photos' });

        const config = await loadDesktopConfig();

        expect(config.theme).toBe('dark');
        expect(config.lastFolder).toBe('/photos');
        expect(mockWriteToml).toHaveBeenCalled();
        expect(mockRemove).toHaveBeenCalledWith(expect.stringContaining('desktop.json'));
    });
});

describe('saveDesktopConfig', () => {
    beforeEach(() => jest.clearAllMocks());

    test('writes TOML with snake_case keys', async () => {
        const config = { theme: 'light' as const };

        await saveDesktopConfig(config);

        expect(mockWriteToml).toHaveBeenCalledWith(
            expect.any(String),
            expect.objectContaining({ theme: 'light' })
        );
    });

    test('converts camelCase fields to snake_case in TOML', async () => {
        const config = {
            lastFolder: '/folder',
            recentSearches: ['cats'],
            lastDownloadFolder: '/downloads',
            lastDatabase: '/db',
        };

        await saveDesktopConfig(config);

        const tomlArg = mockWriteToml.mock.calls[0][1];
        expect(tomlArg.last_folder).toBe('/folder');
        expect(tomlArg.recent_searches).toEqual(['cats']);
        expect(tomlArg.last_download_folder).toBe('/downloads');
        expect(tomlArg.last_database).toBe('/db');
        expect(tomlArg.lastFolder).toBeUndefined();
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
