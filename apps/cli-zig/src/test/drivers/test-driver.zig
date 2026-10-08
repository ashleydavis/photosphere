const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const lan_share_network = @import("lan-share-network-zig");

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
// Runs the scenario named by the arguments, and says what an error.Thrown was thrown for. A program that returns an error
// prints only its name, and the name of this one carries nothing: the Windows unit test job failed in the share tests
// (for example "dbs send says no device found when no receiver turns up before the discovery timeout") with a stderr of
// "error: Thrown" and no way to tell which call had failed.
//
pub fn main(init: std.process.Init) !void {
    runScenario(init) catch |err| {
        if (err == error.Thrown) {
            std.debug.print("{s}\n", .{utils.errors.lastErrorMessage()});
        }
        return err;
    };
}

//
// Runs the scenario named by the arguments.
//
fn runScenario(init: std.process.Init) !void {
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
    else if (std.mem.eql(u8, scenario, "dbs-receive-timeout")) {
        // dbs-receive-timeout <pairing code> <discovery timeout in ms>
        try expectArgumentCount(scenarioArguments, 2);
        try writeResult(allocator, io, resultPath, null);
        var options: cli.dbs.IDbsReceiveOptions = .{
            .yes = true,
            .code = scenarioArguments[0],
            .discoveryTimeoutMs = parseMilliseconds(scenarioArguments[1]),
        };
        try cli.dbs.dbsReceive(allocator, io, &options);
    }
    else if (std.mem.eql(u8, scenario, "dbs-send-timeout")) {
        // dbs-send-timeout <database name> <pairing code> <discovery timeout in ms>
        try expectArgumentCount(scenarioArguments, 3);
        try writeResult(allocator, io, resultPath, null);
        var options: cli.dbs.IDbsSendOptions = .{
            .yes = true,
            .name = scenarioArguments[0],
            .code = scenarioArguments[1],
            .discoveryTimeoutMs = parseMilliseconds(scenarioArguments[2]),
        };
        try cli.dbs.dbsSend(allocator, io, &options);
    }
    else if (std.mem.eql(u8, scenario, "dbs-send-to-mismatched-receiver")) {
        // dbs-send-to-mismatched-receiver <database name> <pairing code> <the other device's code>
        // <discovery timeout in ms>
        try expectArgumentCount(scenarioArguments, 4);
        try writeResult(allocator, io, resultPath, null);
        try withMismatchedReceiver(io, scenarioArguments[2], parseMilliseconds(scenarioArguments[3]), ISendContext{
            .allocator = allocator,
            .io = io,
            .name = scenarioArguments[0],
            .code = scenarioArguments[1],
            .discoveryTimeoutMs = parseMilliseconds(scenarioArguments[3]),
        }, runDbsSend);
    }
    else if (std.mem.eql(u8, scenario, "secrets-receive-timeout")) {
        // secrets-receive-timeout <pairing code> <discovery timeout in ms>
        try expectArgumentCount(scenarioArguments, 2);
        try writeResult(allocator, io, resultPath, null);
        var options: cli.secrets.ISecretsReceiveOptions = .{
            .yes = true,
            .code = scenarioArguments[0],
            .discoveryTimeoutMs = parseMilliseconds(scenarioArguments[1]),
        };
        try cli.secrets.secretsReceive(allocator, io, &options);
    }
    else if (std.mem.eql(u8, scenario, "secrets-send-timeout")) {
        // secrets-send-timeout <secret name> <pairing code> <discovery timeout in ms>
        try expectArgumentCount(scenarioArguments, 3);
        try writeResult(allocator, io, resultPath, null);
        var options: cli.secrets.ISecretsSendOptions = .{
            .yes = true,
            .name = scenarioArguments[0],
            .code = scenarioArguments[1],
            .discoveryTimeoutMs = parseMilliseconds(scenarioArguments[2]),
        };
        try cli.secrets.secretsSend(allocator, io, &options);
    }
    else if (std.mem.eql(u8, scenario, "secrets-send-to-mismatched-receiver")) {
        // secrets-send-to-mismatched-receiver <secret name> <pairing code> <the other device's code>
        // <discovery timeout in ms>
        try expectArgumentCount(scenarioArguments, 4);
        try writeResult(allocator, io, resultPath, null);
        try withMismatchedReceiver(io, scenarioArguments[2], parseMilliseconds(scenarioArguments[3]), ISendContext{
            .allocator = allocator,
            .io = io,
            .name = scenarioArguments[0],
            .code = scenarioArguments[1],
            .discoveryTimeoutMs = parseMilliseconds(scenarioArguments[3]),
        }, runSecretsSend);
    }
    else {
        return error.UnknownScenario;
    }
}

