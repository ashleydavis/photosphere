const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");

//
// A program for the unit tests (it is not shipped): it runs one CLI function against the real process streams,
// so that the tests drive the prompts through stdin and see what is written to stdout, as they would for psi.
// Usage: test-driver <result-file> <scenario> [arguments...]
// The value the function returns is written to <result-file> as JSON.
//

//
// Writes a value to the result file as JSON.
//
fn writeResult(allocator: std.mem.Allocator, io: std.Io, resultPath: []const u8, value: anytype) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = resultPath, .data = json });
}

//
// Parses a "true" or "false" argument.
//
fn parseBool(text: []const u8) !bool {
    if (std.mem.eql(u8, text, "true")) {
        return true;
    }
    if (std.mem.eql(u8, text, "false")) {
        return false;
    }
    return error.ExpectedTrueOrFalse;
}

//
// Checks the number of scenario arguments.
//
fn expectArgumentCount(scenarioArguments: []const [:0]const u8, count: usize) !void {
    if (scenarioArguments.len != count) {
        return error.WrongNumberOfArguments;
    }
}

//
// Runs the scenario named by the arguments.
//
pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.arena.allocator();
    node_utils.process_env.setEnvironMap(init.environ_map);
    const arguments = try init.minimal.args.toSlice(allocator);

    // Copied in as the program `psi bug` opens its URL with (xdg-open, open, or PowerShell on Windows), the driver
    // records the arguments it was started with, one per line, to the file this variable names. It is written
    // under another name and renamed into place, so a test waiting for it never reads half of it.
    if (node_utils.process_env.getEnv("PHOTOSPHERE_TEST_OPENER_RECORD")) |recordPath| {
        const recorded = try std.mem.join(allocator, "\n", arguments[1..]);
        const partialPath = try std.fmt.allocPrint(allocator, "{s}.partial", .{recordPath});
        const cwd = std.Io.Dir.cwd();
        try cwd.writeFile(io, .{ .sub_path = partialPath, .data = recorded });
        try cwd.rename(partialPath, cwd, recordPath, io);
        return;
    }

    if (arguments.len < 3) {
        return error.ExpectedResultFileAndScenario;
    }
    const resultPath = arguments[1];
    const scenario = arguments[2];
    const scenarioArguments = arguments[3..];

    if (std.mem.eql(u8, scenario, "write-progress")) {
        // write-progress <message> <verbose>
        try expectArgumentCount(scenarioArguments, 2);
        var log = cli.log.Log.init(.{ .verbose = try parseBool(scenarioArguments[1]) });
        utils.log.setLog(log.ilog());
        cli.terminal_utils.writeProgress(scenarioArguments[0]);
        cli.terminal_utils.clearProgressMessage();
        try writeResult(allocator, io, resultPath, null);
    }
    else if (std.mem.eql(u8, scenario, "configure-s3")) {
        try expectArgumentCount(scenarioArguments, 0);
        try writeResult(allocator, io, resultPath, try cli.init_cmd.configureS3IfNeeded(allocator, io, false));
    }
    else if (std.mem.eql(u8, scenario, "select-encryption-key")) {
        // select-encryption-key <message>
        try expectArgumentCount(scenarioArguments, 1);
        try writeResult(allocator, io, resultPath, try cli.init_cmd.selectEncryptionKey(allocator, io, scenarioArguments[0]));
    }
    else if (std.mem.eql(u8, scenario, "prompt-for-encryption")) {
        // prompt-for-encryption <message>
        try expectArgumentCount(scenarioArguments, 1);
        try writeResult(allocator, io, resultPath, try cli.init_cmd.promptForEncryption(allocator, io, scenarioArguments[0]));
    }
    else if (std.mem.eql(u8, scenario, "prompt-to-add-key")) {
        // prompt-to-add-key <key name>
        try expectArgumentCount(scenarioArguments, 1);
        try writeResult(allocator, io, resultPath, try cli.init_cmd.promptToAddKey(allocator, io, scenarioArguments[0], false));
    }
    else if (std.mem.eql(u8, scenario, "prompt-to-generate-or-add-key")) {
        // prompt-to-generate-or-add-key <key name>
        try expectArgumentCount(scenarioArguments, 1);
        try writeResult(allocator, io, resultPath, try cli.init_cmd.promptToGenerateOrAddKey(allocator, io, scenarioArguments[0], false));
    }
    else if (std.mem.eql(u8, scenario, "resolve-key-pems-with-prompt")) {
        // resolve-key-pems-with-prompt <key name> <can generate>
        try expectArgumentCount(scenarioArguments, 2);
        try writeResult(allocator, io, resultPath, try cli.init_cmd.resolveKeyPemsWithPrompt(allocator, io, scenarioArguments[0], false, try parseBool(scenarioArguments[1])));
    }
    else if (std.mem.eql(u8, scenario, "get-directory-for-command")) {
        // get-directory-for-command <init|existing> <cwd>
        try expectArgumentCount(scenarioArguments, 2);
        const commandType = std.meta.stringToEnum(cli.directory_picker.CommandType, scenarioArguments[0]) orelse return error.UnknownCommandType;
        try writeResult(allocator, io, resultPath, try cli.directory_picker.getDirectoryForCommand(allocator, io, commandType, false, scenarioArguments[1]));
    }
    else if (std.mem.eql(u8, scenario, "pick-directory")) {
        // pick-directory <message> <current directory> <validate existing database>
        try expectArgumentCount(scenarioArguments, 3);
        const validator: ?cli.directory_picker.Validator = if (try parseBool(scenarioArguments[2])) cli.directory_picker.validateExistingDatabase else null;
        try writeResult(allocator, io, resultPath, try cli.directory_picker.pickDirectory(allocator, io, scenarioArguments[0], scenarioArguments[1], validator));
    }
    else {
        return error.UnknownScenario;
    }
}
