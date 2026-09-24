const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_module = @import("storage.zig");
const s3_client = @import("s3-client.zig");
const s3_range_readable_stream = @import("s3-range-readable-stream.zig");

const errors = utils.errors;
const IFileInfo = storage_module.IFileInfo;
const IListResult = storage_module.IListResult;
const IStorage = storage_module.IStorage;
const IReadStream = storage_module.IReadStream;
const S3Client = s3_client.S3Client;
const Upload = s3_client.Upload;
const ListObjectsV2Output = s3_client.ListObjectsV2Output;
const S3RangeReadableStream = s3_range_readable_stream.S3RangeReadableStream;

// Not ported: WRITE_LOCK_TIMEOUT_MS (write locks are not used by psi replicate or psi verify).

//
// S3 credentials.
//
pub const IS3Credentials = struct {
    // The access key id.
    accessKeyId: []const u8,

    // The secret access key.
    secretAccessKey: []const u8,

    // The region (optional).
    region: ?[]const u8,

    // A custom endpoint such as "https://nyc3.digitaloceanspaces.com" (optional).
    endpoint: ?[]const u8,
};

//
// A path split into the bucket and the key.
//
pub const IParsedPath = struct {
    // The bucket.
    bucket: []const u8,

    // The key.
    key: []const u8,
};

//
// The part size of uploads.
// NOTE: These values have been tuned to allow uploading of 2GB+ files.
//
const UPLOAD_PART_SIZE = 100 * 1024 * 1024; // 100 MB

//
// Records a runtime (non-thrown) Zig error as the most recent error so that it can be the cause of a WrappedError,
// then returns its message (TypeScript: `err.message`), copied so it can be formatted into the new message.
//
fn causeMessage(allocator: std.mem.Allocator, err: anyerror) ![]const u8 {
    if (err != error.Thrown and err != error.FatalError) {
        errors.recordError(@errorName(err), "{s}", .{@errorName(err)});
    }
    return allocator.dupe(u8, errors.errorMessage(err));
}

//
// Returns true when the most recent error is S3's "not found" (TypeScript:
// `err.name === "NotFound" || err.$metadata?.httpStatusCode === 404`).
//
fn isNotFound(err: anyerror) bool {
    if (err != error.Thrown) {
        return false;
    }
    return std.mem.eql(u8, errors.lastErrorName(), "NotFound") or s3_client.lastHttpStatusCode() == 404;
}

//
// Returns true when the most recent error is S3's "NoSuchKey" (TypeScript: `err.name === "NoSuchKey"`).
//
fn isNoSuchKey(err: anyerror) bool {
    return err == error.Thrown and std.mem.eql(u8, errors.lastErrorName(), "NoSuchKey");
}

//
// Gets the last part of a "/" separated name.
//
fn lastPathPart(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, '/')) |slashIndex| {
        return name[slashIndex + 1 ..];
    }
    return name;
}

