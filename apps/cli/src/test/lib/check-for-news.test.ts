const mockFetchNews = jest.fn();
const mockGetShownNewsIds = jest.fn();
const mockAddShownNewsIds = jest.fn();

jest.mock('node-api', () => ({
    fetchNews: mockFetchNews,
    getShownNewsIds: mockGetShownNewsIds,
    addShownNewsIds: mockAddShownNewsIds,
}));

import { checkForNews, getAllNews, markNewsAsShown } from '../../lib/check-for-news';

describe('checkForNews', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('returns oldest unseen item and marks it shown', async () => {
        mockFetchNews.mockResolvedValue([
            { id: 'a', message: 'first' },
            { id: 'b', message: 'second' },
        ]);
        mockGetShownNewsIds.mockResolvedValue([]);

        const result = await checkForNews();

        expect(result).toEqual({ id: 'a', message: 'first' });
        expect(mockAddShownNewsIds).toHaveBeenCalledWith(['a']);
    });

    test('skips items already in the shown set', async () => {
        mockFetchNews.mockResolvedValue([
            { id: 'a', message: 'first' },
            { id: 'b', message: 'second' },
        ]);
        mockGetShownNewsIds.mockResolvedValue(['a']);

        const result = await checkForNews();

        expect(result).toEqual({ id: 'b', message: 'second' });
        expect(mockAddShownNewsIds).toHaveBeenCalledWith(['b']);
    });

    test('returns undefined when there are no unseen items', async () => {
        mockFetchNews.mockResolvedValue([
            { id: 'a', message: 'first' },
        ]);
        mockGetShownNewsIds.mockResolvedValue(['a']);

        const result = await checkForNews();

        expect(result).toBeUndefined();
        expect(mockAddShownNewsIds).not.toHaveBeenCalled();
    });

    test('returns undefined when the feed is empty', async () => {
        mockFetchNews.mockResolvedValue([]);
        mockGetShownNewsIds.mockResolvedValue([]);

        const result = await checkForNews();

        expect(result).toBeUndefined();
        expect(mockAddShownNewsIds).not.toHaveBeenCalled();
    });

    test('returns undefined and swallows errors when fetchNews throws', async () => {
        mockFetchNews.mockRejectedValue(new Error('network'));
        mockGetShownNewsIds.mockResolvedValue([]);

        const result = await checkForNews();

        expect(result).toBeUndefined();
        expect(mockAddShownNewsIds).not.toHaveBeenCalled();
    });

});

describe('getAllNews', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('returns all items with seen state derived from shown ids', async () => {
        mockFetchNews.mockResolvedValue([
            { id: 'a', message: 'first' },
            { id: 'b', message: 'second' },
            { id: 'c', message: 'third' },
        ]);
        mockGetShownNewsIds.mockResolvedValue(['a', 'c']);

        const result = await getAllNews();

        expect(result).toEqual([
            { item: { id: 'a', message: 'first' }, seen: true },
            { item: { id: 'b', message: 'second' }, seen: false },
            { item: { id: 'c', message: 'third' }, seen: true },
        ]);
    });

    test('does not mark anything as shown', async () => {
        mockFetchNews.mockResolvedValue([{ id: 'a', message: 'first' }]);
        mockGetShownNewsIds.mockResolvedValue([]);

        await getAllNews();

        expect(mockAddShownNewsIds).not.toHaveBeenCalled();
    });

    test('returns empty array on fetch failure', async () => {
        mockFetchNews.mockRejectedValue(new Error('network'));
        mockGetShownNewsIds.mockResolvedValue([]);

        const result = await getAllNews();

        expect(result).toEqual([]);
    });
});

describe('markNewsAsShown', () => {
    beforeEach(() => {
        jest.clearAllMocks();
    });

    test('records the supplied ids', async () => {
        await markNewsAsShown(['a', 'b']);

        expect(mockAddShownNewsIds).toHaveBeenCalledWith(['a', 'b']);
    });

    test('is a no-op when given an empty array', async () => {
        await markNewsAsShown([]);

        expect(mockAddShownNewsIds).not.toHaveBeenCalled();
    });

    test('swallows persistence errors', async () => {
        mockAddShownNewsIds.mockRejectedValue(new Error('disk full'));

        await expect(markNewsAsShown(['a'])).resolves.toBeUndefined();
    });
});
