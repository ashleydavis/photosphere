//
// Tests of the setup side of the CLI: the console output, the file logger, the directory picker, the MCP input
// schema and helpers, and the pieces of clack those drive. They cover the branches the other test files do not
// reach: a write that fails, a path that cannot be written to, a prompt the user refuses, an input that does not
// validate, and a malformed MCP message.
//
const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const serialization_zig = @import("serialization-zig");
const helpers = @import("test-helpers.zig");
const console_output = cli.console_output;
const FileLogger = cli.file_logger.FileLogger;
const input_schema = cli.mcp_input_schema;
const mcp_protocol = cli.mcp_protocol;
const mcp_result = cli.mcp_result;
const mcp_types = cli.mcp_types;
const prompts = cli.prompts;
const common = prompts.common;
const clack_core = cli.clack_core;
const BsonValue = serialization_zig.bson.BsonValue;
const BsonDocument = serialization_zig.bson.BsonDocument;
const jsonParse = serialization_zig.json_parse.jsonParse;
const io = std.testing.io;

//
// What a test wrote to stdout and stderr, captured from the process console (the test runner talks to the build
// over stdout, so the console has to be captured rather than written to).
//
const ICapture = struct {
    // What was written to stdout.
    stdout: std.Io.Writer.Allocating,

    // What was written to stderr.
    stderr: std.Io.Writer.Allocating,
};

//
// Starts capturing the console into the given capture. It fills the capture in place rather than returning it,
// because a writer finds the writer it belongs to from the address of its own fields, so it must not be moved after
// it has been given to the console. The caller restores the console with stopCapture.
//
fn startCapture(capture: *ICapture, allocator: std.mem.Allocator) void {
    capture.* = .{
        .stdout = .init(allocator),
        .stderr = .init(allocator),
    };
    utils.console.setCapture(&capture.stdout.writer, &capture.stderr.writer);
}

//
// Stops capturing the console.
//
fn stopCapture() void {
    utils.console.setCapture(null, null);
}

//
// A file logger writing under a temporary directory of its own, with the console captured. The environment map, the
// console and the termination callbacks are all process-wide, so every test that touches them puts them back.
//
const ILogEnvironment = struct {
    // Owns the test's memory.
    arena: std.heap.ArenaAllocator,

    // The environment map the logger resolves its log directory from.
    environ_map: std.process.Environ.Map,

    // The temporary directory the logs go in.
    tmp_dir: []const u8,

    // What the logger and its console log wrote.
    capture: ICapture,

    // The logger under test.
    logger: *FileLogger,

    //
    // Creates the environment and its logger.
    //
    fn init(self: *ILogEnvironment, name: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        self.tmp_dir = try helpers.makeTempDir(allocator, name);
        self.environ_map = std.process.Environ.Map.init(allocator);
        // os.tmpdir() reads TMPDIR on POSIX and TEMP on Windows.
        try self.environ_map.put("TMPDIR", self.tmp_dir);
        try self.environ_map.put("TEMP", self.tmp_dir);
        node_utils.process_env.setEnvironMap(&self.environ_map);
        self.capture = undefined;
        startCapture(&self.capture, allocator);
        cli.process_argv.setArgv(&.{ "psi", "verify", "--db", "x" });
        var console_log = cli.log.Log.init(.{});
        self.logger = try FileLogger.create(allocator, io, console_log.ilog(), "verify --db x");
    }

    //
    // Puts the process state back and deletes the temporary directory.
    //
    fn deinit(self: *ILogEnvironment) void {
        node_utils.termination.clearTerminationCallbacks();
        stopCapture();
        node_utils.process_env.setEnvironMap(null);
        std.Io.Dir.cwd().deleteTree(io, self.tmp_dir) catch {};
        self.arena.deinit();
    }

    //
    // Reads one of the logger's files.
    //
    fn readFile(self: *ILogEnvironment, file_path: []const u8) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(io, file_path, self.arena.allocator(), .unlimited);
    }
};

//
// Makes a directory that can be read and searched but not written to, and returns a function that puts it back so
// the tree under it can be deleted. A no-op (returning the path unchanged) on Windows, where the permissions of a
// directory are not what stops a write.
//
fn makeReadOnlyDir(dir_path: []const u8) ![]const u8 {
    if (builtin.os.tag == .windows) {
        return dir_path;
    }
    try std.Io.Dir.cwd().setFilePermissions(io, dir_path, std.Io.File.Permissions.fromMode(0o500), .{});
    return dir_path;
}

//
// Puts a directory's permissions back so a tree under it can be deleted.
//
fn restoreWrite(dir_path: []const u8) void {
    if (builtin.os.tag == .windows) {
        return;
    }
    std.Io.Dir.cwd().setFilePermissions(io, dir_path, std.Io.File.Permissions.fromMode(0o700), .{}) catch {};
}

//
// Runs `psi summary --cwd <current directory>`: a command that needs an existing database, started from a directory
// that is not one, so it shows the directory picker ("Select an existing media database directory:") with the choices
// subdirectory, full path and cancel, typing the keys of the prompts it shows.
//
fn runPickerOnSummary(allocator: std.mem.Allocator, current_directory: []const u8, promptKeys: []const helpers.IPromptKeys) !helpers.CliResult {
    return helpers.runPsiWithPromptsIn(allocator, .inherit, &.{ "summary", "--cwd", current_directory }, promptKeys);
}

