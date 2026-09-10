import * as fs from "fs";

//
// Where the CLI's own output goes, and why it does not go through `console.log`.
//
// Once this process has a Worker, anything written to `process.stdout` or `process.stderr` beyond
// what the far end takes immediately is discarded, silently, and the CLI creates a pool of Workers as
// soon as it opens a database. Measured on the pinned Bun: `psi find-orphans` printing 3,000 orphans
// into a pipe whose reader had not started yet delivered 8,127 bytes of 220,890 and no summary line
// after them. `console.log` and `fs.writeSync(1, ...)` lose it alike, and nothing recovers it: the
// bytes are dropped as they are written rather than queued, so waiting, ending the stream and letting
// the process end on its own all deliver exactly the same truncated 8,127 bytes.
//
// It only happens when the output is a pipe, which is what a script capturing the output gets and
// never what a terminal gets, and it is worse the busier the machine is, so it showed up as a smoke
// test that failed only in company: `73-s3-pagination` read a count out of the summary line that was
// missing and reported that the app had enumerated 0 objects, which sent three separate
// investigations at S3 for a fault that was in the output.
//
// Opening `/dev/stdout` gives this process a second file description onto the same destination, with
// its own flags rather than the ones the Workers brought, and writes through it arrive whole. That is
// what every line the CLI prints now goes through.
//
// Windows has no such path, and this has never been seen there, so it keeps the ordinary console.
//

//
// One of the two standard destinations, by the path that reopens it.
//
interface IReopenedStream {
    // The device path that opens a fresh file description onto the same destination.
    devicePath: string;

    // The file description, once opened. Undefined until the first write.
    fileDescriptor: number | undefined;

    // True once opening has been tried and failed, so it is not tried again per line.
    unavailable: boolean;
}

//
// Standard output, reopened.
//
const reopenedStdout: IReopenedStream = {
    devicePath: "/dev/stdout",
    fileDescriptor: undefined,
    unavailable: false,
};

//
// Standard error, reopened.
//
const reopenedStderr: IReopenedStream = {
    devicePath: "/dev/stderr",
    fileDescriptor: undefined,
    unavailable: false,
};

//
// Writes a line to one of the two destinations, opening it on first use.
//
// Falls back to the console when the device path cannot be opened, which is Windows and anything else
// without /dev/stdout. Losing the reopened description mid-run (a closed pipe, say) falls back the
// same way rather than throwing, because the alternative is a command that fails while printing its
// answer.
//
function writeLine(stream: IReopenedStream, message: string, fallback: (message: string) => void): void {
    if (!stream.unavailable && stream.fileDescriptor === undefined) {
        try {
            stream.fileDescriptor = fs.openSync(stream.devicePath, "a");
        }
        catch {
            stream.unavailable = true;
        }
    }

    if (stream.fileDescriptor !== undefined) {
        try {
            fs.writeSync(stream.fileDescriptor, `${message}\n`);
            return;
        }
        catch {
            stream.unavailable = true;
            stream.fileDescriptor = undefined;
        }
    }

    fallback(message);
}

//
// Prints a line of the CLI's output.
//
export function writeOutputLine(message: string): void {
    writeLine(reopenedStdout, message, console.log);
}

//
// Prints a line of the CLI's error output.
//
export function writeErrorLine(message: string): void {
    writeLine(reopenedStderr, message, console.error);
}