//
// AWS S3:
// - https://docs.aws.amazon.com/sdkref/latest/guide/environment-variables.html
// - https://docs.aws.amazon.com/AWSJavaScriptSDK/v3/latest/clients/client-s3/index.html
//
// Digital Ocean Spaces:
// - https://docs.digitalocean.com/reference/api/spaces-api/
// - https://docs.digitalocean.com/products/spaces/reference/s3-sdk-examples/
//
pub const CloudStorage = struct {
    //
    // Gets the location of the storage.
    //
    location: []const u8,

    //
    // AWS S3 client.
    // (Zig: held by value, so a CloudStorage must not be moved once it has been used.)
    //
    s3: S3Client,

    //
    // Creates cloud storage (TypeScript: `new CloudStorage(location, credentials)`).
    // (Zig: the request timeouts of the TypeScript request handler are not ported.)
    //
    pub fn init(io: std.Io, location: []const u8, credentials: ?IS3Credentials) CloudStorage {
        var endpoint: ?[]const u8 = null;
        if (credentials) |credentialsValue| {
            if (credentialsValue.endpoint) |credentialsEndpoint| {
                if (credentialsEndpoint.len > 0) {
                    endpoint = credentialsEndpoint;
                }
            }
        }
        if (endpoint == null) {
            if (node_utils.process_env.getEnv("AWS_ENDPOINT")) |environmentEndpoint| {
                if (environmentEndpoint.len > 0) {
                    endpoint = environmentEndpoint;
                }
            }
        }

        var config: s3_client.IS3ClientConfig = .{
            .endpoint = endpoint,
            .region = null,
            .credentials = null,
        };
        if (credentials) |credentialsValue| {
            config.credentials = .{
                .accessKeyId = credentialsValue.accessKeyId,
                .secretAccessKey = credentialsValue.secretAccessKey,
                .sessionToken = null,
            };
            config.region = credentialsValue.region;
        }

        return .{
            .location = location,
            .s3 = S3Client.init(io, config),
        };
    }

    //
    // Gets the IStorage interface of this storage (TypeScript: the class implements IStorage).
    //
    pub fn storage(self: *CloudStorage) IStorage {
        return .{ .ptr = self, .vtable = storage_module.implement(CloudStorage), .location = self.location };
    }

    //
    // Parse the path and extract the bucket and key.
    //
    pub fn parsePath(self: *CloudStorage, path: []const u8) !IParsedPath {
        _ = self;
        const slashIndex = std.mem.indexOfScalar(u8, path, '/') orelse {
            return errors.throwError("Invalid path: {s}. Expected <bucket-name>/<path>", .{path});
        };

        const bucket = path[0..slashIndex];
        const key = path[slashIndex + 1 ..];
        if (bucket.len == 0 or key.len == 0) {
            return errors.throwError("Invalid path: {s}. Expected <bucket-name>/<path>", .{path});
        }

        return .{
            .bucket = bucket,
            .key = key,
        };
    }

    //
    // Returns true if the specified directory is empty.
    //
    pub fn isEmpty(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
        const files = try self.listFiles(allocator, io, path, 1, null);
        if (files.names.len > 0) {
            return false;
        }

        const dirs = try self.listDirs(allocator, io, path, 1, null);
        if (dirs.names.len > 0) {
            return false;
        }

        return true;
    }

    //
    // List files in storage.
    //
    pub fn listFiles(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        const parsed = try self.parsePath(path);
        const bucket = parsed.bucket;
        var key = parsed.key;

        if (key.len == 0) {
            // Empty path is ok.
        }
        else if (std.mem.eql(u8, key, "/")) {
            key = ""; // The root directory is empty.
        }
        else {
            if (std.mem.startsWith(u8, key, "/")) {
                key = key[1..]; // Remove leading slash.
            }

            if (!std.mem.endsWith(u8, key, "/")) {
                key = try std.fmt.allocPrint(allocator, "{s}/", .{key}); // Ensure the path ends with a slash.
            }
        }

        const response = self.s3.listObjectsV2(allocator, io, .{
            .Bucket = bucket,
            .Prefix = key,
            .Delimiter = "/",
            .MaxKeys = max,
            .ContinuationToken = next,
        }) catch |err| {
            const message = try causeMessage(allocator, err);
            return errors.throwWrappedError("Failed to list files in {s}: {s}", .{ path, message });
        };

        var names: std.ArrayList([]const u8) = .empty;
        if (response.Contents) |contents| {
            for (contents) |item| {
                const name = lastPathPart(item.Key); // The last part is the file name or asset ID.
                if (name.len > 0) {
                    try names.append(allocator, name); // Remove empty names.
                }
            }
        }

        return .{
            .names = try names.toOwnedSlice(allocator),
            .next = response.NextContinuationToken,
        };
    }

    //
    // List directories in storage.
    //
    pub fn listDirs(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, path: []const u8, max: u32, next: ?[]const u8) !IListResult {
        const parsed = try self.parsePath(path);
        const bucket = parsed.bucket;
        var key = parsed.key;

        if (key.len == 0) {
            // Empty path is ok.
        }
        else if (std.mem.eql(u8, key, "/")) {
            key = ""; // The root directory is empty.
        }
        else {
            if (!std.mem.endsWith(u8, key, "/")) {
                key = try std.fmt.allocPrint(allocator, "{s}/", .{key}); // Ensure the path ends with a slash.
            }

            if (std.mem.startsWith(u8, key, "/")) {
                key = key[1..]; // Remove leading slash.
            }
        }

        const response = self.s3.listObjectsV2(allocator, io, .{
            .Bucket = bucket,
            .Prefix = key,
            .Delimiter = "/",
            .MaxKeys = max,
            .ContinuationToken = next,
        }) catch |err| {
            const message = try causeMessage(allocator, err);
            return errors.throwWrappedError("Failed to list directories in {s}: {s}", .{ path, message });
        };

        var names: std.ArrayList([]const u8) = .empty;
        if (response.CommonPrefixes) |commonPrefixes| {
            for (commonPrefixes) |item| {
                var prefix = item.Prefix;
                if (prefix.len > 0) {
                    prefix = prefix[0 .. prefix.len - 1]; // Trims trailing slash.
                }
                const name = lastPathPart(prefix); // The last part is the file name or asset ID.
                if (name.len > 0) {
                    try names.append(allocator, name); // Remove empty names.
                }
            }
        }

        return .{
            .names = try names.toOwnedSlice(allocator),
            .next = response.NextContinuationToken,
        };
    }

    //
    // Returns true if the specified file exists.
    //
    pub fn fileExists(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !bool {
        const parsed = try self.parsePath(filePath);
        var key = parsed.key;
        if (std.mem.startsWith(u8, key, "/")) {
            key = key[1..]; // Remove leading slash.
        }

        _ = self.s3.headObject(allocator, io, parsed.bucket, key) catch |err| {
            if (isNotFound(err)) {
                return false;
            }
            const message = try causeMessage(allocator, err);
            return errors.throwWrappedError("Failed to check if file exists: {s}", .{message});
        };
        return true;
    }

    //
    // Returns true if the specified directory exists (has at least one object with the prefix).
    //
    pub fn dirExists(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !bool {
        const parsed = try self.parsePath(dirPath);
        var key = parsed.key;

        if (key.len == 0) {
            // Empty path is ok, bucket always exists if we've gotten this far
            return true;
        }
        else if (std.mem.eql(u8, key, "/")) {
            key = ""; // The root directory is empty.
        }
        else {
            if (std.mem.startsWith(u8, key, "/")) {
                key = key[1..]; // Remove leading slash.
            }

            if (!std.mem.endsWith(u8, key, "/")) {
                key = try std.fmt.allocPrint(allocator, "{s}/", .{key}); // Ensure the path ends with a slash for directory check
            }
        }

        const response = self.s3.listObjectsV2(allocator, io, .{
            .Bucket = parsed.bucket,
            .Prefix = key,
            .Delimiter = null,
            .MaxKeys = 1, // We only need to find one object to confirm directory exists
            .ContinuationToken = null,
        }) catch |err| {
            const message = try causeMessage(allocator, err);
            return errors.throwWrappedError("Failed to check if directory exists: {s}", .{message});
        };
        return response.Contents != null and response.Contents.?.len > 0;
    }

    //
    // Gets info about an asset.
    //
    pub fn info(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IFileInfo {
        const parsed = try self.parsePath(filePath);
        var key = parsed.key;
        if (std.mem.startsWith(u8, key, "/")) {
            key = key[1..]; // Remove leading slash.
        }

        const headResult = self.s3.headObject(allocator, io, parsed.bucket, key) catch |err| {
            if (isNotFound(err)) {
                return null;
            }
            const message = try causeMessage(allocator, err);
            return errors.throwWrappedError("Failed to get info for {s}: {s}", .{ filePath, message });
        };
        const lastModified = headResult.LastModified orelse {
            errors.recordError("Error", "LastModified is undefined for {s}", .{filePath});
            const message = try causeMessage(allocator, error.Thrown);
            return errors.throwWrappedError("Failed to get info for {s}: {s}", .{ filePath, message });
        };
        return .{
            .contentType = headResult.ContentType,
            .length = headResult.ContentLength,
            .lastModified = lastModified,
        };
    }

    //
    // Reads a file from storage.
    // Returns undefined if the file doesn't exist.
    //
    pub fn read(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?[]u8 {
        const parsed = try self.parsePath(filePath);
        var key = parsed.key;
        if (std.mem.startsWith(u8, key, "/")) {
            key = key[1..]; // Remove leading slash.
        }

        const response = self.s3.getObject(allocator, io, parsed.bucket, key, null) catch |err| {
            if (isNoSuchKey(err)) {
                return null;
            }
            const message = try causeMessage(allocator, err);
            return errors.throwWrappedError("Failed to read {s}: {s}", .{ filePath, message });
        };
        // (Zig: the S3 client returns no Body for an empty object, where the SDK's Body gives an empty buffer.)
        return response.Body orelse try allocator.alloc(u8, 0);
    }

    //
    // Writes a file to storage.
    //
    pub fn write(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, data: []const u8) !void {
        const parsed = try self.parsePath(filePath);
        var key = parsed.key;
        if (std.mem.startsWith(u8, key, "/")) {
            key = key[1..]; // Remove leading slash.
        }

        //
        // NOTE: These values have been tuned to allow uploading of 2GB+ files.
        //
        var upload = Upload.init(.{
            .client = &self.s3,
            .params = .{
                .Bucket = parsed.bucket,
                .Key = key,
                .Body = .{ .buffer = data },
                .ContentType = contentType,
                .ContentLength = data.len,
            },
            .partSize = UPLOAD_PART_SIZE,
            .queueSize = 1,
        });
        upload.done(allocator, io) catch |err| {
            const message = try causeMessage(allocator, err);
            return errors.throwWrappedError("Failed to write to {s}: {s}", .{ filePath, message });
        };
    }

    //
    // Streams a file from storage.
    //
    pub fn readStream(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !IReadStream {
        const parsed = try self.parsePath(filePath);
        var key = parsed.key;
        if (std.mem.startsWith(u8, key, "/")) {
            key = key[1..]; // Remove leading slash.
        }

        const stream = try S3RangeReadableStream.init(allocator, io, &self.s3, parsed.bucket, key);
        return stream.readStream();
    }

    //
    // Writes an input stream to storage.
    //
    pub fn writeStream(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, contentType: ?[]const u8, inputStream: *std.Io.Reader, contentLength: ?u64) !void {
        const parsed = try self.parsePath(filePath);
        var key = parsed.key;
        if (std.mem.startsWith(u8, key, "/")) {
            key = key[1..]; // Remove leading slash.
        }

        //
        // NOTE: These values have been tuned to allow uploading of 2GB+ files.
        //
        var upload = Upload.init(.{
            .client = &self.s3,
            .params = .{
                .Bucket = parsed.bucket,
                .Key = key,
                .Body = .{ .stream = inputStream },
                .ContentType = contentType,
                .ContentLength = contentLength,
            },
            .partSize = UPLOAD_PART_SIZE,
            .queueSize = 1,
        });
        upload.done(allocator, io) catch |err| {
            const message = try causeMessage(allocator, err);
            return errors.throwWrappedError("Failed to write stream to {s}: {s}", .{ filePath, message });
        };
    }

    //
    // Deletes a file from storage.
    //
    pub fn deleteFile(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {
        const parsed = try self.parsePath(filePath);
        var key = parsed.key;
        if (std.mem.startsWith(u8, key, "/")) {
            key = key[1..]; // Remove leading slash.
        }

        self.s3.deleteObject(allocator, io, parsed.bucket, key) catch {
            // Ignore errors if the file doesn't exist
        };
    }

    //
    // Deletes a directory and all its contents from storage.
    //
    pub fn deleteDir(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, dirPath: []const u8) !void {
        const parsed = try self.parsePath(dirPath);
        var key = parsed.key;
        if (std.mem.startsWith(u8, key, "/")) {
            key = key[1..]; // Remove leading slash.
        }

        // Make sure the key ends with a slash to indicate a directory
        if (!std.mem.endsWith(u8, key, "/")) {
            key = try std.fmt.allocPrint(allocator, "{s}/", .{key});
        }

        // (Zig: every failure inside the TypeScript try block returns, like the empty catch block.)
        var isTruncated = true;
        var continuationToken: ?[]const u8 = null;

        while (isTruncated) {
            const listResult: ListObjectsV2Output = self.s3.listObjectsV2(allocator, io, .{
                .Bucket = parsed.bucket,
                .Prefix = key,
                .Delimiter = null,
                .MaxKeys = null,
                .ContinuationToken = continuationToken,
            }) catch {
                // Ignore errors if the directory doesn't exist
                return;
            };

            if (listResult.Contents) |contents| {
                if (contents.len > 0) {
                    // Batch delete objects (up to 1000 at a time)
                    const keys = try allocator.alloc([]const u8, contents.len);
                    for (contents, 0..) |object, index| {
                        keys[index] = object.Key;
                    }
                    self.s3.deleteObjects(allocator, io, parsed.bucket, keys) catch {
                        // Ignore errors if the directory doesn't exist
                        return;
                    };
                }
            }

            isTruncated = listResult.IsTruncated;
            continuationToken = listResult.NextContinuationToken;
        }
    }

    //
    // Copies a file from one location to another.
    // srcPath can include the src bucket name.
    //
    pub fn copyTo(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, srcPath: []const u8, destPath: []const u8) !void {
        const source = try self.parsePath(srcPath);
        var srcKey = source.key;
        if (std.mem.startsWith(u8, srcKey, "/")) {
            srcKey = srcKey[1..]; // Remove leading slash.
        }

        const destination = try self.parsePath(destPath);
        var destKey = destination.key;
        if (std.mem.startsWith(u8, destKey, "/")) {
            destKey = destKey[1..]; // Remove leading slash.
        }

        const copySource = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ source.bucket, srcKey });
        self.s3.copyObject(allocator, io, destination.bucket, copySource, destKey) catch |err| {
            const message = try causeMessage(allocator, err);
            return errors.throwWrappedError("Failed to copy from {s} to {s}: {s}", .{ srcPath, destPath, message });
        };
    }

    // Not ported: checkWriteLock, acquireWriteLock, releaseWriteLock, refreshWriteLock
    // (write locks are not used by psi replicate or psi verify).
};