//
// Runs `psi init` from a directory that is not empty, so it shows the directory picker ("Select an empty directory for
// new media database:") with the choices subdirectory, full path and cancel, typing the keys of the prompts it shows.
//
fn runPickerOnInit(allocator: std.mem.Allocator, working_directory: []const u8, promptKeys: []const helpers.IPromptKeys) !helpers.CliResult {
    return helpers.runPsiWithPromptsIn(allocator, .{ .path = working_directory }, &.{"init"}, promptKeys);
}

//
// The directory exists and has no .db in it.
//
fn makePlainDir(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    return helpers.makeTempDir(allocator, name);
}

test "writeOutputLine writes to stdout and writeErrorLine to stderr, each as one whole line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture: ICapture = undefined;
    startCapture(&capture, arena.allocator());
    defer stopCapture();

    console_output.writeOutputLine("first line");
    console_output.writeErrorLine("a problem");
    console_output.writeOutputLine("");

    try std.testing.expectEqualStrings("first line\n\n", capture.stdout.written());
    try std.testing.expectEqualStrings("a problem\n", capture.stderr.written());
}

test "writeOutputLine writes a message with newlines and characters of several bytes whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var capture: ICapture = undefined;
    startCapture(&capture, arena.allocator());
    defer stopCapture();

    // A message far longer than the console's own buffer is written in pieces; every byte of it must still
    // arrive, in order, with exactly one newline of its own at the end.
    const long_line = "x" ** 20000;
    console_output.writeOutputLine(long_line);
    console_output.writeOutputLine("caf\u{00E9} \u{1F4C1}");
    console_output.writeOutputLine("first\nsecond");

    const written = capture.stdout.written();
    try std.testing.expectEqual(long_line.len + 1 + "caf\u{00E9} \u{1F4C1}\n".len + "first\nsecond\n".len, written.len);
    try std.testing.expect(std.mem.startsWith(u8, written, long_line ++ "\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "caf\u{00E9} \u{1F4C1}\nfirst\nsecond\n") != null);
}

test "the log header is everything up to the marker, and without a marker the first fifty lines" {
    var environment: ILogEnvironment = undefined;
    try environment.init("file-logger-header");
    defer environment.deinit();
    const allocator = environment.arena.allocator();

    // With the marker: everything up to and including the marker line, and no entry.
    const details = try environment.logger.getLogDetails(allocator, io);
    try std.testing.expectEqualStrings(environment.logger.getLogFilePath(), details.logFilePath.?);
    try std.testing.expect(std.mem.endsWith(u8, details.logHeader, "--- Log Start ---"));
    try std.testing.expect(std.mem.indexOf(u8, details.logHeader, "] [INFO]") == null);

    // The marker is gone: split('\n').slice(0, 50).join('\n') keeps the first fifty lines and drops the newline
    // that ends the fiftieth, because the join puts the separator back between lines but not after the last one.
    var sixty_lines: std.Io.Writer.Allocating = .init(allocator);
    for (1..61) |line_number| {
        try sixty_lines.writer.print("line {d}\n", .{line_number});
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = environment.logger.getLogFilePath(), .data = sixty_lines.written() });

    var expected: std.Io.Writer.Allocating = .init(allocator);
    for (1..51) |line_number| {
        if (line_number > 1) {
            try expected.writer.writeAll("\n");
        }
        try expected.writer.print("line {d}", .{line_number});
    }
    const truncated = try environment.logger.getLogDetails(allocator, io);
    try std.testing.expectEqualStrings(expected.written(), truncated.logHeader);
    try std.testing.expect(std.mem.indexOf(u8, truncated.logHeader, "line 51") == null);
}

test "a log shorter than fifty lines is returned whole when it has no marker" {
    var environment: ILogEnvironment = undefined;
    try environment.init("file-logger-header-short");
    defer environment.deinit();
    const allocator = environment.arena.allocator();

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = environment.logger.getLogFilePath(), .data = "a\nb\nc\n" });
    const details = try environment.logger.getLogDetails(allocator, io);
    try std.testing.expectEqualStrings("a\nb\nc\n", details.logHeader);
}

test "getLogDetails reports the error when the log file is not there" {
    var environment: ILogEnvironment = undefined;
    try environment.init("file-logger-details-missing");
    defer environment.deinit();
    const allocator = environment.arena.allocator();

    try std.Io.Dir.cwd().deleteFile(io, environment.logger.getLogFilePath());
    // fs.readFile reports the failure as Node does, naming the file it could not open.
    try std.testing.expectError(error.Thrown, environment.logger.getLogDetails(allocator, io));
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "ENOENT: no such file or directory, open") != null);
    try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), environment.logger.getLogFilePath()) != null);
}

test "a log file that cannot be written to drops the entries rather than failing" {
    var environment: ILogEnvironment = undefined;
    try environment.init("file-logger-write-fails");
    defer environment.deinit();

    // Every append opens the file, so a log file that is gone fails on every message and on the footer. Logging
    // must not break the app: nothing is thrown, and the console still gets every message.
    try std.Io.Dir.cwd().deleteFile(io, environment.logger.getLogFilePath());
    environment.logger.info("dropped info");
    environment.logger.warn("dropped warning");
    environment.logger.close();

    try std.testing.expect(environment.logger.hasLoggedErrors());
    try std.testing.expect(std.mem.indexOf(u8, environment.capture.stdout.written(), "dropped info\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, environment.capture.stderr.written(), "dropped warning\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, environment.capture.stdout.written(), "Errors, warnings") != null);
}

