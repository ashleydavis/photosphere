const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;

//
// The bucket and key that an S3 storage path resolves to.
//
pub const IS3PathParts = struct {
    //
    // The bucket name, always non-empty.
    //
    bucket: []const u8,

    //
    // The key within the bucket. Empty when the path names the top of the bucket.
    //
    key: []const u8,
};

//
// Splits an S3 listing path into its bucket and key.
//
// Unlike the path parsing used for naming a single file, an empty key is allowed here, because
// listing the top of a bucket is a legitimate request: it is what the S3 browser asks for the
// moment it is opened. Both `my-bucket` and `my-bucket/` name the top of `my-bucket`.
//
pub fn parseS3ListPath(path: []const u8) !IS3PathParts {
    const slashIndex = std.mem.indexOfScalar(u8, path, '/');
    const bucket = if (slashIndex == null) path else path[0..slashIndex.?];
    const key = if (slashIndex == null) "" else path[slashIndex.? + 1 ..];

    if (bucket.len == 0) {
        return errors.throwError("Invalid path: {s}. Expected <bucket-name> or <bucket-name>/<path>", .{path});
    }

    return .{
        .bucket = bucket,
        .key = key,
    };
}
