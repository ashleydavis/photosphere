const std = @import("std");

//
// A build for Android or for an Apple target that needs the SDK has a libc file for the target (the NDK's, given with --libc, or the SDK's,
// see packages-zig/apple-sdk.zig), and Zig gives that file to every compile step that has none of its own, including the programs the
// build runs on the machine doing it. A program that links the C library (every program on macOS) then links the target's, and fails, as
// ImageMagick's threshold-map-tool did on a Mac building for iOS ("undefined symbol: __NSGetExecutablePath").
//

//
// Gives a program built for the machine doing the build that machine's own C library, as `zig libc` finds it, when the build has a libc
// file for its target. Does nothing when it has none, since the program then finds the machine's C library by itself.
//
pub fn useHostLibc(b: *std.Build, program: *std.Build.Step.Compile) void {
    if (b.libc_file == null) {
        return;
    }
    const find_libc = b.addSystemCommand(&.{ b.graph.zig_exe, "libc" });
    program.setLibCFile(find_libc.captureStdOut(.{
        .basename = "host-libc.txt",
    }));
}