test "close writes the footer once however many times it is called" {
    var environment: ILogEnvironment = undefined;
    try environment.init("file-logger-close-twice");
    defer environment.deinit();

    environment.logger.info("something");
    environment.logger.close();
    environment.logger.close();
    environment.logger.close();

    const content = try environment.readFile(environment.logger.getLogFilePath());
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, content, "--- Log End ---"));
    try std.testing.expect(std.mem.endsWith(u8, content, "s)\n" ++ "=" ** 80 ++ "\n"));
}

test "nothing after close reaches the log files, and an error after close is not counted as one" {
    var environment: ILogEnvironment = undefined;
    try environment.init("file-logger-after-close");
    defer environment.deinit();

    environment.logger.close();
    const afterCloseLength = (try environment.readFile(environment.logger.getLogFilePath())).len;
    environment.logger.info("late info");
    environment.logger.warn("late warning");
    environment.logger.@"error"("late error");
    try std.testing.expect(!environment.logger.hasLoggedErrors());

    const content = try environment.readFile(environment.logger.getLogFilePath());
    try std.testing.expectEqual(afterCloseLength, content.len);
    try std.testing.expect(std.mem.indexOf(u8, content, "late") == null);
    const errorContent = try environment.readFile(environment.logger.getErrorLogFilePath());
    try std.testing.expect(std.mem.indexOf(u8, errorContent, "late") == null);
    try std.testing.expect(std.mem.indexOf(u8, errorContent, "--- Error Log End ---") == null);
}

test "tool output is written under the tool's name, and empty output is left out" {
    var environment: ILogEnvironment = undefined;
    try environment.init("file-logger-tool");
    defer environment.deinit();

    environment.logger.tool("identify", .{
        .stdout = "Image: photo.jpg\n",
        .stderr = "",
    });
    environment.logger.tool("ffprobe", .{
        .stdout = "",
        .stderr = "a warning",
    });
    environment.logger.close();

    const content = try environment.readFile(environment.logger.getLogFilePath());
    try std.testing.expect(std.mem.indexOf(u8, content, "] [TOOL] == identify stdout ==\nImage: photo.jpg\n") != null);
    // An empty string is falsy in TypeScript, so that stderr block is not written at all.
    try std.testing.expect(std.mem.indexOf(u8, content, "== identify stderr ==") == null);
    try std.testing.expect(std.mem.indexOf(u8, content, "] [TOOL] == ffprobe stderr ==\na warning") != null);
    // Nor is the other one, which had no stdout to write.
    try std.testing.expect(std.mem.indexOf(u8, content, "== ffprobe stdout ==") == null);
    // Neither tool had one of the two, so exactly two blocks are written.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, content, "] [TOOL] "));
}

test "a full path that does not exist yet is created by pickDirectory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try makePlainDir(allocator, "picker-create-full");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    const new_dir = try std.fs.path.join(allocator, &.{ parent, "made", "up" });

    // `psi init` only shows the picker when its directory is not empty.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ parent, "occupied" }), .data = "x" });

    // Answer with the full path option (subdirectory, full path, cancel), then decline encryption.
    const result = try runPickerOnInit(allocator, parent, &.{
        .{ .waitFor = "Select an empty directory for new media database:", .keys = "\x1b[B\r" },
        .{ .waitFor = "Enter full directory path:", .keys = try std.mem.concat(allocator, u8, &.{ new_dir, "\r" }) },
        .{ .waitFor = "Would you like to encrypt your database?", .keys = "n" },
    });

    // The directory was created and the database is in it, at the path that was typed.
    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try std.testing.expect(node_utils.fs.pathExists(io, try std.fs.path.join(allocator, &.{ new_dir, ".db", "files.dat" })));
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, try std.fmt.allocPrint(allocator, "Created new media file database in {s}", .{new_dir})) != null);
}

test "pickDirectory returns nothing when the Cancel option is chosen" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try makePlainDir(allocator, "picker-cancel-option");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};

    // Subdirectory, full path, cancel: two downs is Cancel.
    const result = try runPickerOnSummary(allocator, parent, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\x1b[B\x1b[B\r" },
    });
    // Cancel picks no directory, which ends the command.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "No directory selected") != null);
    try std.testing.expectEqual(@as(u8, 1), result.exitCode);
}

test "pickDirectory says why the validator refused a full path, and a subdirectory it created" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try makePlainDir(allocator, "picker-validator-refuses");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    const not_a_database = try std.fs.path.join(allocator, &.{ parent, "not-a-database" });

    // validateExistingDatabase: a directory with no .db in it is not a database. The current directory is not one
    // either, so the options are subdirectory, full path, cancel.
    const full_path = try runPickerOnSummary(allocator, parent, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\x1b[B\r" },
        .{ .waitFor = "Enter full directory path:", .keys = try std.mem.concat(allocator, u8, &.{ not_a_database, "\r" }) },
    });
    try std.testing.expect(std.mem.indexOf(u8, full_path.stdout, "Directory is not a valid Photosphere media database") != null);

    // The subdirectory is the first of the three options and is created before the validator is asked about it.
    const subdirectory = try runPickerOnSummary(allocator, parent, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\r" },
        .{ .waitFor = "Enter name for subdirectory:", .keys = "fresh\r" },
    });
    try std.testing.expect(std.mem.indexOf(u8, subdirectory.stdout, "Directory is not a valid Photosphere media database") != null);
    try std.testing.expect(node_utils.fs.pathExists(io, try std.fs.path.join(allocator, &.{ parent, "fresh" })));
}

