import * as fs from 'fs/promises';
import * as path from 'path';
import { Readable } from 'stream';
import { FileStorage } from '../lib/file-storage';
import { remove, createTestTempDir } from 'node-utils';

//
// Two writes to one path, in flight at once.
//
// A write is staged in a temporary file and renamed over the destination. When that temporary file
// was named after the destination alone, both writes used the same one: each opened it, each wrote
// into it, and whichever renamed first took it away from the other. The loser then failed, with
// ENOENT here and with EPERM on Windows, where the file is still open by the other writer. That is
// what stopped `psi add` writing its index into a local encrypted database on Windows, and the
// failure was swallowed, so the command reported "Added 1 files" and the database held none.
//
describe('FileStorage concurrent writes to one path', () => {
    let tempDir: string;
    let storage: FileStorage;
    let target: string;

    beforeEach(async () => {
        tempDir = createTestTempDir('temp-test-concurrent-write');
        storage = new FileStorage(tempDir);
        target = path.join(tempDir, 'files.dat');
    });

    afterEach(async () => {
        await remove(tempDir);
    });

    //
    // Large enough that the two writes genuinely overlap rather than each completing within a tick.
    //
    const alpha = Buffer.alloc(2 * 1024 * 1024, 'A');
    const beta = Buffer.alloc(2 * 1024 * 1024, 'B');

    test('both writes complete and the file holds one writer\'s content in full', async () => {
        await Promise.all([
            storage.write(target, undefined, alpha),
            storage.write(target, undefined, beta),
        ]);

        const written = await fs.readFile(target);
        expect(written.length).toBe(alpha.length);

        // Whichever won, every byte must come from that one write. A mixture means the two shared a
        // staging file.
        const distinctBytes = new Set(written);
        expect(distinctBytes.size).toBe(1);
    });

    test('both stream writes complete and the file holds one writer\'s content in full', async () => {
        await Promise.all([
            storage.writeStream(target, undefined, Readable.from([alpha])),
            storage.writeStream(target, undefined, Readable.from([beta])),
        ]);

        const written = await fs.readFile(target);
        expect(written.length).toBe(alpha.length);

        const distinctBytes = new Set(written);
        expect(distinctBytes.size).toBe(1);
    });

    test('no staging files are left behind', async () => {
        await Promise.all([
            storage.write(target, undefined, alpha),
            storage.write(target, undefined, beta),
        ]);

        const remaining = await fs.readdir(tempDir);
        expect(remaining.filter(name => name.endsWith('.tmp'))).toEqual([]);
    });
});
