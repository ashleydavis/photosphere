import fs from 'fs';
import os from 'os';
import path from 'path';
import { createTestTempDir, getTestTempRoot } from '../../lib/test-temp-dir';
import { getProcessTmpDir } from '../../lib/fs';

//
// Restores the two environment variables that steer the process temp directory, so a test that
// points them somewhere cannot leak that setting into the tests that follow it.
//
describe('test temp directories', () => {
    let originalTestTmpRoot: string | undefined;
    let originalTestTmpDir: string | undefined;

    beforeEach(() => {
        originalTestTmpRoot = process.env.PHOTOSPHERE_TEST_TMP_ROOT;
        originalTestTmpDir = process.env.TEST_TMP_DIR;
        delete process.env.PHOTOSPHERE_TEST_TMP_ROOT;
        delete process.env.TEST_TMP_DIR;
    });

    afterEach(() => {
        if (originalTestTmpRoot === undefined) {
            delete process.env.PHOTOSPHERE_TEST_TMP_ROOT;
        }
        else {
            process.env.PHOTOSPHERE_TEST_TMP_ROOT = originalTestTmpRoot;
        }
        if (originalTestTmpDir === undefined) {
            delete process.env.TEST_TMP_DIR;
        }
        else {
            process.env.TEST_TMP_DIR = originalTestTmpDir;
        }
    });

    test('createTestTempDir returns a directory that exists inside the test temp root', () => {
        const created = createTestTempDir('exists-check');

        expect(fs.existsSync(created)).toBe(true);
        expect(fs.statSync(created).isDirectory()).toBe(true);
        expect(path.dirname(created)).toBe(getTestTempRoot());
    });

    test('createTestTempDir returns a different directory each time, even for the same label', () => {
        const first = createTestTempDir('same-label');
        const second = createTestTempDir('same-label');

        expect(first).not.toBe(second);
        expect(fs.existsSync(first)).toBe(true);
        expect(fs.existsSync(second)).toBe(true);
    });

    test('createTestTempDir puts the label in the directory name so a stray directory names its test', () => {
        const created = createTestTempDir('9-share-database');

        expect(path.basename(created).startsWith('9-share-database-')).toBe(true);
    });

    test('createTestTempDir replaces path separators in a label rather than following them', () => {
        const created = createTestTempDir('nested/label');

        expect(path.dirname(created)).toBe(getTestTempRoot());
        expect(path.basename(created).startsWith('nested-label-')).toBe(true);
    });

    test('getTestTempRoot is inside the process temp dir and is not the CLI own photosphere directory', () => {
        const testTempRoot = getTestTempRoot();

        expect(path.dirname(testTempRoot)).toBe(getProcessTmpDir());
        expect(testTempRoot).not.toBe(path.join(getProcessTmpDir(), 'photosphere'));
    });

    test('getTestTempRoot follows the process temp dir when a per-test root is set', () => {
        const perTestRoot = path.join(os.tmpdir(), 'photosphere-root-follow-check');
        process.env.PHOTOSPHERE_TEST_TMP_ROOT = perTestRoot;

        expect(getTestTempRoot()).toBe(path.join(perTestRoot, 'tmp', 'photosphere-tests'));
    });

    test('getProcessTmpDir prefers PHOTOSPHERE_TEST_TMP_ROOT over TEST_TMP_DIR', () => {
        process.env.PHOTOSPHERE_TEST_TMP_ROOT = path.join(os.tmpdir(), 'per-test-root');
        process.env.TEST_TMP_DIR = path.join(os.tmpdir(), 'per-suite-dir');

        expect(getProcessTmpDir()).toBe(path.join(os.tmpdir(), 'per-test-root', 'tmp'));
    });

    test('getProcessTmpDir uses TEST_TMP_DIR when only that is set', () => {
        process.env.TEST_TMP_DIR = path.join(os.tmpdir(), 'per-suite-dir');

        expect(getProcessTmpDir()).toBe(path.join(os.tmpdir(), 'per-suite-dir', 'tmp'));
    });

    test('getProcessTmpDir falls back to the system temp dir when neither is set', () => {
        expect(getProcessTmpDir()).toBe(os.tmpdir());
    });
});
