//
// Tests for parseS3ListPath (port of src/tests/s3-path.test.ts).
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const parseS3ListPath = storage_zig.s3_path.parseS3ListPath;

//
// Checks the bucket and key a path is split into.
//
fn expectParts(path: []const u8, expectedBucket: []const u8, expectedKey: []const u8) !void {
    const parts = try parseS3ListPath(path);
    try std.testing.expectEqualStrings(expectedBucket, parts.bucket);
    try std.testing.expectEqualStrings(expectedKey, parts.key);
}

test "splits a bucket from its key" {
    try expectParts("my-bucket/some/dir", "my-bucket", "some/dir");
}

test "a trailing slash gives an empty key" {
    try expectParts("my-bucket/", "my-bucket", "");
}

test "a bucket alone with no slash gives an empty key" {
    try expectParts("my-bucket", "my-bucket", "");
}

test "keeps a leading slash in the key for the caller to normalise" {
    try expectParts("my-bucket//leading", "my-bucket", "/leading");
}

test "rejects an empty bucket" {
    try std.testing.expectError(error.Thrown, parseS3ListPath("/some/dir"));
}

test "rejects an empty path" {
    try std.testing.expectError(error.Thrown, parseS3ListPath(""));
}
