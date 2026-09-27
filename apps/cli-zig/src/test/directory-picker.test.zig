const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const directory_picker = cli.directory_picker;

//
// Creates a directory that looks like a media database (.db/files.dat).
//
fn makeDatabase(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    const dir = try helpers.makeTempDir(allocator, name);
    const dbDir = try std.fs.path.join(allocator, &.{ dir, ".db" });
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dbDir);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = try std.fs.path.join(allocator, &.{ dbDir, "files.dat" }), .data = "x" });
    return dir;
}

//
// Runs a directory picker scenario of the test driver, typing the keys, and returns the directory it returned.
//
fn drive(allocator: std.mem.Allocator, scenarioArguments: []const []const u8, prompts: []const helpers.IPromptKeys) !?[]const u8 {
    var environment = std.process.Environ.Map.init(allocator);
    const result = try helpers.runTestDriver(allocator, scenarioArguments, prompts, &environment);
    return helpers.parseDriverResult(?[]const u8, allocator, result);
}

test "isMediaDatabase detects files.dat or tree.dat under .db" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try makeDatabase(allocator, "picker-db");
    defer std.Io.Dir.cwd().deleteTree(io, database) catch {};
    try std.testing.expect(try directory_picker.isMediaDatabase(allocator, io, database));

    const empty = try helpers.makeTempDir(allocator, "picker-empty");
    defer std.Io.Dir.cwd().deleteTree(io, empty) catch {};
    try std.testing.expect(!try directory_picker.isMediaDatabase(allocator, io, empty));
    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ empty, ".db" }));
    try std.testing.expect(!try directory_picker.isMediaDatabase(allocator, io, empty));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ empty, ".db", "tree.dat" }), .data = "x" });
    try std.testing.expect(try directory_picker.isMediaDatabase(allocator, io, empty));
}

test "validateExistingDatabase explains why a directory is not a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try makeDatabase(allocator, "picker-validate");
    defer std.Io.Dir.cwd().deleteTree(io, database) catch {};
    try std.testing.expect(try directory_picker.validateExistingDatabase(allocator, io, database) == null);
    try std.testing.expectEqualStrings("Directory does not exist", (try directory_picker.validateExistingDatabase(allocator, io, "/no/such/dir/anywhere")).?);
    const parent = std.fs.path.dirname(database).?;
    _ = parent;
    const plain = try helpers.makeTempDir(allocator, "picker-plain");
    defer std.Io.Dir.cwd().deleteTree(io, plain) catch {};
    try std.testing.expectEqualStrings("Directory is not a valid Photosphere media database", (try directory_picker.validateExistingDatabase(allocator, io, plain)).?);
}

test "getDirectoryForCommand returns the current directory when it is a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try makeDatabase(allocator, "picker-current");
    defer std.Io.Dir.cwd().deleteTree(io, database) catch {};
    try std.testing.expectEqualStrings(database, try directory_picker.getDirectoryForCommand(allocator, io, .existing, true, database));

    const empty = try helpers.makeTempDir(allocator, "picker-init");
    defer std.Io.Dir.cwd().deleteTree(io, empty) catch {};
    try std.testing.expectEqualStrings(empty, try directory_picker.getDirectoryForCommand(allocator, io, .init, true, empty));
}

test "getDirectoryForCommand lets the user enter the path of a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try makeDatabase(allocator, "picker-full-path");
    defer std.Io.Dir.cwd().deleteTree(io, database) catch {};
    const plain = try helpers.makeTempDir(allocator, "picker-cwd");
    defer std.Io.Dir.cwd().deleteTree(io, plain) catch {};

    // The current directory is not a database, so the options are: subdirectory, full path, cancel.
    try std.testing.expectEqualStrings(database, (try drive(allocator, &.{ "get-directory-for-command", "existing", plain }, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\x1b[B\r" },
        .{ .waitFor = "Enter full directory path:", .keys = try std.mem.concat(allocator, u8, &.{ database, "\r" }) },
    })).?);
}

test "pickDirectory returns null when cancelled and '.' for the current directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try makeDatabase(allocator, "picker-pick");
    defer std.Io.Dir.cwd().deleteTree(io, database) catch {};

    try std.testing.expectEqualStrings(".", (try drive(allocator, &.{ "pick-directory", "Pick:", database, "true" }, &.{.{ .waitFor = "Pick:", .keys = "\r" }})).?);

    try std.testing.expect(try drive(allocator, &.{ "pick-directory", "Pick:", database, "true" }, &.{.{ .waitFor = "Pick:", .keys = "\x03" }}) == null);

    try std.testing.expect(try drive(allocator, &.{ "pick-directory", "Pick:", database, "false" }, &.{.{ .waitFor = "Pick:", .keys = "\x1b[A\r" }}) == null);
}

test "pickDirectory creates a subdirectory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const parent = try helpers.makeTempDir(allocator, "picker-subdirectory");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};

    // Current directory, subdirectory, full path, cancel (no validator). An invalid name is rejected first.
    try std.testing.expectEqualStrings("./photos", (try drive(allocator, &.{ "pick-directory", "Pick:", parent, "false" }, &.{
        .{ .waitFor = "Pick:", .keys = "\x1b[B\r" },
        .{ .waitFor = "Enter name for subdirectory:", .keys = "a/b\r\x15photos\r" },
    })).?);
    try std.testing.expect(@import("node-utils-zig").fs.pathExists(io, try std.fs.path.join(allocator, &.{ parent, "photos" })));
}
