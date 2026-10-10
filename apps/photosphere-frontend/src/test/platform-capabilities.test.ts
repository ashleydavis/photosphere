import { bundledToolsStatus, getPlatformCapabilities, type IPlatformInfo } from '../lib/platform-capabilities';

const desktop: IPlatformInfo = { platformKind: 'desktop', os: 'linux', arch: 'x86_64' };
const ios: IPlatformInfo = { platformKind: 'mobile', os: 'ios', arch: 'aarch64' };
const android: IPlatformInfo = { platformKind: 'mobile', os: 'linux', arch: 'aarch64' };

describe('getPlatformCapabilities', () => {
    test('a desktop imports dropped files and reads their paths', () => {
        const capabilities = getPlatformCapabilities(desktop);

        expect(capabilities.supportsDragAndDropImport).toBe(true);
        expect(capabilities.readsDroppedFilePaths).toBe(true);
    });

    test('a phone has no drop', () => {
        const capabilities = getPlatformCapabilities(ios);

        expect(capabilities.supportsDragAndDropImport).toBe(false);
        expect(capabilities.readsDroppedFilePaths).toBe(false);
    });

    test('a desktop describes background import as running while the app is open', () => {
        expect(getPlatformCapabilities(desktop).backgroundImportDescription).toBe("Runs whenever Photosphere is open, importing new photos as they appear.");
    });

    test('iOS describes background import as the system deciding when it runs', () => {
        expect(getPlatformCapabilities(ios).backgroundImportDescription).toBe("When the app is not open, iOS decides when to catch up, usually while the phone is charging.");
    });

    test('Android describes background import as running with the screen off', () => {
        expect(getPlatformCapabilities(android).backgroundImportDescription).toBe("Keeps importing when the app is closed and the screen is off, showing a notification while it does.");
    });

    test('a desktop opens databases and folders with the system, copies images and uses the shell developer tools', () => {
        const capabilities = getPlatformCapabilities(desktop);

        expect(capabilities.opensDatabaseWithDialog).toBe(true);
        expect(capabilities.opensFolders).toBe(true);
        expect(capabilities.copiesImagesToClipboard).toBe(true);
        expect(capabilities.devToolsKind).toBe('shell');
        expect(capabilities.asksCoreForTools).toBe(true);
        expect(capabilities.downloadMethod).toBe('save-dialog');
        expect(capabilities.showsDesktopChrome).toBe(true);
        expect(capabilities.runsBackgroundWork).toBe(false);
    });

    test('a phone opens none of those, uses Eruda, bundles its tools and shares downloads', () => {
        const capabilities = getPlatformCapabilities(android);

        expect(capabilities.opensDatabaseWithDialog).toBe(false);
        expect(capabilities.opensFolders).toBe(false);
        expect(capabilities.copiesImagesToClipboard).toBe(false);
        expect(capabilities.devToolsKind).toBe('eruda');
        expect(capabilities.asksCoreForTools).toBe(false);
        expect(capabilities.downloadMethod).toBe('share-sheet');
        expect(capabilities.showsDesktopChrome).toBe(false);
        expect(capabilities.runsBackgroundWork).toBe(true);
    });

    test('a platform kind the core did not mean to report throws', () => {
        const unknownKind = { platformKind: 'tablet', os: 'linux', arch: 'x86_64' } as any;

        expect(() => getPlatformCapabilities(unknownKind)).toThrow('Unknown platform kind "tablet"');
    });
});

describe('bundledToolsStatus', () => {
    test('reports every tool available', () => {
        expect(bundledToolsStatus()).toEqual({
            magick: { available: true },
            ffprobe: { available: true },
            ffmpeg: { available: true },
            allAvailable: true,
            missingTools: [],
        });
    });
});
