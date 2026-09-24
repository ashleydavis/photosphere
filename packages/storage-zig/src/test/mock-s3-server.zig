const std = @import("std");
const storage_zig = @import("storage-zig");

const sigv4 = storage_zig.sigv4;
const s3_client = storage_zig.s3_client;

//
// A local S3-compatible HTTP server for the tests (path-style requests on 127.0.0.1).
// It implements the requests CloudStorage sends: ListObjectsV2, HeadObject, GetObject (with ranges), PutObject,
// CopyObject, DeleteObject, DeleteObjects and the multipart upload requests. It checks the SigV4 signature of every
// request against the test credentials and can inject failures. Connections are closed after each response, so
// stopping the server never waits on an idle keep-alive connection.
//

//
// The access key id the server accepts.
//
pub const ACCESS_KEY_ID = "AKIAMOCKEXAMPLE";

//
// The secret access key the server accepts.
//
pub const SECRET_ACCESS_KEY = "mock/secret/key";

//
// The region the tests use.
//
pub const REGION = "us-east-1";

//
// The time every object reports as last modified ("Wed, 12 Oct 2009 17:50:00 GMT").
//
pub const LAST_MODIFIED_TEXT = "Wed, 12 Oct 2009 17:50:00 GMT";

//
// LAST_MODIFIED_TEXT in milliseconds since the Unix epoch.
//
pub const LAST_MODIFIED_MS: i64 = 1255369800000;

//
// A stored object.
//
const StoredObject = struct {
    // The contents (empty for a synthetic object).
    data: []const u8,

    // The size of a synthetic object whose bytes are all `fill` (null for a normal object).
    syntheticSize: ?u64,

    // The byte of a synthetic object.
    fill: u8,

    // The content type.
    contentType: ?[]const u8,

    //
    // Gets the size of the object.
    //
    fn size(self: StoredObject) u64 {
        return self.syntheticSize orelse self.data.len;
    }
};

//
// An in-progress multipart upload.
//
const MultipartUpload = struct {
    // "<bucket>/<key>".
    objectPath: []const u8,

    // The content type given when the upload was created.
    contentType: ?[]const u8,

    // The uploaded parts by part number.
    parts: std.AutoArrayHashMapUnmanaged(u32, []const u8),
};

//
// A parsed request.
//
const ParsedRequest = struct {
    // The method.
    method: std.http.Method,

    // The raw (encoded) path.
    rawPath: []const u8,

    // The decoded bucket.
    bucket: []const u8,

    // The decoded key (empty for bucket requests).
    key: []const u8,

    // The decoded query parameters.
    query: []const sigv4.IQueryParameter,

    // The request headers.
    headers: []const sigv4.IHeader,

    // The request body.
    body: []const u8,

    //
    // Gets a query parameter.
    //
    fn queryValue(self: ParsedRequest, name: []const u8) ?[]const u8 {
        for (self.query) |parameter| {
            if (std.mem.eql(u8, parameter.name, name)) {
                return parameter.value;
            }
        }
        return null;
    }

    //
    // Gets a header (case-insensitive).
    //
    fn header(self: ParsedRequest, name: []const u8) ?[]const u8 {
        for (self.headers) |requestHeader| {
            if (std.ascii.eqlIgnoreCase(requestHeader.name, name)) {
                return requestHeader.value;
            }
        }
        return null;
    }
};

//
// A response to send.
//
const MockResponse = struct {
    // The status code.
    status: u16,

    // The body.
    body: []const u8,

    // Extra headers.
    headers: []const std.http.Header,

    // For a synthetic object: stream this many bytes of `fill` instead of `body`.
    syntheticLength: ?u64,

    // The byte of a synthetic body.
    fill: u8,
};

