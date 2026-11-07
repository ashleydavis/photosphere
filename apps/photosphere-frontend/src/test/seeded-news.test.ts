import { firstSeededNewsNotification } from '../lib/seeded-news';

describe('firstSeededNewsNotification', () => {
    test('is undefined when nothing was seeded', () => {
        expect(firstSeededNewsNotification([])).toBeUndefined();
    });

    test('shows the first item as a toast that stays until dismissed, in the primary colour by default', () => {
        const notification = firstSeededNewsNotification([
            { id: 'news-1', message: 'First' },
            { id: 'news-2', message: 'Second' },
        ]);

        expect(notification).toEqual({ message: 'First', color: 'primary', duration: 0, newsId: 'news-1' });
    });

    test('uses the colour the item names', () => {
        const notification = firstSeededNewsNotification([{ id: 'news-1', message: 'Careful', color: 'warning' }]);

        expect(notification?.color).toBe('warning');
    });

    test('throws for a colour a toast does not have', () => {
        expect(() => firstSeededNewsNotification([{ id: 'news-1', message: 'x', color: 'pink' }])).toThrow('"pink"');
    });
});
