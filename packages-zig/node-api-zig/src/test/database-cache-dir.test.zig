const std = @import("std");
const node_api = @import("node-api-zig");
const node_utils = @import("node-utils-zig");
const database_cache_dir = node_api.database_cache_dir;
const getDatabaseCacheDir = database_cache_dir.getDatabaseCacheDir;
const getImportRecordPath = database_cache_dir.getImportRecordPath;
const path = node_utils.path;

test "sits inside the database cache directory, beside everything else this machine works out about a database" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The record is not in the database. It is one more thing the machine knows about it, so it
    // goes where the hash cache goes.
    try std.testing.expectEqualStrings(try getDatabaseCacheDir(allocator, "/photos/one"), path.dirname(try getImportRecordPath(allocator, "/photos/one")));
}

test "names the record apart from anything else in that directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("imports.dat", path.basename(try getImportRecordPath(allocator, "/photos/one")));
}

test "gives two databases two different records" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // Importing into one database must not show up as an import into another: each is this
    // machine's account of what it put into that database and nothing else.
    try std.testing.expect(!std.mem.eql(u8, try getImportRecordPath(allocator, "/photos/one"), try getImportRecordPath(allocator, "/photos/two")));
}

test "gives the same database the same record every time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // The record has to be found again on the next run, or a restart would lose the history.
    try std.testing.expectEqualStrings(try getImportRecordPath(allocator, "/photos/one"), try getImportRecordPath(allocator, "/photos/one"));
}

test "makes a path out of a database path that could never be one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    // An S3 database path has colons and slashes in it, which cannot be pasted into a directory
    // name on any platform, and an S3 database is exactly the case this move was made for.
    const name = path.basename(try getDatabaseCacheDir(allocator, "s3:my-bucket:/photos/db"));
    try std.testing.expect(name.len > 0);
    for (name) |character| {
        try std.testing.expect(std.ascii.isDigit(character) or (character >= 'a' and character <= 'f'));
    }
}
