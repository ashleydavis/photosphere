import fs from 'fs';
import os from 'os';
import path from 'path';
import { TestUuidGenerator } from '../../lib/test-uuid-generator';

//
// Creates a unique directory path under the OS temp folder for test isolation.
//
function uniqueTmpDir(): string {
    return path.join(os.tmpdir(), `photosphere-uuid-gen-test-${Date.now()}-${Math.random().toString(36).slice(2)}`);
}

describe('TestUuidGenerator', () => {
    let originalTestTmpDir: string | undefined;

    beforeEach(() => {
        originalTestTmpDir = process.env.TEST_TMP_DIR;
    });

    afterEach(() => {
        if (originalTestTmpDir === undefined) {
            delete process.env.TEST_TMP_DIR;
        }
        else {
            process.env.TEST_TMP_DIR = originalTestTmpDir;
        }
    });

    test('generate() succeeds and creates the counter directory when TEST_TMP_DIR does not exist', () => {
        const tmpDir = uniqueTmpDir();
        expect(fs.existsSync(tmpDir)).toBe(false);

        process.env.TEST_TMP_DIR = tmpDir;
        const generator = new TestUuidGenerator();

        const uuid = generator.generate();

        expect(typeof uuid).toBe('string');
        expect(uuid.length).toBeGreaterThan(0);
        expect(fs.existsSync(tmpDir)).toBe(true);

        generator.reset();
        fs.rmdirSync(tmpDir);
    });

    test('generate() returns unique values on successive calls', () => {
        const tmpDir = uniqueTmpDir();
        process.env.TEST_TMP_DIR = tmpDir;
        const generator = new TestUuidGenerator();

        const first = generator.generate();
        const second = generator.generate();

        expect(first).not.toBe(second);

        generator.reset();
        fs.rmdirSync(tmpDir);
    });
});