//
// What a send scenario needs to run its command with.
//
const ISendContext = struct {
    // Allocates what the command allocates.
    allocator: std.mem.Allocator,

    // The Io the command prompts and logs with.
    io: std.Io,

    // The name of the database or secret to send.
    name: []const u8,

    // The pairing code the sender uses.
    code: []const u8,

    // How long the sender waits for a receiver, in milliseconds.
    discoveryTimeoutMs: i64,
};

//
// A LAN share receiver kept broadcasting for the sender of a scenario, on a thread of its own.
//
const IHeldReceiver = struct {
    // The receiver. It announces the hash of the pairing code it was given, which is deliberately
    // not the sender's: that is what a user who mistyped the pairing code has on the other device,
    // and it is what makes the sender report a rejected code rather than an absent device.
    receiver: lan_share_network.lan_share_receiver.LanShareReceiver,

    // The pairing code the receiver announces.
    code: []const u8,

    // The Io the receiver's threads sleep with.
    io: std.Io,

    // Set once the receiver is broadcasting, so the sender does not start before the first
    // announcement has gone out.
    isBroadcasting: std.atomic.Value(bool),
};

//
// Runs a LAN share receiver on a thread until it is cancelled.
//
fn holdReceiver(context: *IHeldReceiver) void {
    context.receiver.start(context.code) catch |err| {
        std.debug.panic("Starting the LAN share receiver failed: {t}", .{err});
    };
    context.isBroadcasting.store(true, .release);
    while (!context.receiver.isDone.load(.acquire)) {
        context.io.sleep(.fromMilliseconds(20), .awake) catch {
            return;
        };
    }
}

//
// Starts a receiver announcing a pairing code of its own, runs what the scenario names while it
// broadcasts, then stops it. What the scenario names is passed in as a function so the receiver is
// released in the same place either way.
//
fn withMismatchedReceiver(io: std.Io, code: []const u8, timeoutMs: i64, context: ISendContext, run: *const fn (ISendContext) anyerror!void) !void {
    var held = IHeldReceiver{
        .receiver = lan_share_network.lan_share_receiver.LanShareReceiver.init(io, timeoutMs),
        .code = code,
        .io = io,
        .isBroadcasting = .init(false),
    };
    defer held.receiver.deinit();
    const thread = try std.Thread.spawn(.{}, holdReceiver, .{&held});
    while (!held.isBroadcasting.load(.acquire)) {
        try io.sleep(.fromMilliseconds(20), .awake);
    }
    try run(context);
    held.receiver.cancel();
    thread.join();
}

//
// The discovery timeout a scenario argument carries, in milliseconds.
//
fn parseMilliseconds(text: []const u8) i64 {
    return std.fmt.parseInt(i64, text, 10) catch |err| {
        std.debug.panic("Parsing the discovery timeout \"{s}\" failed: {t}", .{ text, err });
    };
}

//
// Runs `psi dbs send` with the pairing code and discovery timeout a scenario carried, as the closure
// withMismatchedReceiver runs.
//
fn runDbsSend(context: ISendContext) !void {
    var options: cli.dbs.IDbsSendOptions = .{
        .yes = true,
        .name = context.name,
        .code = context.code,
        .discoveryTimeoutMs = context.discoveryTimeoutMs,
    };
    try cli.dbs.dbsSend(context.allocator, context.io, &options);
}

//
// Runs `psi secrets send` with the pairing code and discovery timeout a scenario carried, as the
// closure withMismatchedReceiver runs.
//
fn runSecretsSend(context: ISendContext) !void {
    var options: cli.secrets.ISecretsSendOptions = .{
        .yes = true,
        .name = context.name,
        .code = context.code,
        .discoveryTimeoutMs = context.discoveryTimeoutMs,
    };
    try cli.secrets.secretsSend(context.allocator, context.io, &options);
}
