import * as fs from 'fs/promises';
import { createReadStream } from 'fs';
import * as path from 'path';
import { Readable } from 'stream';
import { FileStorage } from '../lib/file-storage';
import { remove, createTestTempDir } from 'node-utils';

//
// Writing a stream to storage, when that stream is reading a file and when it is not.
//
// A stream that carries the path of the file it is reading is copied file to file rather than piped
// through. That matters most on a phone, where every byte piped through the fs shims crosses the
// engine bridge as a base64 string built inside the JS engine: importing a photo built one such
// string to read it and another to write it, to accomplish a copy the platform can do without moving
// anything into the engine. Both paths have to produce identical bytes, because one of them is used
// for every photo taken into a database and the other for everything that is transformed on its way
// in, such as an encrypted write.
//
//
// Note on what these do NOT cover: they cannot tell which of the two paths ran, because both produce
// identical bytes, which is the point of them. That the copy path is taken at all, and that it is
// worth taking, is proven by the device measurement in
// `docs/performance/mobile-import-leaderboard.md`, where it shows up as the upload stage falling.
//
describe('FileStorage writeStream', () => {
    let tempDir: string;
    let storage: FileStorage;

    beforeEach(async () => {
        tempDir = createTestTempDir('temp-test-write-stream');
        storage = new FileStorage(tempDir);
    });

    afterEach(async () => {
        await remove(tempDir);
    });

    test('a file-backed stream is written byte for byte', async () => {
        const contents = Buffer.alloc(3 * 1024 * 1024);
        for (let index = 0; index < contents.length; index++) {
            contents[index] = index % 251;
        }

        const sourcePath = path.join(tempDir, 'source.bin');
        await fs.writeFile(sourcePath, contents);

        await storage.writeStream(path.join(tempDir, 'copied.bin'), 'application/octet-stream', createReadStream(sourcePath));

        const written = await fs.readFile(path.join(tempDir, 'copied.bin'));
        expect(written.equals(contents)).toBe(true);
    });

    test('a stream with no path behind it is still piped through', async () => {
        // An encrypting stream is one of these: it carries no path, because what it produces is not
        // any file on disk. Taking the copy path for it would write the wrong bytes.
        const contents = Buffer.from('not backed by any file', 'utf8');

        await storage.writeStream(path.join(tempDir, 'piped.bin'), 'application/octet-stream', Readable.from([contents]));

        const written = await fs.readFile(path.join(tempDir, 'piped.bin'));
        expect(written.equals(contents)).toBe(true);
    });

    test('an empty file-backed stream produces an empty file, not a missing one', async () => {
        const sourcePath = path.join(tempDir, 'empty-source.bin');
        await fs.writeFile(sourcePath, Buffer.alloc(0));

        await storage.writeStream(path.join(tempDir, 'empty-copy.bin'), 'application/octet-stream', createReadStream(sourcePath));

        const written = await fs.readFile(path.join(tempDir, 'empty-copy.bin'));
        expect(written.length).toBe(0);
    });
});