test "a path that is a file is not empty, so the init validator refuses it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try makePlainDir(allocator, "picker-file-not-empty");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    const existing_file = try std.fs.path.join(allocator, &.{ parent, "a-file" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = existing_file, .data = "x" });

    const result = try runPickerOnInit(allocator, parent, &.{
        .{ .waitFor = "Select an empty directory for new media database:", .keys = "\x1b[B\r" },
        .{ .waitFor = "Enter full directory path:", .keys = try std.mem.concat(allocator, u8, &.{ existing_file, "\r" }) },
    });

    // Reading a file as a directory fails, so isEmptyOrNonExistent says it is not empty and the validator refuses.
    // A refused pick exits 1; had the file been taken for an empty directory, it would have been returned.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "can't use this directory because it's not empty") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "No directory selected") != null);
    try std.testing.expect(result.exitCode != 0);
}

test "a directory with a child in it is not empty either" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try makePlainDir(allocator, "picker-not-empty");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    const full_dir = try std.fs.path.join(allocator, &.{ parent, "full" });
    try std.Io.Dir.cwd().createDirPath(io, full_dir);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ full_dir, "child" }), .data = "x" });

    const result = try runPickerOnInit(allocator, parent, &.{
        .{ .waitFor = "Select an empty directory for new media database:", .keys = "\x1b[B\r" },
        .{ .waitFor = "Enter full directory path:", .keys = try std.mem.concat(allocator, u8, &.{ full_dir, "\r" }) },
    });

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "can't use this directory because it's not empty") != null);
    try std.testing.expect(result.exitCode != 0);
}

test "a subdirectory name that is blank or has a forbidden character is refused, then a valid one is taken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try makePlainDir(allocator, "picker-blank-name");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};

    // \x15 is readline's kill-line, which clears the refused value so a valid one can be typed after it. The subdirectory
    // is the first of the choices (subdirectory, full path, cancel).
    const blank = try runPickerOnSummary(allocator, parent, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\r" },
        .{ .waitFor = "Enter name for subdirectory:", .keys = "   \r\x15photos\r" },
    });
    try std.testing.expect(std.mem.indexOf(u8, blank.stdout, "Directory name is required") != null);
    try std.testing.expect(node_utils.fs.pathExists(io, try std.fs.path.join(allocator, &.{ parent, "photos" })));

    const forbidden = try runPickerOnSummary(allocator, parent, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\r" },
        .{ .waitFor = "Enter name for subdirectory:", .keys = "a|b\r\x15pictures\r" },
    });
    try std.testing.expect(std.mem.indexOf(u8, forbidden.stdout, "Directory name contains invalid characters") != null);
    try std.testing.expect(node_utils.fs.pathExists(io, try std.fs.path.join(allocator, &.{ parent, "pictures" })));
}

test "a subdirectory name that is already a directory is refused" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try makePlainDir(allocator, "picker-taken-name");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ parent, "taken" }));

    const result = try runPickerOnSummary(allocator, parent, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\r" },
        .{ .waitFor = "Enter name for subdirectory:", .keys = "taken\r\x15free\r" },
    });

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Directory already exists") != null);
    try std.testing.expect(node_utils.fs.pathExists(io, try std.fs.path.join(allocator, &.{ parent, "free" })));
}

test "a full path of only whitespace is refused as a path that was not given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try makePlainDir(allocator, "picker-blank-path");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    const wanted = try std.fs.path.join(allocator, &.{ parent, "wanted" });

    const result = try runPickerOnSummary(allocator, parent, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\x1b[B\r" },
        .{ .waitFor = "Enter full directory path:", .keys = try std.mem.concat(allocator, u8, &.{ "  \r\x15", wanted, "\r" }) },
    });

    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Path is required") != null);
    try std.testing.expect(node_utils.fs.pathExists(io, wanted));
}

test "pickDirectory reports the failure to create a subdirectory in a directory that cannot be written to" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const read_only = try makePlainDir(allocator, "picker-read-only-subdir");
    defer restoreWrite(read_only);
    defer std.Io.Dir.cwd().deleteTree(io, read_only) catch {};

    _ = try makeReadOnlyDir(read_only);
    const created = try std.fs.path.join(allocator, &.{ read_only, "photos" });
    const result = try runPickerOnSummary(allocator, read_only, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\r" },
        .{ .waitFor = "Enter name for subdirectory:", .keys = "photos\r" },
    });

    // The name passes validation because nothing is there yet, and it is the mkdir that fails.
    const expected = try std.fmt.allocPrint(allocator, "Failed to create directory: EACCES: permission denied, mkdir '{s}'", .{created});
    if (builtin.os.tag != .windows) {
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, expected) != null);
        try std.testing.expect(!node_utils.fs.pathExists(io, created));
    }
}

test "a full path under a directory that cannot be written to fails with the message Node gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const read_only = try makePlainDir(allocator, "picker-read-only-full");
    defer restoreWrite(read_only);
    defer std.Io.Dir.cwd().deleteTree(io, read_only) catch {};

    _ = try makeReadOnlyDir(read_only);
    const created = try std.fs.path.join(allocator, &.{ read_only, "photos" });
    const result = try runPickerOnSummary(allocator, read_only, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\x1b[B\r" },
        .{ .waitFor = "Enter full directory path:", .keys = try std.mem.concat(allocator, u8, &.{ created, "\r" }) },
    });

    if (builtin.os.tag != .windows) {
        const expected = try std.fmt.allocPrint(allocator, "Failed to create directory: EACCES: permission denied, mkdir '{s}'", .{created});
        try std.testing.expect(std.mem.indexOf(u8, result.stdout, expected) != null);
        try std.testing.expect(!node_utils.fs.pathExists(io, created));
    }
}

