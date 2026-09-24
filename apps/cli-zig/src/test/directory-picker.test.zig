const std = @import("std");
const cli = @import("cli-zig");
const helpers = @import("test-helpers.zig");
const directory_picker = cli.directory_picker;
const prompts = cli.prompts;

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
// Makes the prompts read the keys and write to a discarded buffer.
//
fn typeKeys(allocator: std.mem.Allocator, keys: []const u8) !void {
    const input = try helpers.chunkedInput(allocator, try helpers.splitKeys(allocator, keys));
    const output = try allocator.create(std.Io.Writer.Allocating);
    output.* = std.Io.Writer.Allocating.init(allocator);
    prompts.common.setDefaultStreamsForTesting(.{ .input = input, .output = &output.writer });
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
    defer prompts.common.setDefaultStreamsForTesting(null);

    // The current directory is not a database, so the options are: subdirectory, full path, cancel.
    try typeKeys(allocator, try std.mem.concat(allocator, u8, &.{ "\x1b[B\r", database, "\r" }));
    try std.testing.expectEqualStrings(database, try directory_picker.getDirectoryForCommand(allocator, io, .existing, false, plain));
}

test "pickDirectory returns null when cancelled and '.' for the current directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const database = try makeDatabase(allocator, "picker-pick");
    defer std.Io.Dir.cwd().deleteTree(io, database) catch {};
    defer prompts.common.setDefaultStreamsForTesting(null);

    try typeKeys(allocator, "\r");
    try std.testing.expectEqualStrings(".", (try directory_picker.pickDirectory(allocator, io, "Pick:", database, directory_picker.validateExistingDatabase)).?);

    try typeKeys(allocator, "\x03");
    try std.testing.expect(try directory_picker.pickDirectory(allocator, io, "Pick:", database, directory_picker.validateExistingDatabase) == null);

    try typeKeys(allocator, "\x1b[A\r");
    try std.testing.expect(try directory_picker.pickDirectory(allocator, io, "Pick:", database, null) == null);
}

test "pickDirectory creates a subdirectory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const parent = try helpers.makeTempDir(allocator, "picker-subdirectory");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    defer prompts.common.setDefaultStreamsForTesting(null);

    // Current directory, subdirectory, full path, cancel (no validator). An invalid name is rejected first.
    try typeKeys(allocator, "\x1b[B\ra/b\r\x15photos\r");
    try std.testing.expectEqualStrings("./photos", (try directory_picker.pickDirectory(allocator, io, "Pick:", parent, null)).?);
    try std.testing.expect(@import("node-utils-zig").fs.pathExists(io, try std.fs.path.join(allocator, &.{ parent, "photos" })));
}