//
// The mock server.
//
pub const MockS3Server = struct {
    // Allocates the stored objects (thread-safe).
    allocator: std.mem.Allocator,

    // The io the server runs on.
    io: std.Io,

    // The listening socket.
    server: std.Io.net.Server,

    // The port the server listens on.
    port: u16,

    // Runs the accept loop and the connections.
    group: std.Io.Group,

    // Protects the fields below.
    mutex: std.Io.Mutex,

    // The objects by "<bucket>/<key>".
    objects: std.StringArrayHashMapUnmanaged(StoredObject),

    // The multipart uploads by upload id.
    uploads: std.StringArrayHashMapUnmanaged(MultipartUpload),

    // The number of uploads created (used for upload ids).
    uploadCount: u32,

    // Every request, "METHOD /path?query".
    requests: std.ArrayList([]const u8),

    // The Range header of every GetObject request.
    ranges: std.ArrayList([]const u8),

    // GetObject requests whose range covers at least this many bytes fail with 500 (null for never).
    failRangesOfAtLeast: ?u64,

    // The number of GetObject requests that still fail with 500 before requests succeed.
    failGetObjectCount: u32,

    // Every GetObject request fails with this 503 message (null for never).
    getObjectUnavailableMessage: ?[]const u8,

    // The number of signature failures seen.
    signatureFailures: u32,

    //
    // Starts a server on an ephemeral port of 127.0.0.1.
    //
    pub fn start(io: std.Io) !*MockS3Server {
        const allocator = std.heap.smp_allocator;
        const self = try allocator.create(MockS3Server);
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .server = try address.listen(io, .{ .reuse_address = true }),
            .port = 0,
            .group = .init,
            .mutex = .init,
            .objects = .empty,
            .uploads = .empty,
            .uploadCount = 0,
            .requests = .empty,
            .ranges = .empty,
            .failRangesOfAtLeast = null,
            .failGetObjectCount = 0,
            .getObjectUnavailableMessage = null,
            .signatureFailures = 0,
        };
        self.port = self.server.socket.address.getPort();
        // The accept loop must not run inline on the caller (which `async` may do), so it needs real concurrency.
        try self.group.concurrent(io, acceptLoop, .{self});
        return self;
    }

    //
    // Stops the server and frees everything.
    //
    pub fn stop(self: *MockS3Server) void {
        self.group.cancel(self.io);
        self.server.deinit(self.io);
        self.allocator.destroy(self);
    }

    //
    // Gets the endpoint URL of the server.
    //
    pub fn endpoint(self: *MockS3Server, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.port});
    }

    //
    // Stores an object.
    //
    pub fn putObject(self: *MockS3Server, objectPath: []const u8, data: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.objects.put(self.allocator, try self.allocator.dupe(u8, objectPath), .{
            .data = try self.allocator.dupe(u8, data),
            .syntheticSize = null,
            .fill = 0,
            .contentType = null,
        });
    }

    //
    // Stores a large object whose bytes are all `fill` without holding it in memory.
    //
    pub fn putSyntheticObject(self: *MockS3Server, objectPath: []const u8, size: u64, fill: u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.objects.put(self.allocator, try self.allocator.dupe(u8, objectPath), .{
            .data = "",
            .syntheticSize = size,
            .fill = fill,
            .contentType = null,
        });
    }

    //
    // Gets a copy of an object's data (null when missing).
    //
    pub fn getObject(self: *MockS3Server, allocator: std.mem.Allocator, objectPath: []const u8) !?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const object = self.objects.get(objectPath) orelse {
            return null;
        };
        return try allocator.dupe(u8, object.data);
    }

    //
    // Gets the content type of an object.
    //
    pub fn getContentType(self: *MockS3Server, objectPath: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const object = self.objects.get(objectPath) orelse {
            return null;
        };
        return object.contentType;
    }

    //
    // Returns the number of requests whose description starts with the prefix.
    //
    pub fn countRequests(self: *MockS3Server, prefix: []const u8) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var count: usize = 0;
        for (self.requests.items) |request| {
            if (std.mem.startsWith(u8, request, prefix)) {
                count += 1;
            }
        }
        return count;
    }

    //
    // Returns a copy of the recorded ranges.
    //
    pub fn recordedRanges(self: *MockS3Server, allocator: std.mem.Allocator) ![]const []const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return allocator.dupe([]const u8, self.ranges.items);
    }

    //
    // Accepts connections until canceled.
    //
    fn acceptLoop(self: *MockS3Server) void {
        while (true) {
            const stream = self.server.accept(self.io) catch {
                return;
            };
            self.group.concurrent(self.io, serveConnection, .{ self, stream }) catch {
                // No thread is free: serve the connection on the accept loop's thread.
                self.serveConnection(stream);
            };
        }
    }

    //
    // Serves the requests of one connection.
    //
    fn serveConnection(self: *MockS3Server, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);
        var receiveBuffer: [16 * 1024]u8 = undefined;
        var sendBuffer: [16 * 1024]u8 = undefined;
        var connectionReader = stream.reader(self.io, &receiveBuffer);
        var connectionWriter = stream.writer(self.io, &sendBuffer);
        var httpServer = std.http.Server.init(&connectionReader.interface, &connectionWriter.interface);
        while (httpServer.reader.state == .ready) {
            var request = httpServer.receiveHead() catch {
                return;
            };
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            self.serveRequest(arena.allocator(), &request) catch {
                return;
            };
        }
    }

    //
    // Reads, checks and answers one request.
    //
    fn serveRequest(self: *MockS3Server, allocator: std.mem.Allocator, request: *std.http.Server.Request) !void {
        const parsed = try parseRequest(allocator, request);
        const response = self.handle(allocator, parsed) catch |err| blk: {
            break :blk try errorResponse(allocator, 500, "InternalError", @errorName(err));
        };
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.appendSlice(allocator, response.headers);
        if (response.syntheticLength) |length| {
            var buffer: [64 * 1024]u8 = undefined;
            var bodyWriter = try request.respondStreaming(&buffer, .{
                .content_length = length,
                .respond_options = .{ .status = @enumFromInt(response.status), .extra_headers = headers.items, .keep_alive = false },
            });
            var fillBlock: [64 * 1024]u8 = undefined;
            @memset(&fillBlock, response.fill);
            var remaining = length;
            while (remaining > 0) {
                const count: usize = @intCast(@min(remaining, fillBlock.len));
                try bodyWriter.writer.writeAll(fillBlock[0..count]);
                remaining -= count;
            }
            try bodyWriter.end();
            return;
        }
        try request.respond(response.body, .{ .status = @enumFromInt(response.status), .extra_headers = headers.items, .keep_alive = false });
    }

    //
    // Records a request.
    //
    fn recordRequest(self: *MockS3Server, parsed: ParsedRequest) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        var description: std.ArrayList(u8) = .empty;
        try description.print(self.allocator, "{s} /{s}/{s}", .{ @tagName(parsed.method), parsed.bucket, parsed.key });
        for (parsed.query, 0..) |parameter, index| {
            try description.append(self.allocator, if (index == 0) '?' else '&');
            try description.print(self.allocator, "{s}={s}", .{ parameter.name, parameter.value });
        }
        try self.requests.append(self.allocator, description.items);
    }

    //
    // Answers a parsed request.
    //
    fn handle(self: *MockS3Server, allocator: std.mem.Allocator, parsed: ParsedRequest) !MockResponse {
        try self.recordRequest(parsed);
        if (!try verifySignature(allocator, parsed)) {
            self.mutex.lockUncancelable(self.io);
            self.signatureFailures += 1;
            self.mutex.unlock(self.io);
            return errorResponse(allocator, 403, "SignatureDoesNotMatch", "The request signature we calculated does not match the signature you provided.");
        }

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (parsed.key.len == 0) {
            if (parsed.method == .GET and parsed.queryValue("list-type") != null) {
                return self.listObjects(allocator, parsed);
            }
            if (parsed.method == .POST and parsed.queryValue("delete") != null) {
                return self.deleteObjects(allocator, parsed);
            }
            return errorResponse(allocator, 400, "InvalidRequest", "Unsupported bucket request");
        }

        const objectPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parsed.bucket, parsed.key });
        switch (parsed.method) {
            .HEAD => {
                const object = self.objects.get(objectPath) orelse {
                    return .{ .status = 404, .body = "", .headers = &.{}, .syntheticLength = null, .fill = 0 };
                };
                return self.objectResponse(allocator, object, 200, 0, object.size(), null);
            },
            .GET => return self.getObjectResponse(allocator, parsed, objectPath),
            .PUT => {
                if (parsed.header("x-amz-copy-source")) |copySource| {
                    const sourcePath = try decodePercent(allocator, copySource);
                    const source = self.objects.get(sourcePath) orelse {
                        return errorResponse(allocator, 404, "NoSuchKey", "The specified key does not exist.");
                    };
                    try self.objects.put(self.allocator, try self.allocator.dupe(u8, objectPath), source);
                    return .{ .status = 200, .body = "<CopyObjectResult><ETag>\"copy\"</ETag></CopyObjectResult>", .headers = &.{}, .syntheticLength = null, .fill = 0 };
                }
                if (parsed.queryValue("uploadId")) |uploadId| {
                    const upload = self.uploads.getPtr(uploadId) orelse {
                        return errorResponse(allocator, 404, "NoSuchUpload", "The specified upload does not exist.");
                    };
                    const partNumber = try std.fmt.parseInt(u32, parsed.queryValue("partNumber") orelse "0", 10);
                    try upload.parts.put(self.allocator, partNumber, try self.allocator.dupe(u8, parsed.body));
                    const etag = try std.fmt.allocPrint(allocator, "\"etag-{d}\"", .{partNumber});
                    const headers = try allocator.alloc(std.http.Header, 1);
                    headers[0] = .{ .name = "ETag", .value = etag };
                    return .{ .status = 200, .body = "", .headers = headers, .syntheticLength = null, .fill = 0 };
                }
                try self.objects.put(self.allocator, try self.allocator.dupe(u8, objectPath), .{
                    .data = try self.allocator.dupe(u8, parsed.body),
                    .syntheticSize = null,
                    .fill = 0,
                    .contentType = if (parsed.header("content-type")) |contentType| try self.allocator.dupe(u8, contentType) else null,
                });
                return .{ .status = 200, .body = "", .headers = &.{}, .syntheticLength = null, .fill = 0 };
            },
            .POST => {
                if (parsed.queryValue("uploads") != null) {
                    self.uploadCount += 1;
                    const uploadId = try std.fmt.allocPrint(self.allocator, "upload-{d}", .{self.uploadCount});
                    try self.uploads.put(self.allocator, uploadId, .{
                        .objectPath = try self.allocator.dupe(u8, objectPath),
                        .contentType = if (parsed.header("content-type")) |contentType| try self.allocator.dupe(u8, contentType) else null,
                        .parts = .empty,
                    });
                    const body = try std.fmt.allocPrint(allocator, "<InitiateMultipartUploadResult><Bucket>{s}</Bucket><Key>{s}</Key><UploadId>{s}</UploadId></InitiateMultipartUploadResult>", .{ parsed.bucket, parsed.key, uploadId });
                    return .{ .status = 200, .body = body, .headers = &.{}, .syntheticLength = null, .fill = 0 };
                }
                if (parsed.queryValue("uploadId")) |uploadId| {
                    const upload = self.uploads.get(uploadId) orelse {
                        return errorResponse(allocator, 404, "NoSuchUpload", "The specified upload does not exist.");
                    };
                    var data: std.ArrayList(u8) = .empty;
                    const partNumbers = try s3_client.xmlElements(allocator, parsed.body, "PartNumber");
                    for (partNumbers) |partNumberText| {
                        const partNumber = try std.fmt.parseInt(u32, partNumberText, 10);
                        const part = upload.parts.get(partNumber) orelse {
                            return errorResponse(allocator, 400, "InvalidPart", "One or more of the specified parts could not be found.");
                        };
                        try data.appendSlice(self.allocator, part);
                    }
                    try self.objects.put(self.allocator, upload.objectPath, .{
                        .data = data.items,
                        .syntheticSize = null,
                        .fill = 0,
                        .contentType = upload.contentType,
                    });
                    _ = self.uploads.swapRemove(uploadId);
                    return .{ .status = 200, .body = "<CompleteMultipartUploadResult></CompleteMultipartUploadResult>", .headers = &.{}, .syntheticLength = null, .fill = 0 };
                }
                return errorResponse(allocator, 400, "InvalidRequest", "Unsupported POST");
            },
            .DELETE => {
                if (parsed.queryValue("uploadId")) |uploadId| {
                    _ = self.uploads.swapRemove(uploadId);
                    return .{ .status = 204, .body = "", .headers = &.{}, .syntheticLength = null, .fill = 0 };
                }
                _ = self.objects.swapRemove(objectPath);
                return .{ .status = 204, .body = "", .headers = &.{}, .syntheticLength = null, .fill = 0 };
            },
            else => return errorResponse(allocator, 405, "MethodNotAllowed", "Unsupported method"),
        }
    }

    //
    // Builds the response for an object (or a range of it).
    //
    fn objectResponse(self: *MockS3Server, allocator: std.mem.Allocator, object: StoredObject, status: u16, rangeStart: u64, length: u64, contentRange: ?[]const u8) !MockResponse {
        _ = self;
        var headers: std.ArrayList(std.http.Header) = .empty;
        try headers.append(allocator, .{ .name = "Last-Modified", .value = LAST_MODIFIED_TEXT });
        if (object.contentType) |contentType| {
            try headers.append(allocator, .{ .name = "Content-Type", .value = contentType });
        }
        if (contentRange) |contentRangeValue| {
            try headers.append(allocator, .{ .name = "Content-Range", .value = contentRangeValue });
        }
        if (object.syntheticSize != null) {
            return .{ .status = status, .body = "", .headers = headers.items, .syntheticLength = length, .fill = object.fill };
        }
        const startIndex: usize = @intCast(rangeStart);
        const endIndex: usize = @intCast(rangeStart + length);
        return .{ .status = status, .body = object.data[startIndex..endIndex], .headers = headers.items, .syntheticLength = null, .fill = 0 };
    }

    //
    // Answers GetObject, with failure injection.
    //
    fn getObjectResponse(self: *MockS3Server, allocator: std.mem.Allocator, parsed: ParsedRequest, objectPath: []const u8) !MockResponse {
        const range = parsed.header("range");
        if (range) |rangeValue| {
            try self.ranges.append(self.allocator, try self.allocator.dupe(u8, rangeValue));
        }
        if (self.getObjectUnavailableMessage) |message| {
            return errorResponse(allocator, 503, "ServiceUnavailable", message);
        }
        if (self.failGetObjectCount > 0) {
            self.failGetObjectCount -= 1;
            return errorResponse(allocator, 500, "InternalError", "first chunk failed");
        }

        if (std.mem.eql(u8, parsed.key, "no-body")) {
            const headers = try allocator.alloc(std.http.Header, 1);
            headers[0] = .{ .name = "Content-Range", .value = "bytes 0-9/10" };
            return .{ .status = 206, .body = "", .headers = headers, .syntheticLength = null, .fill = 0 };
        }

        const object = self.objects.get(objectPath) orelse {
            return errorResponse(allocator, 404, "NoSuchKey", "The specified key does not exist.");
        };
        const size = object.size();
        const rangeValue = range orelse {
            return self.objectResponse(allocator, object, 200, 0, size, null);
        };

        const dashIndex = std.mem.indexOfScalar(u8, rangeValue, '-') orelse {
            return errorResponse(allocator, 400, "InvalidArgument", "Invalid range");
        };
        const rangeStart = try std.fmt.parseInt(u64, rangeValue["bytes=".len..dashIndex], 10);
        const requestedEnd = try std.fmt.parseInt(u64, rangeValue[dashIndex + 1 ..], 10);
        if (self.failRangesOfAtLeast) |threshold| {
            if (requestedEnd - rangeStart + 1 >= threshold) {
                return errorResponse(allocator, 500, "InternalError", "chunk too large");
            }
        }
        if (size == 0) {
            // An empty object answers like the mocked response of the TypeScript test "reads an empty file".
            const headers = try allocator.alloc(std.http.Header, 1);
            headers[0] = .{ .name = "Content-Range", .value = "bytes 0-0/0" };
            return .{ .status = 206, .body = "", .headers = headers, .syntheticLength = null, .fill = 0 };
        }
        if (rangeStart >= size) {
            return errorResponse(allocator, 416, "InvalidRange", "The requested range is not satisfiable");
        }
        const end = @min(requestedEnd, size - 1);
        const contentRange = try std.fmt.allocPrint(allocator, "bytes {d}-{d}/{d}", .{ rangeStart, end, size });
        return self.objectResponse(allocator, object, 206, rangeStart, end - rangeStart + 1, contentRange);
    }

    //
    // An entry of a listing: an object key or a common prefix.
    //
    const ListEntry = struct {
        // The key or the prefix.
        name: []const u8,

        // True for a common prefix.
        isPrefix: bool,
    };

    //
    // Answers ListObjectsV2 (continuation tokens are the last name returned).
    //
    fn listObjects(self: *MockS3Server, allocator: std.mem.Allocator, parsed: ParsedRequest) !MockResponse {
        const prefix = parsed.queryValue("prefix") orelse "";
        const delimiter = parsed.queryValue("delimiter");
        const maxKeys = try std.fmt.parseInt(usize, parsed.queryValue("max-keys") orelse "1000", 10);
        const continuationToken = parsed.queryValue("continuation-token");
        const bucketPrefix = try std.fmt.allocPrint(allocator, "{s}/", .{parsed.bucket});

        var keys: std.ArrayList([]const u8) = .empty;
        for (self.objects.keys()) |objectPath| {
            if (!std.mem.startsWith(u8, objectPath, bucketPrefix)) {
                continue;
            }
            const key = objectPath[bucketPrefix.len..];
            if (std.mem.startsWith(u8, key, prefix)) {
                try keys.append(allocator, key);
            }
        }
        std.mem.sort([]const u8, keys.items, {}, stringLessThan);

        var entries: std.ArrayList(ListEntry) = .empty;
        for (keys.items) |key| {
            if (delimiter) |delimiterValue| {
                if (std.mem.indexOfPos(u8, key, prefix.len, delimiterValue)) |delimiterIndex| {
                    const commonPrefix = key[0 .. delimiterIndex + delimiterValue.len];
                    if (entries.items.len == 0 or !std.mem.eql(u8, entries.items[entries.items.len - 1].name, commonPrefix)) {
                        try entries.append(allocator, .{ .name = commonPrefix, .isPrefix = true });
                    }
                    continue;
                }
            }
            try entries.append(allocator, .{ .name = key, .isPrefix = false });
        }

        var startIndex: usize = 0;
        if (continuationToken) |token| {
            while (startIndex < entries.items.len and std.mem.order(u8, entries.items[startIndex].name, token) != .gt) {
                startIndex += 1;
            }
        }
        const endIndex = @min(entries.items.len, startIndex + maxKeys);
        const isTruncated = endIndex < entries.items.len;

        var body: std.ArrayList(u8) = .empty;
        try body.print(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListBucketResult><Name>{s}</Name><Prefix>{s}</Prefix><KeyCount>{d}</KeyCount><MaxKeys>{d}</MaxKeys><IsTruncated>{s}</IsTruncated>", .{
            parsed.bucket,
            try s3_client.xmlEncode(allocator, prefix),
            endIndex - startIndex,
            maxKeys,
            if (isTruncated) "true" else "false",
        });
        for (entries.items[startIndex..endIndex]) |entry| {
            const encodedName = try s3_client.xmlEncode(allocator, entry.name);
            if (entry.isPrefix) {
                try body.print(allocator, "<CommonPrefixes><Prefix>{s}</Prefix></CommonPrefixes>", .{encodedName});
            }
            else {
                try body.print(allocator, "<Contents><Key>{s}</Key><Size>0</Size></Contents>", .{encodedName});
            }
        }
        if (isTruncated) {
            try body.print(allocator, "<NextContinuationToken>{s}</NextContinuationToken>", .{try s3_client.xmlEncode(allocator, entries.items[endIndex - 1].name)});
        }
        try body.appendSlice(allocator, "</ListBucketResult>");
        return .{ .status = 200, .body = body.items, .headers = &.{}, .syntheticLength = null, .fill = 0 };
    }

    //
    // Answers DeleteObjects.
    //
    fn deleteObjects(self: *MockS3Server, allocator: std.mem.Allocator, parsed: ParsedRequest) !MockResponse {
        if (parsed.header("content-md5") == null) {
            return errorResponse(allocator, 400, "InvalidRequest", "Missing required header for this request: Content-MD5");
        }
        const keys = try s3_client.xmlElements(allocator, parsed.body, "Key");
        for (keys) |encodedKey| {
            const key = try s3_client.xmlDecode(allocator, encodedKey);
            const objectPath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parsed.bucket, key });
            _ = self.objects.swapRemove(objectPath);
        }
        return .{ .status = 200, .body = "<DeleteResult></DeleteResult>", .headers = &.{}, .syntheticLength = null, .fill = 0 };
    }
};

