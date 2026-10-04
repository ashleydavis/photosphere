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
    const root = try helpers.makeTempDir(allocator, "picker-full-path");
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const database = try std.fs.path.join(allocator, &.{ root, "db" });
    const plain = try helpers.makeTempDir(allocator, "picker-cwd");
    defer std.Io.Dir.cwd().deleteTree(io, plain) catch {};
    const created = try helpers.runPsiWithPromptsIn(allocator, .inherit, &.{ "init", "--db", database, "--yes" }, &.{});
    try std.testing.expectEqual(@as(u8, 0), created.exitCode);

    // The current directory is not a database, so the options are: subdirectory, full path, cancel. The path typed is the
    // database the command goes on to open, which a command given the wrong path would not find.
    const result = try helpers.runPsiWithPromptsIn(allocator, .inherit, &.{ "summary", "--cwd", plain }, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\x1b[B\r" },
        .{ .waitFor = "Enter full directory path:", .keys = try std.mem.concat(allocator, u8, &.{ database, "\r" }) },
    });
    try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Database Summary") != null);
}

test "pickDirectory creates a subdirectory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const parent = try helpers.makeTempDir(allocator, "picker-subdirectory");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};

    // `psi init` only shows the picker when its directory is not empty. The choices are subdirectory, full path, cancel.
    // An invalid name is rejected first, then the encryption question is declined.
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = try std.fs.path.join(allocator, &.{ parent, "occupied" }), .data = "x" });
    const result = try helpers.runPsiWithPromptsIn(allocator, .{ .path = parent }, &.{"init"}, &.{
        .{ .waitFor = "Select an empty directory for new media database:", .keys = "\r" },
        .{ .waitFor = "Enter name for subdirectory:", .keys = "a/b\r\x15photos\r" },
        .{ .waitFor = "Would you like to encrypt your database?", .keys = "n" },
    });
    try std.testing.expectEqual(@as(u8, 0), result.exitCode);

    // The path the picker gave back is the relative one, which is where the database was created.
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "Created new media file database in ./photos\n") != null);
    try std.testing.expect(@import("node-utils-zig").fs.pathExists(io, try std.fs.path.join(allocator, &.{ parent, "photos", ".db", "files.dat" })));
}

test "a command cancelled in the picker with Ctrl+C or by arrowing up to Cancel selects no directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const plain = try helpers.makeTempDir(allocator, "picker-psi-cancel");
    defer std.Io.Dir.cwd().deleteTree(io, plain) catch {};

    // Ctrl+C at the prompt.
    const interrupted = try helpers.runPsiWithPromptsIn(allocator, .inherit, &.{ "summary", "--cwd", plain }, &.{.{ .waitFor = "Select an existing media database directory:", .keys = "\x03" }});
    try std.testing.expect(std.mem.indexOf(u8, interrupted.stdout, "No directory selected") != null);
    try std.testing.expectEqual(@as(u8, 1), interrupted.exitCode);

    // Up from the first choice wraps round to the last, which is Cancel.
    const wrapped = try helpers.runPsiWithPromptsIn(allocator, .inherit, &.{ "summary", "--cwd", plain }, &.{.{ .waitFor = "Select an existing media database directory:", .keys = "\x1b[A\r" }});
    try std.testing.expect(std.mem.indexOf(u8, wrapped.stdout, "No directory selected") != null);
    try std.testing.expectEqual(@as(u8, 1), wrapped.exitCode);
}

test "pickDirectory reports a failed mkdir with the message Node gives" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    const parent = try helpers.makeTempDir(allocator, "picker-mkdir");
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch {};
    const filePath = try std.fs.path.join(allocator, &.{ parent, "afile" });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = filePath, .data = "x" });

    // A full path under an existing file: mkdir fails with ENOTDIR, naming the path it was given, and no directory is
    // picked.
    const failed = try helpers.runPsiWithPromptsIn(allocator, .inherit, &.{ "summary", "--cwd", parent }, &.{
        .{ .waitFor = "Select an existing media database directory:", .keys = "\x1b[B\r" },
        .{ .waitFor = "Enter full directory path:", .keys = try std.mem.concat(allocator, u8, &.{ filePath, "/x\r" }) },
    });
    try std.testing.expect(std.mem.indexOf(u8, failed.stdout, "No directory selected") != null);
    try std.testing.expectEqual(@as(u8, 1), failed.exitCode);
    const expected = try std.fmt.allocPrint(allocator, "Failed to create directory: ENOTDIR: not a directory, mkdir '{s}'", .{try std.fs.path.join(allocator, &.{ filePath, "x" })});
    if (std.mem.indexOf(u8, failed.stdout, expected) == null) {
        std.debug.print("expected {s} in:\n{s}\n", .{ expected, failed.stdout });
        return error.TestUnexpectedResult;
    }
}
