import { resolveDroppedFilePath, type IDroppedFile } from '../lib/dropped-file-path';
import { getPlatformCapabilities } from '../lib/platform-capabilities';

const desktop = getPlatformCapabilities({ platformKind: 'desktop', os: 'linux', arch: 'x86_64' });
const mobile = getPlatformCapabilities({ platformKind: 'mobile', os: 'ios', arch: 'aarch64' });

function fileWith(testPath: string | undefined): IDroppedFile {
    const file = new File([], 'photo.jpg') as IDroppedFile;
    file.__testPath = testPath;
    return file;
}

describe('resolveDroppedFilePath', () => {
    test('in test mode the path the test attached wins', () => {
        const path = resolveDroppedFilePath(fileWith('/tests/photo.jpg'), true, desktop, () => '/real/photo.jpg');

        expect(path).toBe('/tests/photo.jpg');
    });

    test('outside test mode the attached path is ignored and the bridge is asked', () => {
        const path = resolveDroppedFilePath(fileWith('/tests/photo.jpg'), false, desktop, () => '/real/photo.jpg');

        expect(path).toBe('/real/photo.jpg');
    });

    test('in test mode a file with no attached path is asked of the bridge', () => {
        const path = resolveDroppedFilePath(fileWith(undefined), true, desktop, () => '/real/photo.jpg');

        expect(path).toBe('/real/photo.jpg');
    });

    test('a file the bridge has no path for has none', () => {
        const path = resolveDroppedFilePath(fileWith(undefined), false, desktop, () => undefined);

        expect(path).toBeUndefined();
    });

    test('a phone never asks the bridge', () => {
        let asked = false;
        const path = resolveDroppedFilePath(fileWith(undefined), false, mobile, () => {
            asked = true;
            return '/real/photo.jpg';
        });

        expect(path).toBeUndefined();
        expect(asked).toBe(false);
    });
});
