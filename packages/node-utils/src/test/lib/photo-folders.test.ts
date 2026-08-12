import * as fsSync from 'fs';
import * as path from 'path';
import {
    filterExistingFolders,
    getDefaultPhotoFolders,
    getPhotoFolderCandidates,
    parseXdgPicturesDir,
    readXdgPicturesDir,
} from '../../lib/photo-folders';
import { createTestTempDir } from '../../lib/test-temp-dir';

describe('photo-folders', () => {

    describe('getPhotoFolderCandidates', () => {

        test('Windows offers Pictures and Camera Roll', () => {
            const candidates = getPhotoFolderCandidates('win32', path.join('C:', 'Users', 'someone'), undefined);
            expect(candidates).toEqual([
                path.join('C:', 'Users', 'someone', 'Pictures'),
                path.join('C:', 'Users', 'someone', 'Pictures', 'Camera Roll'),
            ]);
        });

        test('macOS offers Pictures only', () => {
            const candidates = getPhotoFolderCandidates('darwin', '/Users/someone', undefined);
            expect(candidates).toEqual([path.join('/Users/someone', 'Pictures')]);
        });

        test('Linux uses the XDG pictures directory when there is one', () => {
            const candidates = getPhotoFolderCandidates('linux', '/home/someone', '/home/someone/Bilder');
            expect(candidates).toEqual(['/home/someone/Bilder']);
        });

        test('Linux falls back to Pictures under the home directory', () => {
            const candidates = getPhotoFolderCandidates('linux', '/home/someone', undefined);
            expect(candidates).toEqual([path.join('/home/someone', 'Pictures')]);
        });

        test('a duplicate candidate appears once', () => {
            const candidates = getPhotoFolderCandidates('linux', '/home/someone', path.join('/home/someone', 'Pictures'));
            expect(candidates).toEqual([path.join('/home/someone', 'Pictures')]);
        });
    });

    describe('parseXdgPicturesDir', () => {

        test('expands $HOME in the value', () => {
            const contents = 'XDG_DESKTOP_DIR="$HOME/Desktop"\nXDG_PICTURES_DIR="$HOME/Bilder"\n';
            expect(parseXdgPicturesDir(contents, '/home/someone')).toBe(path.join('/home/someone', 'Bilder'));
        });

        test('accepts an absolute value', () => {
            expect(parseXdgPicturesDir('XDG_PICTURES_DIR="/mnt/photos"\n', '/home/someone')).toBe('/mnt/photos');
        });

        test('accepts the home directory itself', () => {
            expect(parseXdgPicturesDir('XDG_PICTURES_DIR="$HOME"\n', '/home/someone')).toBe('/home/someone');
        });

        test('ignores comments and other keys', () => {
            const contents = '# XDG_PICTURES_DIR="$HOME/Wrong"\nXDG_VIDEOS_DIR="$HOME/Videos"\n';
            expect(parseXdgPicturesDir(contents, '/home/someone')).toBeUndefined();
        });

        test('an empty value is not a directory', () => {
            expect(parseXdgPicturesDir('XDG_PICTURES_DIR=""\n', '/home/someone')).toBeUndefined();
        });

        test('an empty file names nothing', () => {
            expect(parseXdgPicturesDir('', '/home/someone')).toBeUndefined();
        });
    });

    describe('readXdgPicturesDir', () => {

        test('reads the pictures directory from the user-dirs file', () => {
            const homeDir = createTestTempDir('photo-folders-xdg');
            fsSync.mkdirSync(path.join(homeDir, '.config'), { recursive: true });
            fsSync.writeFileSync(path.join(homeDir, '.config', 'user-dirs.dirs'), 'XDG_PICTURES_DIR="$HOME/Bilder"\n');

            expect(readXdgPicturesDir(homeDir)).toBe(path.join(homeDir, 'Bilder'));
        });

        test('returns undefined rather than throwing when there is no user-dirs file', () => {
            const homeDir = createTestTempDir('photo-folders-no-xdg');
            expect(readXdgPicturesDir(homeDir)).toBeUndefined();
        });
    });

    describe('filterExistingFolders', () => {

        test('keeps only folders that exist', () => {
            const tempDir = createTestTempDir('photo-folders-filter');
            const presentDir = path.join(tempDir, 'Pictures');
            const absentDir = path.join(tempDir, 'Nowhere');
            fsSync.mkdirSync(presentDir);

            expect(filterExistingFolders([presentDir, absentDir])).toEqual([presentDir]);
        });

        test('a file is not a folder', () => {
            const tempDir = createTestTempDir('photo-folders-file');
            const filePath = path.join(tempDir, 'Pictures');
            fsSync.writeFileSync(filePath, 'not a directory');

            expect(filterExistingFolders([filePath])).toEqual([]);
        });

        test('returns an empty list rather than throwing when none exist', () => {
            expect(filterExistingFolders(['/definitely/not/here', '/nor/here'])).toEqual([]);
        });
    });

    describe('getDefaultPhotoFolders', () => {

        test('returns only folders that exist on this machine', () => {
            const folders = getDefaultPhotoFolders();
            for (const folder of folders) {
                expect(fsSync.statSync(folder).isDirectory()).toBe(true);
            }
        });
    });
});
