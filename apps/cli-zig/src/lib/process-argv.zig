//
// The process arguments, kept for the whole program.
// main sets the arguments once at startup. argv[0] is the executable, so the user arguments start at index 1.
//

const std = @import("std");

//
// The process arguments (argv[0] is the executable). Empty until main calls setArgv.
//
var process_argv: []const []const u8 = &.{};

//
// Sets the process arguments.
//
pub fn setArgv(argv: []const []const u8) void {
    process_argv = argv;
}

//
// Gets the process arguments (argv[0] is the executable).
//
pub fn getArgv() []const []const u8 {
    return process_argv;
}

//
// Gets the user arguments (those after the executable).
//
pub fn userArgs() []const []const u8 {
    if (process_argv.len <= 1) {
        return &.{};
    }
    return process_argv[1..];
}
