const mockCheckForUpdates = jest.fn();
const mockMarkUpdateAsShown = jest.fn();
const mockCheckForNews = jest.fn();

jest.mock('../../lib/check-for-updates', () => ({
    checkForUpdates: mockCheckForUpdates,
    markUpdateAsShown: mockMarkUpdateAsShown,
}));

jest.mock('../../lib/check-for-news', () => ({
    checkForNews: mockCheckForNews,
}));

jest.mock('utils', () => ({
    log: {
        info: jest.fn(),
    },
}));

import { printNotifications, printNewsItem } from '../../lib/print-notifications';
import { log } from 'utils';

describe('printNotifications', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('prints update line when an update is available', async () => {
        mockCheckForUpdates.mockResolvedValue('1.2.3');
        mockCheckForNews.mockResolvedValue(undefined);

        await printNotifications();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('A new version is available: v1.2.3'))).toBe(true);
    });

    test('records the update version as shown after printing', async () => {
        mockCheckForUpdates.mockResolvedValue('1.2.3');
        mockCheckForNews.mockResolvedValue(undefined);

        await printNotifications();

        expect(mockMarkUpdateAsShown).toHaveBeenCalledWith('1.2.3');
    });

    test('does not record any update when no update is available', async () => {
        mockCheckForUpdates.mockResolvedValue(undefined);
        mockCheckForNews.mockResolvedValue(undefined);

        await printNotifications();

        expect(mockMarkUpdateAsShown).not.toHaveBeenCalled();
    });

    test('omits update line when checkForUpdates returns undefined', async () => {
        mockCheckForUpdates.mockResolvedValue(undefined);
        mockCheckForNews.mockResolvedValue(undefined);

        await printNotifications();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('A new version is available'))).toBe(false);
    });

    test('prints news heading and message when a news item is available', async () => {
        mockCheckForUpdates.mockResolvedValue(undefined);
        mockCheckForNews.mockResolvedValue({ id: 'a', message: 'Hello users' });

        await printNotifications();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('📰 News:'))).toBe(true);
        expect(calls.some(line => line.includes('Hello users'))).toBe(true);
    });

    test('renders link and action when present on the news item', async () => {
        mockCheckForUpdates.mockResolvedValue(undefined);
        mockCheckForNews.mockResolvedValue({
            id: 'a',
            message: 'Hello',
            link: { label: 'Read more', url: 'https://example.com/read' },
            action: { label: 'Try it', url: 'https://example.com/try' },
        });

        await printNotifications();

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('Read more') && line.includes('https://example.com/read'))).toBe(true);
        expect(calls.some(line => line.includes('Try it') && line.includes('https://example.com/try'))).toBe(true);
    });

    test('prints nothing extra when both checks return undefined', async () => {
        mockCheckForUpdates.mockResolvedValue(undefined);
        mockCheckForNews.mockResolvedValue(undefined);

        await printNotifications();

        expect(log.info).not.toHaveBeenCalled();
    });
});

describe('printNewsItem', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('prints message body without link or action sections when neither is set', () => {
        printNewsItem({ id: 'a', message: 'Bare message' });

        const calls = (log.info as jest.Mock).mock.calls.map(callArgs => callArgs[0]);
        expect(calls.some(line => line.includes('📰 News:'))).toBe(true);
        expect(calls.some(line => line.includes('Bare message'))).toBe(true);
    });
});
