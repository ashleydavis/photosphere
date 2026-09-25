const std = @import("std");
const utils = @import("utils-zig");
const console = utils.console;

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
// (Zig: the standard output and error of the Zig CLI are never made non-blocking (its workers are threads,
// not Bun Workers), so utils-zig's console, which writes every byte of a line with a blocking write and
// ignores the error of a reader that has gone away, already does what writeAll does here. Not ported:
// pauseWord, RETRY_PAUSE_MS, outputGone, writeAll.)
//

//
// Prints a line of the CLI's output.
//
pub fn writeOutputLine(message: []const u8) void {
    console.log(message);
}

//
// Prints a line of the CLI's error output.
//
pub fn writeErrorLine(message: []const u8) void {
    console.@"error"(message);
}
