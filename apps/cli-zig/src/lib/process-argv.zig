//
// Stand-in for the JavaScript global `process.argv` (this file has no TypeScript counterpart).
// main sets the arguments once at startup. In TypeScript argv[0] is the runtime and argv[1] the script;
// in Zig argv[0] is the executable, so the user arguments (`process.argv.slice(2)`) start at index 1.
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
// Gets the user arguments (TypeScript: `process.argv.slice(2)`).
//
pub fn userArgs() []const []const u8 {
    if (process_argv.len <= 1) {
        return &.{};
    }
    return process_argv[1..];
}
