const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const storage_module = @import("storage.zig");
const s3_client = @import("s3-client.zig");
const s3_range_readable_stream = @import("s3-range-readable-stream.zig");
const s3_path = @import("s3-path.zig");

const errors = utils.errors;
const IFileInfo = storage_module.IFileInfo;
const IListResult = storage_module.IListResult;
const IStorage = storage_module.IStorage;
const IReadStream = storage_module.IReadStream;
const S3Client = s3_client.S3Client;
const Upload = s3_client.Upload;
const ListObjectsV2Output = s3_client.ListObjectsV2Output;
const S3RangeReadableStream = s3_range_readable_stream.S3RangeReadableStream;
const parseS3ListPath = s3_path.parseS3ListPath;
const IWriteLockInfo = storage_module.IWriteLockInfo;
const LockFileContent = storage_module.LockFileContent;
const parseLockContent = storage_module.parseLockContent;
const log = &utils.log.log;
const Date = utils.timestamp_provider.Date;

// Write lock timeout in milliseconds (10 seconds)
const WRITE_LOCK_TIMEOUT_MS = 10000;

//
// How much of an upload goes in one part.
//
// The uploader holds a whole part in memory before it sends any of it, so the part size is how much
// memory an upload costs and how long it is silent before bytes start moving. At 100MB, which this
// was, a 100MB video on a Pixel 6 sat at full CPU for twenty minutes with nothing reaching the
// server while the engine assembled the part.
//
// Five megabytes, which is the smallest S3 allows: anything under it is refused outright with
// "EntityTooSmall: Your proposed upload part size is smaller than the minimum allowed size". It
// still allows a 2GB file, which is 400 parts against the 10,000 S3 permits.
//
// The smallest is what is wanted here, because a part is held in memory before it is sent and is one
// request against the server's own object lock. A phone pushes about seven megabytes a minute, so
// eight megabyte parts took over a minute each and MinIO refused the one after with "A timeout
// occurred while trying to lock a resource, please reduce your request rate", over and over on the
// same video.
//
const UPLOAD_PART_BYTES = 5 * 1024 * 1024;

