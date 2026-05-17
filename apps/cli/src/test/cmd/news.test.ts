const mockVersion = { value: '1.2.3' };
jest.mock('config', () => ({
    get version() { return mockVersion.value; },
    buildMetadata: { commitHash: 'dev', buildDate: 'development', isNightly: false },
}));

const mockGetLatestVersion = jest.fn();
const mockMarkUpdateAsShown = jest.fn();
const mockGetAllNews = jest.fn();
const mockMarkNewsAsShown = jest.fn();

jest.mock('../../lib/check-for-updates', () => ({
    getLatestVersion: mockGetLatestVersion,
    markUpdateAsShown: mockMarkUpdateAsShown,
}));

jest.mock('../../lib/check-for-news', () => ({
    getAllNews: mockGetAllNews,
    markNewsAsShown: mockMarkNewsAsShown,
}));

jest.mock('utils', () => ({
    log: {
        info: jest.fn(),
    },
}));

import { newsCommand } from '../../../src/cmd/news';
import { log } from 'utils';

describe('newsCommand', () => {
    beforeEach(() => {
        jest.clearAllMocks();
        mockVersion.value = '1.2.3';
        mockGetLatestVersion.mockResolvedValue(undefined);
        mockGetAllNews.mockResolvedValue([]);
    });

    test('always prints the running version', async () => {
        await newsCommand();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('Running version') && line.includes('v1.2.3'))).toBe(true);
    });

    test('prints "up to date" when the latest version matches the running version', async () => {
        mockGetLatestVersion.mockResolvedValue('1.2.3');

        await newsCommand();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('Latest release') && line.includes('v1.2.3') && line.includes('up to date'))).toBe(true);
        expect(mockMarkUpdateAsShown).not.toHaveBeenCalled();
    });

    test('prints "update available" and records the version when a newer release exists', async () => {
        mockGetLatestVersion.mockResolvedValue('9.9.9');

        await newsCommand();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('Latest release') && line.includes('v9.9.9') && line.includes('update available'))).toBe(true);
        expect(mockMarkUpdateAsShown).toHaveBeenCalledWith('9.9.9');
    });

    test('omits the latest release line when latest version is unknown', async () => {
        mockGetLatestVersion.mockResolvedValue(undefined);

        await newsCommand();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('Latest release'))).toBe(false);
        expect(mockMarkUpdateAsShown).not.toHaveBeenCalled();
    });

    test('prints "No news items available" when the feed is empty', async () => {
        await newsCommand();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('No news items available'))).toBe(true);
        expect(mockMarkNewsAsShown).not.toHaveBeenCalled();
    });

    test('renders both seen and unseen items and marks unseen ones as shown', async () => {
        mockGetAllNews.mockResolvedValue([
            { item: { id: 'a', message: 'older seen item' }, seen: true },
            { item: { id: 'b', message: 'new item' }, seen: false },
        ]);

        await newsCommand();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('older seen item'))).toBe(true);
        expect(calls.some(line => line.includes('new item') && line.includes('(new)'))).toBe(true);
        expect(mockMarkNewsAsShown).toHaveBeenCalledWith(['b']);
    });

    test('renders items newest-first (reverse of feed order)', async () => {
        mockGetAllNews.mockResolvedValue([
            { item: { id: 'a', message: 'oldest' }, seen: true },
            { item: { id: 'b', message: 'middle' }, seen: true },
            { item: { id: 'c', message: 'newest' }, seen: true },
        ]);

        await newsCommand();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        const newestIndex = calls.findIndex(line => line.includes('newest'));
        const oldestIndex = calls.findIndex(line => line.includes('oldest'));
        expect(newestIndex).toBeGreaterThan(-1);
        expect(oldestIndex).toBeGreaterThan(-1);
        expect(newestIndex).toBeLessThan(oldestIndex);
    });

    test('renders link and action lines when present on items', async () => {
        mockGetAllNews.mockResolvedValue([
            {
                item: {
                    id: 'a',
                    message: 'Body',
                    link: { label: 'Docs', url: 'https://example.com/docs' },
                    action: { label: 'Open', url: 'https://example.com/open' },
                },
                seen: false,
            },
        ]);

        await newsCommand();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('Docs') && line.includes('https://example.com/docs'))).toBe(true);
        expect(calls.some(line => line.includes('Open') && line.includes('https://example.com/open'))).toBe(true);
    });

    test('does not call markNewsAsShown when every item is already seen', async () => {
        mockGetAllNews.mockResolvedValue([
            { item: { id: 'a', message: 'a' }, seen: true },
            { item: { id: 'b', message: 'b' }, seen: true },
        ]);

        await newsCommand();

        expect(mockMarkNewsAsShown).toHaveBeenCalledWith([]);
    });
});
