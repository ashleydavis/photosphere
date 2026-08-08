import { Readable, Writable } from "stream";

//
// Pipes a readable stream into a writable stream, tearing down both when either one finishes for
// any reason.
//
// The `close` handler is what stops the source outliving its consumer. A caller that has read what
// it needs and calls dest.destroy() emits `close`, not `error`, and Node's pipe() does not carry
// destruction back upstream, so the source was left open with nothing reading it. That is a leaked
// file handle every time an encrypted file is opened and abandoned: EncryptedStorage.readStream
// hands back the decryption stream, so the caller only ever destroys that, never the file beneath.
// loadVersion in the serialization package does exactly this, taking four bytes and destroying the
// stream, and it runs on .db/files.dat every time an encrypted database is opened.
//
// Invisible on Linux, where an open handle does not stop a file being replaced. On Windows it does:
// renaming the new index over the old one failed with EPERM, `psi add` swallowed it and reported
// success, and the database was left with nothing in it.
//
// Destroying an already-finished stream is a no-op, so the normal path costs nothing: on a clean
// end the source has already finished before `close` reaches this handler.
//
export function pipe(source: Readable, dest: Writable): void {
    source.on('error', (err) => dest.destroy(err));
    dest.on('error', () => source.destroy());
    dest.on('close', () => source.destroy());
    source.pipe(dest);
}
