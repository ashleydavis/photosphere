import { Readable, Writable, PassThrough } from "stream";
import { pipe } from "./pipe";

describe('pipe', () => {

    test('pipes data from source to destination', (done) => {
        const source = Readable.from(['hello', ' ', 'world']);
        const dest = new PassThrough();
        const chunks: Buffer[] = [];

        dest.on('data', (chunk) => chunks.push(chunk));
        dest.on('end', () => {
            expect(Buffer.concat(chunks).toString()).toBe('hello world');
            done();
        });

        pipe(source, dest);
    });

    test('destroys dest when source errors', (done) => {
        const source = new PassThrough();
        const dest = new PassThrough();

        dest.on('close', () => done());

        pipe(source, dest);

        source.destroy(new Error('source error'));
    });

    test('destroys source when dest errors', (done) => {
        const source = new PassThrough();
        const dest = new PassThrough();

        source.on('close', () => done());

        pipe(source, dest);

        dest.destroy(new Error('dest error'));
    });
});