//
// Byte order for sorting keys like S3.
//
fn stringLessThan(context: void, left: []const u8, right: []const u8) bool {
    _ = context;
    return std.mem.order(u8, left, right) == .lt;
}

//
// Builds an S3 XML error response.
//
fn errorResponse(allocator: std.mem.Allocator, status: u16, code: []const u8, message: []const u8) !MockResponse {
    const body = try std.fmt.allocPrint(allocator, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<Error><Code>{s}</Code><Message>{s}</Message></Error>", .{ code, message });
    return .{ .status = status, .body = body, .headers = &.{}, .syntheticLength = null, .fill = 0 };
}

//
// Decodes %XX escapes.
//
fn decodePercent(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var output: std.ArrayList(u8) = .empty;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '%' and index + 2 < text.len) {
            const value = try std.fmt.parseInt(u8, text[index + 1 .. index + 3], 16);
            try output.append(allocator, value);
            index += 3;
            continue;
        }
        try output.append(allocator, text[index]);
        index += 1;
    }
    return output.items;
}

//
// Reads the head and body of a request.
//
fn parseRequest(allocator: std.mem.Allocator, request: *std.http.Server.Request) !ParsedRequest {
    const target = try allocator.dupe(u8, request.head.target);
    var headers: std.ArrayList(sigv4.IHeader) = .empty;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        try headers.append(allocator, .{ .name = try allocator.dupe(u8, header.name), .value = try allocator.dupe(u8, header.value) });
    }
    const method = request.head.method;
    var bodyBuffer: [4096]u8 = undefined;
    const bodyReader = request.readerExpectNone(&bodyBuffer);
    const body = try bodyReader.allocRemaining(allocator, .unlimited);

    const queryIndex = std.mem.indexOfScalar(u8, target, '?');
    const rawPath = if (queryIndex) |index| target[0..index] else target;
    var query: std.ArrayList(sigv4.IQueryParameter) = .empty;
    if (queryIndex) |index| {
        var parameters = std.mem.splitScalar(u8, target[index + 1 ..], '&');
        while (parameters.next()) |parameter| {
            if (parameter.len == 0) {
                continue;
            }
            const equalsIndex = std.mem.indexOfScalar(u8, parameter, '=');
            const name = if (equalsIndex) |equals| parameter[0..equals] else parameter;
            const value = if (equalsIndex) |equals| parameter[equals + 1 ..] else "";
            try query.append(allocator, .{ .name = try decodePercent(allocator, name), .value = try decodePercent(allocator, value) });
        }
    }

    const path = try decodePercent(allocator, rawPath);
    const withoutSlash = if (std.mem.startsWith(u8, path, "/")) path[1..] else path;
    const slashIndex = std.mem.indexOfScalar(u8, withoutSlash, '/');
    return .{
        .method = method,
        .rawPath = rawPath,
        .bucket = if (slashIndex) |index| withoutSlash[0..index] else withoutSlash,
        .key = if (slashIndex) |index| withoutSlash[index + 1 ..] else "",
        .query = query.items,
        .headers = headers.items,
        .body = body,
    };
}