// Not ported: SINGLE_PART_MAX_BYTES (only used by writeStreamHashed, which psi replicate and psi verify do not reach).

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

        return .{
            .location = location,
            .s3 = buildClient(io, endpoint, credentials),
        };
    }

    //
    // Builds the S3 client, and tells the signer not to hash request bodies.
    //
    // Signature version 4 normally covers the body: the signer reads the whole request payload and
    // puts its SHA-256 in x-amz-content-sha256. The SDK skips that of its own accord over HTTPS,
    // where it sends UNSIGNED-PAYLOAD instead, and does not over plain HTTP, which is what an S3
    // server on a local network is reached over.
    //
    // On a phone that hash is the single most expensive thing a sync does. It runs in the embedded
    // engine's pure JavaScript SHA-256 at well under a megabyte a second: measured on a Pixel 6, a
    // 100MB video held one upload for over twenty minutes at full CPU without a byte reaching the
    // server. Nothing is given up by not signing the body, because every file this writes carries a
    // SHA-256 the server checks it against (see writeStreamHashed), which the signature never did.
    //
    // (Zig: the S3 client (the binding to aws-c-s3 in s3-client.zig) is configured with `maxAttempts: 1` and
    // the connectionTimeout of the request handler; aws-c-s3 has no whole-request timeout, so requestTimeout is
    // not ported. The photosphereUnsignedPayload middleware is the client signing every request that has a body
    // with "UNSIGNED-PAYLOAD".)
    //
    fn buildClient(io: std.Io, endpoint: ?[]const u8, credentials: ?IS3Credentials) S3Client {
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

        return S3Client.init(io, config);
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
        const parsed = try parseS3ListPath(path);
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
        const parsed = try parseS3ListPath(path);
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

    // Not ported: readableLength, storedHash, writeStreamHashed (not reached by psi replicate or psi verify).

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
            .partSize = UPLOAD_PART_BYTES,
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
            .partSize = UPLOAD_PART_BYTES,
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

    //
    // Checks if a write lock is acquired for the specified file.
    // Returns the lock information if it exists, undefined otherwise.
    //
    pub fn checkWriteLock(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !?IWriteLockInfo {

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
            return errors.throwWrappedError("Failed to check write lock for {s}: {s}", .{ filePath, message });
        };
        // (Zig: the S3 client returns no Body for an empty object, which is the empty string of transformToString.)
        const lockContent = response.Body orelse "";
        if (lockContent.len > 0) {
            return parseLockContent(allocator, lockContent) catch |err| {
                const message = try causeMessage(allocator, err);
                return errors.throwWrappedError("Failed to check write lock for {s}: {s}", .{ filePath, message });
            };
        }
        return null;
    }

    //
    // Attempts to acquire a write lock for the specified file.
    // Returns true if the lock was acquired, false if it already exists.
    //
    pub fn acquireWriteLock(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8, owner: []const u8) !bool {

        const timestamp = std.Io.Clock.real.now(io).toMilliseconds();
        const processId = storage_module.processId();

        if (log.verboseEnabled()) {
            log.verbose(try std.fmt.allocPrint(allocator, "[LOCK] {d},ACQUIRE_ATTEMPT,{d},{s},{s}", .{ timestamp, processId, owner, filePath }));
        }

        const parsed = try self.parsePath(filePath);
        const bucket = parsed.bucket;
        var key = parsed.key;
        if (std.mem.startsWith(u8, key, "/")) {
            key = key[1..]; // Remove leading slash.
        }

        // Create lock information with owner and timestamp
        const lockInfo: LockFileContent = .{
            .owner = owner,
            .acquiredAt = try (Date{ .epochMilliseconds = std.Io.Clock.real.now(io).toMilliseconds() }).toISOString(allocator),
            .timestamp = timestamp,
        };
        const lockContent = try std.json.Stringify.valueAlloc(allocator, lockInfo, .{});
        const lockBody = lockContent;

        // Use conditional write to ensure atomic "create if not exists"
        self.s3.putObject(allocator, io, bucket, key, lockBody, "application/json", "*") catch |putErr| {
            // If the condition failed (object already exists), check if it's timed out
            if (putErr == error.Thrown and (s3_client.lastHttpStatusCode() == 412 or std.mem.eql(u8, errors.lastErrorName(), "PreconditionFailed") or std.mem.eql(u8, errors.lastErrorName(), "ConditionalRequestConflict"))) {
                // Check if existing lock has timed out (10 seconds = 10000ms)
                const existingLock = try self.checkWriteLock(allocator, io, filePath);
                if (existingLock) |lock| {
                    const lockAge = timestamp - lock.timestamp;
                    if (lockAge > WRITE_LOCK_TIMEOUT_MS) {
                        // Lock has timed out, delete it and try to acquire new lock
                        if (log.verboseEnabled()) {
                            log.verbose(try std.fmt.allocPrint(allocator, "[LOCK] {d},ACQUIRE_TIMEOUT_BREAK,{d},{s},{s},age:{d}ms,oldOwner:{s}", .{ timestamp, processId, owner, filePath, lockAge, lock.owner }));
                        }

                        retryAfterTimeout: {
                            // Delete the expired lock
                            self.s3.deleteObject(allocator, io, bucket, key) catch {
                                break :retryAfterTimeout;
                            };

                            // Try to acquire the lock again (without conditional header this time)
                            self.s3.putObject(allocator, io, bucket, key, lockBody, "application/json", null) catch {
                                break :retryAfterTimeout;
                            };

                            if (log.verboseEnabled()) {
                                log.verbose(try std.fmt.allocPrint(allocator, "[LOCK] {d},ACQUIRE_SUCCESS_AFTER_TIMEOUT,{d},{s},{s}", .{ timestamp, processId, owner, filePath }));
                            }
                            return true;
                        }

                        // Another process might have acquired the lock in the meantime
                        if (log.verboseEnabled()) {
                            log.verbose(try std.fmt.allocPrint(allocator, "[LOCK] {d},ACQUIRE_FAILED_RETRY,{d},{s},{s}", .{ timestamp, processId, owner, filePath }));
                        }
                        return false;
                    }
                    else {
                        // Lock is still valid
                        if (log.verboseEnabled()) {
                            log.verbose(try std.fmt.allocPrint(allocator, "[LOCK] {d},ACQUIRE_FAILED_EXISTS,{d},{s},{s},age:{d}ms,owner:{s}", .{ timestamp, processId, owner, filePath, lockAge, lock.owner }));
                        }
                        return false;
                    }
                }
                else {
                    // The write above was refused because the lock is there, but reading it back
                    // returned nothing. This used to assume the lock was corrupt, delete it and take
                    // it. It is not corrupt: the read simply raced its owner, who is still in the
                    // critical section. Deleting it here let three processes write one database at
                    // once and one of them lost its records (S3-LOCK-BROKEN-WHILE-HELD in
                    // Refuse instead and let the caller retry.
                    if (log.verboseEnabled()) {
                        log.verbose(try std.fmt.allocPrint(allocator, "[LOCK] {d},ACQUIRE_FAILED_UNREADABLE,{d},{s},{s}", .{ timestamp, processId, owner, filePath }));
                    }
                    return false;
                }
            }

            const message = try causeMessage(allocator, putErr);
            if (log.verboseEnabled()) {
                log.verbose(try std.fmt.allocPrint(allocator, "[LOCK] {d},ACQUIRE_FAILED_ERROR,{d},{s},{s},error:{s}", .{ timestamp, processId, owner, filePath, message }));
            }

            return errors.throwWrappedError("Failed to acquire write lock for {s}: {s}", .{ filePath, message });
        };

        if (log.verboseEnabled()) {
            log.verbose(try std.fmt.allocPrint(allocator, "[LOCK] {d},ACQUIRE_SUCCESS,{d},{s},{s}", .{ timestamp, processId, owner, filePath }));
        }
        return true;
    }

    //
    // Releases a write lock for the specified file.
    //
    pub fn releaseWriteLock(self: *CloudStorage, allocator: std.mem.Allocator, io: std.Io, filePath: []const u8) !void {

        const parsed = try self.parsePath(filePath);
        var key = parsed.key;
        if (std.mem.startsWith(u8, key, "/")) {
            key = key[1..]; // Remove leading slash.
        }

        self.s3.deleteObject(allocator, io, parsed.bucket, key) catch |err| {
            // Ignore errors if the lock file doesn't exist
            if (log.verboseEnabled()) {
                log.verbose(try std.fmt.allocPrint(allocator, "[LOCK] {d},RELEASE_FAILED,{d},unknown,{s},error:{s}", .{ std.Io.Clock.real.now(io).toMilliseconds(), storage_module.processId(), filePath, errors.errorMessage(err) }));
            }
            return;
        };
        if (log.verboseEnabled()) {
            log.verbose(try std.fmt.allocPrint(allocator, "[LOCK] {d},RELEASE_SUCCESS,{d},unknown,{s}", .{ std.Io.Clock.real.now(io).toMilliseconds(), storage_module.processId(), filePath }));
        }
    }

    // Not ported: refreshWriteLock (not reached by psi replicate or psi verify).
};