//
// A subdirectory under a path whose ancestor is a file: the name passes validation and the mkdir is what fails,
// which is the same failure as a directory that cannot be written to but does not depend on permissions.
//
test "a subdirectory under a path that is a file fails to be created" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parent = try makePlainDir(allocator, "picker-under-a-file");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    const file_path = try std.fs.path.join(allocator, &.{ parent, "afile" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file_path, .data = "x" });
    const under_the_file = try std.fs.path.join(allocator, &.{ file_path, "photos" });

    const result = try runPickerOnSummary(allocator, under_the_file, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\r" },
        .{ .waitFor = "Enter name for subdirectory:", .keys = "photos\r" },
    });

    const expected = try std.fmt.allocPrint(allocator, "Failed to create directory: ENOTDIR: not a directory, mkdir '{s}'", .{try std.fs.path.join(allocator, &.{ under_the_file, "photos" })});
    if (std.mem.indexOf(u8, result.stdout, expected) == null) {
        std.debug.print("expected {s} in:\n{s}\n", .{ expected, result.stdout });
        return error.TestUnexpectedResult;
    }
}

//
// The shape to check arguments against: one field of every kind the psi tools use.
//
const every_kind_of_field = [_]input_schema.IField{
    .{
        .name = "name",
        .fieldType = .string,
        .presence = .required,
    },
    .{
        .name = "flag",
        .fieldType = .boolean,
        .presence = .optional,
    },
    .{
        .name = "count",
        .fieldType = .{ .integer = .{ .minimum = 1, .maximum = 3 } },
        .presence = .{ .default = .{ .number = 2 } },
    },
    .{
        .name = "names",
        .fieldType = .stringArray,
        .presence = .{ .default = .{ .array = &.{} } },
    },
    .{
        .name = "kind",
        .fieldType = .{ .enumeration = &.{ "one", "two" } },
        .presence = .{ .default = .{ .string = "one" } },
    },
};

test "parseArguments fills in every default and leaves out the optional fields that were not given" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const arguments = (try jsonParse(allocator, "{\"name\":\"given\"}")).document;
    const parsed = try input_schema.parseArguments(allocator, &every_kind_of_field, arguments);
    try std.testing.expect(parsed == .success);
    const with_defaults =
        \\{"name":"given","count":2,"names":[],"kind":"one"}
    ;
    try std.testing.expectEqualStrings(with_defaults, try mcp_protocol.stringifyCompact(allocator, .{ .document = parsed.success }));

    // An unknown field is dropped, and an optional field given as null is still checked: .optional() means it may be
    // left out, not that null is allowed for it.
    const with_extra = (try jsonParse(allocator, "{\"name\":\"a\",\"flag\":null,\"extra\":1}")).document;
    const dropped = try input_schema.parseArguments(allocator, &every_kind_of_field, with_extra);
    try std.testing.expect(dropped == .failure);
    const expected =
        \\[
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "boolean",
        \\    "received": "null",
        \\    "path": [
        \\      "flag"
        \\    ],
        \\    "message": "Expected boolean, received null"
        \\  }
        \\]
    ;
    try std.testing.expectEqualStrings(expected, try input_schema.formatIssues(allocator, dropped.failure));
}

test "parseArguments with no arguments at all reports the input itself missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A shape with fields is a zod 3 object: the issue says Required at the root.
    const with_fields = try input_schema.parseArguments(allocator, &every_kind_of_field, null);
    try std.testing.expect(with_fields == .failure);
    const required_object =
        \\[
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "object",
        \\    "received": "undefined",
        \\    "path": [],
        \\    "message": "Required"
        \\  }
        \\]
    ;
    try std.testing.expectEqualStrings(required_object, try input_schema.formatIssues(allocator, with_fields.failure));

    // A shape without fields is the SDK's zod 4 object schema, whose issue is worded the zod 4 way.
    const without_fields = try input_schema.parseArguments(allocator, &.{}, null);
    try std.testing.expect(without_fields == .failure);
    const invalid_object =
        \\[
        \\  {
        \\    "expected": "object",
        \\    "code": "invalid_type",
        \\    "path": [],
        \\    "message": "Invalid input: expected object, received undefined"
        \\  }
        \\]
    ;
    try std.testing.expectEqualStrings(invalid_object, try input_schema.formatIssues(allocator, without_fields.failure));
}

