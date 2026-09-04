// Answers homedir() and platform() so these tests can stand on any machine and still ask what every
// platform resolves to. Everything else about `os` is left alone, because the module under test
// reads tmpdir() from it too.
const mockHomedir = jest.fn<string, []>();
const mockPlatform = jest.fn<string, []>();

jest.mock('os', () => ({
    ...jest.requireActual('os'),
    homedir: () => mockHomedir(),
    platform: () => mockPlatform(),
}));

import * as os from 'os';
import * as path from 'path';
import { getCacheDir, getConfigDir } from '../../lib/fs';

//
// A home directory to resolve against. Inside the system temp directory so that a test which does go
// on to touch the filesystem cannot reach anything of the developer's.
//
const TEST_HOME = path.join(os.tmpdir(), 'some-home');

//
// The environment variables these two functions read, put back after every test so one pointing them
// somewhere cannot leak into the next.
//
const STEERING_VARIABLES = ['PHOTOSPHERE_CONFIG_DIR', 'PHOTOSPHERE_CACHE_DIR', 'XDG_CACHE_HOME', 'LOCALAPPDATA'];

describe('the directories Photosphere keeps its own data in', () => {
    let originalValues: Map<string, string | undefined>;

    beforeEach(() => {
        originalValues = new Map<string, string | undefined>();
        for (const name of STEERING_VARIABLES) {
            originalValues.set(name, process.env[name]);
            delete process.env[name];
        }

        mockHomedir.mockReturnValue(TEST_HOME);
        mockPlatform.mockReturnValue('linux');
    });

    afterEach(() => {
        for (const [name, originalValue] of originalValues) {
            if (originalValue === undefined) {
                delete process.env[name];
            }
            else {
                process.env[name] = originalValue;
            }
        }
    });

    describe('getConfigDir', () => {
        test('is .config/photosphere under the home directory on desktop and the CLI', () => {
            expect(getConfigDir()).toBe(path.join(TEST_HOME, '.config', 'photosphere'));
        });

        test('is the same Unix-style path on Windows, so one support answer covers every machine', () => {
            mockPlatform.mockReturnValue('win32');

            expect(getConfigDir()).toBe(path.join(TEST_HOME, '.config', 'photosphere'));
        });

        test('is the storage sandbox root when there is no home directory', () => {
            // A device has no home directory, and the mobile `os` shim says so with an empty string,
            // which is what keeps every derived path inside the app's sandbox.
            mockHomedir.mockReturnValue('');

            expect(getConfigDir()).toBe('.');
        });

        test('uses PHOTOSPHERE_CONFIG_DIR when it is set', () => {
            // This is what the test suites set, so a run cannot reach the developer's real data or
            // another run's.
            process.env.PHOTOSPHERE_CONFIG_DIR = path.join(os.tmpdir(), 'chosen-config');

            expect(getConfigDir()).toBe(path.join(os.tmpdir(), 'chosen-config'));
        });

        test('uses the override on a device too, where there is no home directory to fall back on', () => {
            mockHomedir.mockReturnValue('');
            process.env.PHOTOSPHERE_CONFIG_DIR = path.join(os.tmpdir(), 'chosen-config');

            expect(getConfigDir()).toBe(path.join(os.tmpdir(), 'chosen-config'));
        });
    });

    describe('getCacheDir', () => {
        test('is ~/.cache/photosphere on Linux', () => {
            expect(getCacheDir()).toBe(path.join(TEST_HOME, '.cache', 'photosphere'));
        });

        test('follows XDG_CACHE_HOME on Linux, which is what says where caches go there', () => {
            process.env.XDG_CACHE_HOME = path.join(os.tmpdir(), 'xdg-cache');

            expect(getCacheDir()).toBe(path.join(os.tmpdir(), 'xdg-cache', 'photosphere'));
        });

        test('ignores an XDG_CACHE_HOME that is set but empty, which means the same as unset', () => {
            process.env.XDG_CACHE_HOME = '';

            expect(getCacheDir()).toBe(path.join(TEST_HOME, '.cache', 'photosphere'));
        });

        test('is ~/Library/Caches/photosphere on macOS', () => {
            mockPlatform.mockReturnValue('darwin');

            expect(getCacheDir()).toBe(path.join(TEST_HOME, 'Library', 'Caches', 'photosphere'));
        });

        test('ignores XDG_CACHE_HOME on macOS, which has a location of its own', () => {
            mockPlatform.mockReturnValue('darwin');
            process.env.XDG_CACHE_HOME = path.join(os.tmpdir(), 'xdg-cache');

            expect(getCacheDir()).toBe(path.join(TEST_HOME, 'Library', 'Caches', 'photosphere'));
        });

        test('is under LOCALAPPDATA on Windows', () => {
            // Local rather than Roaming, so a cache does not follow a roaming profile around a
            // network.
            mockPlatform.mockReturnValue('win32');
            process.env.LOCALAPPDATA = path.join(os.tmpdir(), 'AppDataLocal');

            expect(getCacheDir()).toBe(path.join(os.tmpdir(), 'AppDataLocal', 'photosphere', 'cache'));
        });

        test('falls back to AppData/Local on Windows when LOCALAPPDATA is not set', () => {
            mockPlatform.mockReturnValue('win32');

            expect(getCacheDir()).toBe(path.join(TEST_HOME, 'AppData', 'Local', 'photosphere', 'cache'));
        });

        test('is the storage sandbox root when there is no home directory', () => {
            mockHomedir.mockReturnValue('');

            expect(getCacheDir()).toBe('.');
        });

        test('uses PHOTOSPHERE_CACHE_DIR when it is set, on every platform', () => {
            // The test temp allocator sets this for every suite at once, which is what keeps a run
            // off the developer's real hash caches and out of the way of any other run.
            process.env.PHOTOSPHERE_CACHE_DIR = path.join(os.tmpdir(), 'chosen-cache');

            for (const platform of ['linux', 'darwin', 'win32']) {
                mockPlatform.mockReturnValue(platform);
                expect(getCacheDir()).toBe(path.join(os.tmpdir(), 'chosen-cache'));
            }
        });

        test('is not the config directory, because nothing in it is a setting', () => {
            process.env.PHOTOSPHERE_CONFIG_DIR = path.join(os.tmpdir(), 'chosen-config');

            expect(getCacheDir()).not.toBe(getConfigDir());
        });
    });
});
