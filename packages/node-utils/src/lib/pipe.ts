import { Readable, Writable } from "stream";

//
// Pipes a readable stream into a writable stream with error propagation.
// If either stream errors, the other is destroyed to prevent memory leaks.
//
export function pipe(source: Readable, dest: Writable): void {
    source.on('error', (err) => dest.destroy(err));
    dest.on('error', () => source.destroy());
    source.pipe(dest);
}
