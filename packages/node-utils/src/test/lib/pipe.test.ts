import * as fs from 'fs';
import * as path from 'path';
import { createReadStream } from 'fs';
import { Transform } from 'stream';
import { pipe } from '../../lib/pipe';
import * as os from 'os';

//
// Counts how many of this process's open descriptors point at one file, read from /proc. Linux only,
// which is where these tests run.
//
function openHandleCount(filePath: string): number {
    let count = 0;
    for (const entry of fs.readdirSync('/proc/self/fd')) {
        try {
            if (fs.readlinkSync(path.join('/proc/self/fd', entry)) === filePath) {
                count++;
            }
        }
        catch {
            // The descriptor closed while being read, so it is not the one being counted.
        }
    }
    return count;
}

//
// Gives pending stream teardown a chance to run before the handles are counted.
//
function settle(): Promise<void> {
    return new Promise(resolve => setTimeout(resolve, 150));
}

//
// A consumer that stops consuming and is then thrown away must not leave the source open.
//
// This is the situation EncryptedStorage.readStream creates. It pipes the file into a decryption
// stream and returns only the decryption stream, so that is the sole handle the caller holds.
// loadVersion in the serialization package takes a four byte header from it and destroys it, and it
// does that against .db/files.dat, which save() wrote through the whole-buffer encryptor rather than
// the stream one, so the decryption stream stalls rather than completing.
//
// Destroying the consumer emits `close`, not `error`, and Node's pipe does not carry destruction
// back upstream. The file was left open with nothing reading it. On Linux that costs a descriptor.
// On Windows an open handle stops the file being renamed over, which failed the write that replaces
// the database index during `psi add`, and the error was swallowed so the command reported success
// over an empty database. That is Windows smoke tests 49 and 50.
//
describe('pipe', () => {
    let tempDir: string;
    let sourceFile: string;

    beforeEach(() => {
        tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'photosphere-tests-pipe-'));
        sourceFile = path.join(tempDir, 'source.dat');
        // Bigger than the read stream's buffer, so the source is still holding the file open when
        // the consumer is abandoned rather than having already run to the end and closed itself.
        fs.writeFileSync(sourceFile, Buffer.alloc(8 * 1024 * 1024, 'x'));
    });

    afterEach(() => {
        fs.rmSync(tempDir, { recursive: true, force: true });
    });

    //
    // Stands in for the decryption stream when it is handed bytes it cannot decrypt: it accepts the
    // first chunk and then never completes another, so the pipeline stalls with the file open.
    //
    function stalledConsumer(onFirstChunk: () => void): Transform {
        let seenFirst = false;
        return new Transform({
            transform(chunk, encoding, callback) {
                if (!seenFirst) {
                    seenFirst = true;
                    onFirstChunk();
                }
                // Never calls back, so nothing downstream ever completes.
            },
        });
    }

    test('destroying a stalled consumer closes the source file', async () => {
        const source = createReadStream(sourceFile);
        let destination: Transform;
        await new Promise<void>(resolve => {
            destination = stalledConsumer(() => resolve());
            pipe(source, destination);
        });

        expect(openHandleCount(sourceFile)).toBe(1);
        destination!.destroy();

        await settle();
        expect(openHandleCount(sourceFile)).toBe(0);
    });

    test('an error on the consumer closes the source file', async () => {
        const source = createReadStream(sourceFile);
        let destination: Transform;
        await new Promise<void>(resolve => {
            destination = stalledConsumer(() => resolve());
            pipe(source, destination);
        });

        destination!.on('error', () => {});
        destination!.destroy(new Error('consumer gave up'));

        await settle();
        expect(openHandleCount(sourceFile)).toBe(0);
    });
});
