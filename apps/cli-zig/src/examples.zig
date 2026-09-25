//
// Port of apps/cli/src/examples.ts: the usage examples shown in the help of the commands.
//

const std = @import("std");
const commander = @import("lib/commander.zig");

//
// A usage example of a command.
//
pub const ICommandExample = struct {
    // The command line.
    command: []const u8,

    // What the command line does.
    description: []const u8,
};

//
// The examples of a command, by command name.
//
pub const ICommandExamples = struct {
    // The name of the command.
    commandName: []const u8,

    // Its examples.
    examples: []const ICommandExample,
};

//
// Centralized examples for all CLI commands
// (only the commands implemented in Zig are ported: verify and replicate).
//
pub const COMMAND_EXAMPLES = [_]ICommandExamples{
    .{
        .commandName = "verify",
        .examples = &.{
            .{
                .command = "psi verify --db .",
                .description = "Verifies a database in the current directory.",
            },
            .{
                .command = "psi verify --db ./photos",
                .description = "Verifies a database in the ./photos directory.",
            },
            .{
                .command = "psi verify --db ./photos --full",
                .description = "Forces full verification of all files.",
            },
        },
    },
    .{
        .commandName = "replicate",
        .examples = &.{
            .{
                .command = "psi replicate --db ./photos --dest ./backup",
                .description = "Replicates a database to a backup location.",
            },
            .{
                .command = "psi replicate --db . --dest s3:bucket/photos",
                .description = "Replicates the current database to S3.",
            },
        },
    },
};

// Not ported: MAIN_EXAMPLES (the program help is shown by the TypeScript CLI).

//
// Helper function to format examples for help text
//
pub fn formatExamplesForHelp(allocator: std.mem.Allocator, examples: []const ICommandExample) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    for (examples) |example| {
        var line: std.ArrayList(u8) = .empty;
        try line.appendSlice(allocator, "  ");
        try line.appendSlice(allocator, example.command);
        const length = commander.jsLength(example.command);
        if (length < 32) {
            try line.appendNTimes(allocator, ' ', 32 - length);
        }
        try line.append(allocator, ' ');
        try line.appendSlice(allocator, example.description);
        try lines.append(allocator, line.items);
    }
    return std.mem.join(allocator, "\n", lines.items);
}

//
// Helper function to get examples help text for a command
//
pub fn getCommandExamplesHelp(allocator: std.mem.Allocator, commandName: []const u8) ![]const u8 {
    for (COMMAND_EXAMPLES) |entry| {
        if (std.mem.eql(u8, entry.commandName, commandName)) {
            if (entry.examples.len == 0) {
                return "";
            }
            return std.fmt.allocPrint(allocator, "\nExamples:\n{s}", .{try formatExamplesForHelp(allocator, entry.examples)});
        }
    }
    return "";
}