test "parseArguments reports a missing required field as Required and one out of range by its bound" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const missing = (try jsonParse(allocator, "{}")).document;
    const result = try input_schema.parseArguments(allocator, &every_kind_of_field, missing);
    try std.testing.expect(result == .failure);
    const required_name =
        \\[
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "string",
        \\    "received": "undefined",
        \\    "path": [
        \\      "name"
        \\    ],
        \\    "message": "Required"
        \\  }
        \\]
    ;
    try std.testing.expectEqualStrings(required_name, try input_schema.formatIssues(allocator, result.failure));

    // An integer past the maximum gets that one check; the minimum is not reported as well.
    const out_of_range = (try jsonParse(allocator, "{\"name\":\"a\",\"count\":9}")).document;
    const ranged = try input_schema.parseArguments(allocator, &every_kind_of_field, out_of_range);
    try std.testing.expect(ranged == .failure);
    const too_big =
        \\[
        \\  {
        \\    "code": "too_big",
        \\    "maximum": 3,
        \\    "type": "number",
        \\    "inclusive": true,
        \\    "exact": false,
        \\    "message": "Number must be less than or equal to 3",
        \\    "path": [
        \\      "count"
        \\    ]
        \\  }
        \\]
    ;
    try std.testing.expectEqualStrings(too_big, try input_schema.formatIssues(allocator, ranged.failure));

    // A boolean and an array of the wrong type are both named by what they received.
    const wrong_types = (try jsonParse(allocator, "{\"name\":\"a\",\"flag\":\"no\",\"names\":\"x\"}")).document;
    const named = try input_schema.parseArguments(allocator, &every_kind_of_field, wrong_types);
    try std.testing.expect(named == .failure);
    const wrong_types_expected =
        \\[
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "boolean",
        \\    "received": "string",
        \\    "path": [
        \\      "flag"
        \\    ],
        \\    "message": "Expected boolean, received string"
        \\  },
        \\  {
        \\    "code": "invalid_type",
        \\    "expected": "array",
        \\    "received": "string",
        \\    "path": [
        \\      "names"
        \\    ],
        \\    "message": "Expected array, received string"
        \\  }
        \\]
    ;
    try std.testing.expectEqualStrings(wrong_types_expected, try input_schema.formatIssues(allocator, named.failure));
}

test "toJsonSchema writes a schema for every kind of field a tool declares" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const expected =
        \\{"type":"object","properties":{"name":{"type":"string"},"flag":{"type":"boolean"},"count":{"type":"integer","minimum":1,"maximum":3,"default":2},"names":{"type":"array","items":{"type":"string"},"default":[]},"kind":{"type":"string","enum":["one","two"],"default":"one"}},"required":["name"],"additionalProperties":false,"$schema":"http://json-schema.org/draft-07/schema#"}
    ;
    try std.testing.expectEqualStrings(expected, try mcp_protocol.stringifyCompact(allocator, try input_schema.toJsonSchema(allocator, &every_kind_of_field)));
}

test "stringifyCompact writes a number JSON cannot write as null, and leaves an undefined field out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var not_numbers: [2]BsonValue = .{
        .{ .number = std.math.nan(f64) },
        .{ .number = std.math.inf(f64) },
    };
    try std.testing.expectEqualStrings(
        "[null,null]"
    , try mcp_protocol.stringifyCompact(allocator, .{ .array = &not_numbers }));

    // A value JSON has no form for at all (a date) is null.
    var a_date: [1]BsonValue = .{.{ .date = 0 }};
    try std.testing.expectEqualStrings(
        "[null]"
    , try mcp_protocol.stringifyCompact(allocator, .{ .array = &a_date }));

    // An undefined field of an object is left out entirely, as JSON.stringify leaves it out.
    var document: BsonDocument = .empty;
    try document.put(allocator, "kept", .{ .string = "yes" });
    try document.put(allocator, "gone", .undefined);
    try document.put(allocator, "alsoGone", .undefined);
    const kept_only =
        \\{"kept":"yes"}
    ;
    try std.testing.expectEqualStrings(kept_only, try mcp_protocol.stringifyCompact(allocator, .{ .document = document }));
}

test "requireDatabase answers with the no-database result when nothing is open" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tool_context: mcp_types.IMcpToolContext = .{
        .uuidGenerator = undefined,
        .timestampProvider = undefined,
        .sessionId = "session",
        .options = .{},
        .allocator = allocator,
    };
    try std.testing.expect(tool_context.getDatabase() == null);

    const guard = try mcp_result.requireDatabase(allocator, &tool_context);
    try std.testing.expect(guard == .result);
    try std.testing.expectEqual(@as(usize, 1), guard.result.content.len);
    try std.testing.expectEqualStrings("text", guard.result.content[0].type);
    try std.testing.expectEqualStrings(mcp_result.NO_DATABASE_MESSAGE, guard.result.content[0].text);
    // The guard is an ordinary result, not an error of the tool: isError is left out.
    try std.testing.expect(guard.result.isError == null);
}

test "toJsValue converts the shapes a tool hands it, and leaves an absent optional out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // A struct becomes an object with its fields in order, an enum its name, a slice an array, and an optional that
    // is absent becomes undefined, which JSON.stringify leaves out.
    const Sample = struct {
        text: []const u8,
        count: u32,
        ratio: f64,
        flag: bool,
        missing: ?[]const u8,
        present: ?u32,
        kind: enum { original, display },
        items: []const []const u8,
    };
    const sample: Sample = .{
        .text = "hi",
        .count = 3,
        .ratio = 0.5,
        .flag = false,
        .missing = null,
        .present = 7,
        .kind = .display,
        .items = &.{ "a", "b" },
    };
    const as_an_object =
        \\{"text":"hi","count":3,"ratio":0.5,"flag":false,"present":7,"kind":"display","items":["a","b"]}
    ;
    try std.testing.expectEqualStrings(as_an_object, try mcp_protocol.stringifyCompact(allocator, try mcp_result.toJsValue(allocator, sample)));

    // A whole optional that is absent becomes undefined, which an array writes as null.
    const absent: ?u32 = null;
    var one_element: [1]BsonValue = .{try mcp_result.toJsValue(allocator, absent)};
    try std.testing.expectEqualStrings(
        "[null]"
    , try mcp_protocol.stringifyCompact(allocator, .{ .array = &one_element }));
}

