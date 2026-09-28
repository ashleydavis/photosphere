//
// Port of apps/cli/src/cmd/examples.ts: the `psi examples` command.
//

const std = @import("std");
const utils = @import("utils-zig");
const pc = @import("../lib/picocolors.zig");
const examples = @import("../examples.zig");
const log = &utils.log.log;
const COMMAND_EXAMPLES = examples.COMMAND_EXAMPLES;
const formatExamplesForHelp = examples.formatExamplesForHelp;

//
// A category of commands in the examples listing (an entry of `categories` in examples.ts).
//
const IExampleCategory = struct {
    // The name of the category.
    categoryName: []const u8,

    // The names of the commands in the category.
    commands: []const []const u8,
};

//
// Group commands by category for better organization
//
const categories = [_]IExampleCategory{
    .{
        .categoryName = "Database Management",
        .commands = &.{ "init", "add", "check", "summary", "verify", "find-orphans", "remove-orphans" },
    },
    .{
        .categoryName = "Backup and syncrhonization",
        .commands = &.{ "replicate", "compare" },
    },
    .{
        .categoryName = "Configuration",
        .commands = &.{ "config", "tools" },
    },
    .{
        .categoryName = "File Analysis",
        .commands = &.{"info"},
    },
    .{
        .categoryName = "Help and Support",
        .commands = &.{ "examples", "bug" },
    },
};

//
// Finds the examples of a command (`COMMAND_EXAMPLES[commandName]`), or null when it has none.
//
fn findExamples(commandName: []const u8) ?[]const examples.ICommandExample {
    for (COMMAND_EXAMPLES) |entry| {
        if (std.mem.eql(u8, entry.commandName, commandName)) {
            return entry.examples;
        }
    }
    return null;
}

//
// Command to display all examples categorized by command
//
pub fn examplesCommand(allocator: std.mem.Allocator) !void {
    log.info(try pc.bold(allocator, try pc.blue(allocator, "📖 Photosphere CLI Examples")));
    log.info("");
    log.info("Below are usage examples for all available commands:");
    log.info("");

    for (categories) |category| {
        log.info(try pc.bold(allocator, try pc.cyan(allocator, try std.fmt.allocPrint(allocator, "{s}:", .{category.categoryName}))));
        log.info("");

        for (category.commands) |commandName| {
            const commandExamples = findExamples(commandName);
            if (commandExamples != null and commandExamples.?.len > 0) {
                log.info(try pc.bold(allocator, try std.fmt.allocPrint(allocator, "  {s}:", .{commandName})));
                const formattedExamples = try formatExamplesForHelp(allocator, commandExamples.?);
                // Indent each line by 4 spaces
                var indentedLines: std.ArrayList([]const u8) = .empty;
                var lines = std.mem.splitScalar(u8, formattedExamples, '\n');
                while (lines.next()) |line| {
                    try indentedLines.append(allocator, try std.fmt.allocPrint(allocator, "  {s}", .{line}));
                }
                const indentedExamples = try std.mem.join(allocator, "\n", indentedLines.items);
                log.info(indentedExamples);
                log.info("");
            }
        }
    }

    log.info("💡 Tip: Use \"psi <command> --help\" to see detailed help for any specific command.");
    log.info("");
}
