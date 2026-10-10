import { HELP_URL, interpretMenuAction, logDirectoryOf, normalizeRoute } from '../lib/menu-actions';

describe('interpretMenuAction', () => {
    test('navigate actions go to their route', () => {
        expect(interpretMenuAction('navigate:/gallery')).toEqual({ kind: 'navigate', page: '/gallery' });
        expect(interpretMenuAction('navigate:/database-summary')).toEqual({ kind: 'navigate', page: '/database-summary' });
    });

    test('a navigate route with no leading slash is given one', () => {
        expect(interpretMenuAction('navigate:map')).toEqual({ kind: 'navigate', page: '/map' });
    });

    test('a navigate action with no route throws', () => {
        expect(() => interpretMenuAction('navigate:')).toThrow('names no route');
    });

    test('about goes to the about page', () => {
        expect(interpretMenuAction('about')).toEqual({ kind: 'navigate', page: '/about' });
    });

    test('theme actions set the theme', () => {
        expect(interpretMenuAction('theme:light')).toEqual({ kind: 'set-theme', theme: 'light' });
        expect(interpretMenuAction('theme:dark')).toEqual({ kind: 'set-theme', theme: 'dark' });
        expect(interpretMenuAction('theme:system')).toEqual({ kind: 'set-theme', theme: 'system' });
    });

    test('a theme that does not exist throws', () => {
        expect(() => interpretMenuAction('theme:purple')).toThrow('not light, dark or system');
        expect(() => interpretMenuAction('theme:')).toThrow('not light, dark or system');
    });

    test('open-log-directory shows the log folder', () => {
        expect(interpretMenuAction('open-log-directory')).toEqual({ kind: 'open-log-directory' });
    });

    test('help opens the wiki in the system browser', () => {
        expect(interpretMenuAction('help')).toEqual({ kind: 'open-url', url: 'https://github.com/ashleydavis/photosphere/wiki' });
        expect(HELP_URL).toBe('https://github.com/ashleydavis/photosphere/wiki');
    });

    test('close-database closes the database', () => {
        expect(interpretMenuAction('close-database')).toEqual({ kind: 'close-database' });
    });

    test('every other action is passed on as a platform event', () => {
        for (const action of ['new-database', 'add-database', 'open-database', 'import-assets', 'open-configuration', 'report-bug']) {
            expect(interpretMenuAction(action)).toEqual({ kind: 'platform-event', action });
        }
    });
});

describe('normalizeRoute', () => {
    test('keeps a route that has its slash and adds one that is missing', () => {
        expect(normalizeRoute('/gallery')).toBe('/gallery');
        expect(normalizeRoute('gallery')).toBe('/gallery');
    });
});

describe('logDirectoryOf', () => {
    test('gives the folder of a log file on Linux and MacOS', () => {
        expect(logDirectoryOf('/home/user/.local/share/photosphere/logs/photosphere.log')).toBe('/home/user/.local/share/photosphere/logs');
    });

    test('gives the folder of a log file on Windows', () => {
        expect(logDirectoryOf('C:\\Users\\user\\AppData\\photosphere\\logs\\photosphere.log')).toBe('C:\\Users\\user\\AppData\\photosphere\\logs');
    });

    test('gives the root for a file directly under it', () => {
        expect(logDirectoryOf('/photosphere.log')).toBe('/');
    });

    test('throws when file logging is not active', () => {
        expect(() => logDirectoryOf(null)).toThrow('file logging is not active');
    });

    test('throws for a path with no folder', () => {
        expect(() => logDirectoryOf('photosphere.log')).toThrow('has no folder');
    });
});