test "intro, cancel and outro write the line clack writes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    var output = std.Io.Writer.Allocating.init(allocator);
    const options: prompts.CommonOptions = .{ .output = &output.writer };

    try prompts.intro(io, "Photosphere", options);
    try prompts.outro(io, "all done", options);
    try prompts.cancel(allocator, io, "stopped", options);

    // The bar end is a space in this copy of clack, and cancel writes it, then two spaces, then the message and a
    // blank line.
    try std.testing.expectEqualStrings("\nPhotosphere\n\nall done\n   stopped\n\n", output.written());
}

test "limitOptions clamps a maxItems below five and hides nothing when everything fits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(false);
    defer cli.picocolors.setColorSupportOverride(null);
    const Style = struct {
        fn style(style_allocator: std.mem.Allocator, context: *anyopaque, option: []const u8, active: bool) anyerror![]const u8 {
            _ = context;
            return std.fmt.allocPrint(style_allocator, "{s}{s}", .{ if (active) ">" else " ", option });
        }
    };
    var context: u8 = 0;
    const options = [_][]const u8{ "0", "1", "2", "3", "4", "5", "6", "7", "8", "9" };

    // maxItems is raised to the floor of 5, so ten options still show a bottom ellipsis with the cursor at the top.
    const clamped = try prompts.limitOptions([]const u8, allocator, .{
        .options = &options,
        .maxItems = 1,
        .cursor = 0,
        .rows = 10,
        .style = Style.style,
        .styleContext = &context,
    });
    try std.testing.expectEqual(@as(usize, 5), clamped.len);
    try std.testing.expectEqualStrings(">0", clamped[0]);
    try std.testing.expectEqualStrings("...", clamped[4]);

    // Three options and six rows: everything fits, so no ellipsis at all.
    const few = [_][]const u8{ "a", "b", "c" };
    const all = try prompts.limitOptions([]const u8, allocator, .{
        .options = &few,
        .maxItems = null,
        .cursor = 2,
        .rows = 10,
        .style = Style.style,
        .styleContext = &context,
    });
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqualStrings(" a", all[0]);
    try std.testing.expectEqualStrings(">c", all[2]);

    // The cursor at the bottom: the window has moved up, so the ellipsis is at the top and not at the bottom.
    const at_the_bottom = try prompts.limitOptions([]const u8, allocator, .{
        .options = &options,
        .maxItems = null,
        .cursor = 9,
        .rows = 10,
        .style = Style.style,
        .styleContext = &context,
    });
    try std.testing.expectEqual(@as(usize, 6), at_the_bottom.len);
    try std.testing.expectEqualStrings("...", at_the_bottom[0]);
    try std.testing.expectEqualStrings(" 5", at_the_bottom[1]);
    try std.testing.expectEqualStrings(">9", at_the_bottom[5]);

    // A terminal with fewer than four rows leaves no room for options at all (rows - 4 clamps to 0).
    const no_room = try prompts.limitOptions([]const u8, allocator, .{
        .options = &options,
        .maxItems = null,
        .cursor = 9,
        .rows = 2,
        .style = Style.style,
        .styleContext = &context,
    });
    try std.testing.expectEqual(@as(usize, 0), no_room.len);
}

test "symbol gives each prompt state its own colour and symbol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    cli.picocolors.setColorSupportOverride(true);
    defer cli.picocolors.setColorSupportOverride(null);

    // A terminal without unicode support gets the ASCII fallbacks, which is what the TypeScript does too
    // (`is-unicode-supported` is false there). The build runner's TERM decides it, so the symbols are read from
    // the same `unicodeOr` the library uses rather than hardcoded to the Unicode ones.
    const stepActive = common.unicodeOr("\u{25C6}", "*");
    const stepCancel = common.unicodeOr("\u{25A0}", "x");
    const stepError = common.unicodeOr("\u{25B2}", "x");
    const stepSubmit = common.unicodeOr("\u{25C7}", "o");

    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "\x1b[36m{s}\x1b[39m", .{stepActive}), try common.symbol(allocator, .initial));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "\x1b[36m{s}\x1b[39m", .{stepActive}), try common.symbol(allocator, .active));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "\x1b[31m{s}\x1b[39m", .{stepCancel}), try common.symbol(allocator, .cancel));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "\x1b[33m{s}\x1b[39m", .{stepError}), try common.symbol(allocator, .@"error"));
    try std.testing.expectEqualStrings(try std.fmt.allocPrint(allocator, "\x1b[32m{s}\x1b[39m", .{stepSubmit}), try common.symbol(allocator, .submit));
}

test "getColumns is 80 when stdout is not a terminal, and stdoutColumns is then null" {
    // The build runner gives the tests a pipe for stdout.
    try std.testing.expect(cli.tty.columns(cli.tty.stdout_fd) == null);
    try std.testing.expect(clack_core.utils.stdoutColumns() == null);
    try std.testing.expectEqual(@as(usize, 80), clack_core.utils.getColumns());
    try std.testing.expect(prompts.limit_options.stdoutRows() == null);
}

test "isCI is true only for CI=true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var environ_map = std.process.Environ.Map.init(arena.allocator());
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    try std.testing.expect(!common.isCI());
    try environ_map.put("CI", "1");
    try std.testing.expect(!common.isCI());
    try environ_map.put("CI", "true");
    try std.testing.expect(common.isCI());
}

