import * as fs from "fs";

//
// Where the CLI's own output goes, and why it does not go through `console.log`.
//
// Once this process has a Worker, and the CLI creates a pool of them as soon as it opens a database,
// the standard output is non-blocking and anything written to it beyond what the far end takes
// immediately is discarded. Measured on the pinned Bun: `psi find-orphans` printing 3,000 orphans
// into a pipe whose reader had not started yet delivered 8,127 bytes of 220,890 and no summary line
// after them. The bytes are dropped as they are written rather than queued, so nothing recovers them:
// waiting six seconds, ending the stream and waiting for its callback, and letting the process end on
// its own with no `process.exit` at all each deliver exactly the same 8,127 bytes.
//
// It only happens when the output is a pipe, which is what a script capturing the output gets and
// never what a terminal gets, and it is worse the busier the machine is, so it showed up as a smoke
// test that failed only in company: `73-s3-pagination` read a count out of the summary line that was
// missing and reported that the app had enumerated 0 objects.
//
// So the CLI writes its own bytes and waits for them, which is what a blocking write to a terminal
// does anyway. `fs.writeSync` on a non-blocking descriptor raises EAGAIN when the far end is full
// instead of waiting, and can write fewer bytes than it was given; both are the caller's to deal
// with, and neither is dealt with by anything that writes a whole line and moves on.
//

//
// One word of shared memory, there only as something `Atomics.wait` can block on. It is the one way
// to pause without spinning and without handing control back to the event loop, which a synchronous
// write cannot do.
//
const pauseWord = new Int32Array(new SharedArrayBuffer(4));

//
// Milliseconds to wait before trying a write again when the far end is full. Long enough that a
// reader which has not started yet is not spun on, short enough to be invisible against the reading.
//
const RETRY_PAUSE_MS = 1;

//
// True once a write has failed in a way that means there is nothing at the other end any more, so
// the remaining output is dropped rather than reported per line.
//
let outputGone = false;

//
// Writes every byte of the text to the given descriptor, and does not return until they have gone.
//
function writeAll(fileDescriptor: number, text: string): void {
    if (outputGone) {
        return;
    }

    const bytes = Buffer.from(text, "utf8");
    let written = 0;

    while (written < bytes.length) {
        try {
            written += fs.writeSync(fileDescriptor, bytes, written, bytes.length - written);
        }
        catch (error: any) {
            const code = error?.code;

            if (code === "EAGAIN" || code === "EWOULDBLOCK") {
                // The far end is full. A blocking descriptor would have waited here, so wait.
                Atomics.wait(pauseWord, 0, 0, RETRY_PAUSE_MS);
                continue;
            }

            if (code === "EPIPE" || code === "EBADF") {
                // Nobody is reading any more, which is what `head` does to a long listing. Node's
                // own streams swallow this rather than turning it into an error the user sees.
                outputGone = true;
                return;
            }

            throw error;
        }
    }
}

//
// Prints a line of the CLI's output.
//
export function writeOutputLine(message: string): void {
    writeAll(1, `${message}\n`);
}

//
// Prints a line of the CLI's error output.
//
export function writeErrorLine(message: string): void {
    writeAll(2, `${message}\n`);
}