//
// Checks the SigV4 Authorization header of a request against the test credentials and the payload hash.
//
fn verifySignature(allocator: std.mem.Allocator, parsed: ParsedRequest) !bool {
    const authorization = parsed.header("authorization") orelse {
        return false;
    };
    const signedHeadersStart = (std.mem.indexOf(u8, authorization, "SignedHeaders=") orelse {
        return false;
    }) + "SignedHeaders=".len;
    const signedHeadersEnd = std.mem.indexOfScalarPos(u8, authorization, signedHeadersStart, ',') orelse {
        return false;
    };
    const credentialStart = (std.mem.indexOf(u8, authorization, "Credential=") orelse {
        return false;
    }) + "Credential=".len;
    const credentialEnd = std.mem.indexOfScalarPos(u8, authorization, credentialStart, ',') orelse {
        return false;
    };
    var scope = std.mem.splitScalar(u8, authorization[credentialStart..credentialEnd], '/');
    const accessKeyId = scope.next() orelse "";
    _ = scope.next();
    const region = scope.next() orelse "";
    if (!std.mem.eql(u8, accessKeyId, ACCESS_KEY_ID)) {
        return false;
    }

    const payloadHash = parsed.header("x-amz-content-sha256") orelse {
        return false;
    };
    if (!std.mem.eql(u8, payloadHash, &sigv4.sha256Hex(parsed.body))) {
        return false;
    }

    var signedHeaders: std.ArrayList(sigv4.IHeader) = .empty;
    var names = std.mem.splitScalar(u8, authorization[signedHeadersStart..signedHeadersEnd], ';');
    while (names.next()) |name| {
        try signedHeaders.append(allocator, .{ .name = name, .value = parsed.header(name) orelse "" });
    }
    const signature = try sigv4.sign(allocator, .{
        .accessKeyId = ACCESS_KEY_ID,
        .secretAccessKey = SECRET_ACCESS_KEY,
        .sessionToken = null,
    }, .{
        .method = @tagName(parsed.method),
        .canonicalUri = parsed.rawPath,
        .query = parsed.query,
        .headers = signedHeaders.items,
        .payloadHash = payloadHash,
        .region = region,
        .service = "s3",
        .amzDate = parsed.header("x-amz-date") orelse "",
    });
    return std.mem.eql(u8, signature.authorization, authorization);
}