test "parseWatchInterval refuses an interval that is empty, infinite or not a number" {
    // Number('') is 0 and Number('Infinity') is not finite, so both are refused the way a mistyped interval is.
    for ([_][]const u8{ "", "   ", "Infinity", "-Infinity", "hourly", "1e999" }) |refused| {
        try std.testing.expectError(error.Thrown, cli.sync_watch.parseWatchInterval(refused));
        try std.testing.expect(std.mem.indexOf(u8, utils.errors.lastErrorMessage(), "positive number of seconds") != null);
    }

    // A fraction and a value past the integer range are both taken as given.
    try std.testing.expectEqual(@as(f64, 0.5), try cli.sync_watch.parseWatchInterval("0.5"));
    try std.testing.expectEqual(@as(f64, 1e21), try cli.sync_watch.parseWatchInterval("1e21"));
}

//
// Points the environment at a news feed of the given YAML and a config directory of its own.
//
fn useNewsFeed(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map, root: []const u8, feed: []const u8) !void {
    const config_dir = try std.fmt.allocPrint(allocator, "{s}/config", .{root});
    try std.Io.Dir.cwd().createDirPath(io, config_dir);
    try environ_map.put("PHOTOSPHERE_CONFIG_DIR", config_dir);
    const feed_path = try std.fmt.allocPrint(allocator, "{s}/news.yaml", .{root});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = feed_path, .data = feed });
    try environ_map.put("PHOTOSPHERE_NEWS_URL", try helpers.fileUrl(allocator, feed_path));
}

//
// A feed of three items, none of which has a link or an action.
//
const three_plain_items =
    \\items:
    \\  - id: one
    \\    message: First
    \\  - id: two
    \\    message: Second
    \\  - id: three
    \\    message: Third
    \\
;

test "checkForNews returns the oldest unseen item, marks it shown, then the next one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "check-for-news-order");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var environ_map = std.process.Environ.Map.init(allocator);
    try useNewsFeed(allocator, &environ_map, root, three_plain_items);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    // The oldest unseen item first, one per call, and nothing once they have all been shown.
    try std.testing.expectEqualStrings("one", (cli.check_for_news.checkForNews(allocator, io).?).id);
    try std.testing.expectEqualStrings("two", (cli.check_for_news.checkForNews(allocator, io).?).id);
    try std.testing.expectEqualStrings("three", (cli.check_for_news.checkForNews(allocator, io).?).id);
    try std.testing.expect(cli.check_for_news.checkForNews(allocator, io) == null);
}

test "getAllNews marks only the items already shown, and is empty when the feed cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "all-news-seen");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var environ_map = std.process.Environ.Map.init(allocator);
    try useNewsFeed(allocator, &environ_map, root, three_plain_items);
    node_utils.process_env.setEnvironMap(&environ_map);
    defer node_utils.process_env.setEnvironMap(null);

    // Nothing shown yet.
    const all = cli.check_for_news.getAllNews(allocator, io);
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expect(!all[0].seen);
    try std.testing.expect(!all[1].seen);

    // After one item has been shown, only that one is marked.
    _ = cli.check_for_news.checkForNews(allocator, io);
    const partly = cli.check_for_news.getAllNews(allocator, io);
    try std.testing.expectEqual(@as(usize, 3), partly.len);
    try std.testing.expect(partly[0].seen);
    try std.testing.expect(!partly[1].seen);
    try std.testing.expect(!partly[2].seen);

    // markNewsAsShown with no ids records nothing, so the marks do not change.
    cli.check_for_news.markNewsAsShown(allocator, io, &.{});
    const unchanged = cli.check_for_news.getAllNews(allocator, io);
    try std.testing.expect(unchanged[0].seen);
    try std.testing.expect(!unchanged[1].seen);

    // A feed that cannot be read gives an empty feed and no item, rather than an error.
    try environ_map.put("PHOTOSPHERE_NEWS_URL", try helpers.fileUrl(allocator, try std.fmt.allocPrint(allocator, "{s}/no-such-feed.yaml", .{root})));
    try std.testing.expectEqual(@as(usize, 0), (cli.check_for_news.getAllNews(allocator, io)).len);
    try std.testing.expect(cli.check_for_news.checkForNews(allocator, io) == null);
}

test "process_argv hands back the user arguments, and nothing when only the executable is set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const previous = cli.process_argv.getArgv();
    defer cli.process_argv.setArgv(previous);

    cli.process_argv.setArgv(&.{});
    try std.testing.expectEqual(@as(usize, 0), cli.process_argv.getArgv().len);
    try std.testing.expectEqual(@as(usize, 0), cli.process_argv.userArgs().len);

    cli.process_argv.setArgv(&.{"psi"});
    try std.testing.expectEqual(@as(usize, 1), cli.process_argv.getArgv().len);
    try std.testing.expectEqual(@as(usize, 0), cli.process_argv.userArgs().len);

    // process.argv.slice(2) in TypeScript starts past the runtime and the script, which here is past argv[0].
    cli.process_argv.setArgv(&.{ "psi", "verify", "--db", "x" });
    try std.testing.expectEqual(@as(usize, 3), cli.process_argv.userArgs().len);
    try std.testing.expectEqualStrings("verify", cli.process_argv.userArgs()[0]);
    try std.testing.expectEqualStrings("--db", cli.process_argv.userArgs()[1]);
    try std.testing.expectEqualStrings("x", cli.process_argv.userArgs()[2]);
}