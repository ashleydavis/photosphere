const std = @import("std");
const utils = @import("utils-zig");

//
// Redirects the console of the code under test (the Zig stand-in for jest.spyOn(console, ...) in the TypeScript tests).
//

//
// Receives what the code under test writes to stdout with console.log (log.info), because the test runner uses
// stdout to talk to the build runner.
//
var discarded_stdout: std.Io.Writer.Discarding = .init(&.{});

//
// Sends the console's stderr to the writer, keeping stdout discarded. stdout must never reach the real stdout in a
// test: under the build runner it is the channel the test program reports its results on.
//
pub fn captureStderr(writer: *std.Io.Writer) void {
    utils.console.setCapture(&discarded_stdout.writer, writer);
}

//
// Sends the console's stdout and stderr to the writers.
//
pub fn captureConsole(stdoutWriter: *std.Io.Writer, stderrWriter: *std.Io.Writer) void {
    utils.console.setCapture(stdoutWriter, stderrWriter);
}

//
// Puts the console back as setupEnvironment left it: stdout discarded, stderr real.
//
pub fn endConsoleCapture() void {
    utils.console.setCapture(&discarded_stdout.writer, null);
}
