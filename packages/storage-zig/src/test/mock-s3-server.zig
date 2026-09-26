const std = @import("std");
const storage_zig = @import("storage-zig");

const aws = @import("aws-c");
const s3_client = storage_zig.s3_client;

//
// A local S3-compatible HTTP server for the tests (path-style requests on 127.0.0.1).
// It implements the requests CloudStorage sends: ListObjectsV2, HeadObject, GetObject (with ranges), PutObject,
// CopyObject, DeleteObject, DeleteObjects and the multipart upload requests. It checks the SigV4 signature of every
// request against the test credentials and can inject failures. Connections are closed after each response, so
// stopping the server never waits on an idle keep-alive connection.
//

//
// A query string parameter of a request.
//
const IQueryParameter = struct {
    // The decoded name.
    name: []const u8,

    // The decoded value.
    value: []const u8,
};

//
// A header of a request.
//
const IHeader = struct {
    // The name.
    name: []const u8,

    // The value.
    value: []const u8,
};

//
// Encodes text for an XML text node (the server writes XML responses).
//
fn xmlEncode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    try s3_client.appendXmlEscaped(allocator, &output, text);
    return output.toOwnedSlice(allocator);
}

//
// Decodes the XML escapes of a text node with the SDK's aws_byte_buf_append_unescaped_xml.
//
fn xmlDecode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var buffer: aws.aws_byte_buf = undefined;
    if (aws.aws_byte_buf_init(&buffer, aws.aws_default_allocator(), text.len) != aws.AWS_OP_SUCCESS) {
        return error.OutOfMemory;
    }
    defer aws.aws_byte_buf_clean_up(&buffer);
    if (aws.aws_byte_buf_append_unescaped_xml(aws.aws_default_allocator(), s3_client.cursorOf(text), &buffer) != aws.AWS_OP_SUCCESS) {
        return error.InvalidXml;
    }
    return allocator.dupe(u8, s3_client.sliceOf(aws.aws_byte_cursor_from_buf(&buffer)));
}

//
// Returns the raw inner text of every <tag>...</tag> element of a request body (elements of the same tag do not nest
// in the bodies the client sends).
//
fn xmlElements(allocator: std.mem.Allocator, xml: []const u8, tag: []const u8) ![]const []const u8 {
    const openTag = try std.fmt.allocPrint(allocator, "<{s}>", .{tag});
    const closeTag = try std.fmt.allocPrint(allocator, "</{s}>", .{tag});
    var elements: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, xml, index, openTag)) |start| {
        const contentStart = start + openTag.len;
        const end = std.mem.indexOfPos(u8, xml, contentStart, closeTag) orelse {
            break;
        };
        try elements.append(allocator, xml[contentStart..end]);
        index = end + closeTag.len;
    }
    return elements.toOwnedSlice(allocator);
}

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

    // The raw request target (the path and the query string as they were sent).
    target: []const u8,

    // The decoded bucket.
    bucket: []const u8,

    // The decoded key (empty for bucket requests).
    key: []const u8,

    // The decoded query parameters.
    query: []const IQueryParameter,

    // The request headers.
    headers: []const IHeader,

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

    // True to answer every GetObject request with NoSuchKey, as if the object were not there.
    getObjectNoSuchKey: bool,

    // True to answer range requests without a Content-Range header.
    omitContentRange: bool,

    // Every GetObject request fails with this 503 message (null for never).
    getObjectUnavailableMessage: ?[]const u8,

    // True to close the connection of every GetObject request without answering it (a network failure).
    dropGetObjectConnections: bool,

    // The number of signature failures seen.
    signatureFailures: u32,

    // The number of requests being answered right now.
    requestsInFlight: u32,

    // The largest number of requests that were answered at the same time.
    maxRequestsInFlight: u32,

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
            .dropGetObjectConnections = false,
            .omitContentRange = false,
            .getObjectNoSuchKey = false,
            .signatureFailures = 0,
            .requestsInFlight = 0,
            .maxRequestsInFlight = 0,
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
        self.mutex.lockUncancelable(self.io);
        self.requestsInFlight += 1;
        self.maxRequestsInFlight = @max(self.maxRequestsInFlight, self.requestsInFlight);
        self.mutex.unlock(self.io);
        defer {
            self.mutex.lockUncancelable(self.io);
            self.requestsInFlight -= 1;
            self.mutex.unlock(self.io);
        }
        const parsed = try parseRequest(allocator, request);
        const response = self.handle(allocator, parsed) catch |err| blk: {
            if (err == error.ConnectionDropped) {
                return err;
            }
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
        if (!try verifySignature(parsed)) {
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
                if (parsed.header("if-none-match")) |ifNoneMatch| {
                    if (std.mem.eql(u8, ifNoneMatch, "*") and self.objects.contains(objectPath)) {
                        return errorResponse(allocator, 412, "PreconditionFailed", "At least one of the pre-conditions you specified did not hold");
                    }
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
                    const partNumbers = try xmlElements(allocator, parsed.body, "PartNumber");
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
        if (self.dropGetObjectConnections) {
            return error.ConnectionDropped;
        }
        if (self.getObjectUnavailableMessage) |message| {
            return errorResponse(allocator, 503, "ServiceUnavailable", message);
        }
        if (self.getObjectNoSuchKey) {
            return errorResponse(allocator, 404, "NoSuchKey", "The specified key does not exist.");
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
        return self.objectResponse(allocator, object, 206, rangeStart, end - rangeStart + 1, if (self.omitContentRange) null else contentRange);
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
            try xmlEncode(allocator, prefix),
            endIndex - startIndex,
            maxKeys,
            if (isTruncated) "true" else "false",
        });
        for (entries.items[startIndex..endIndex]) |entry| {
            const encodedName = try xmlEncode(allocator, entry.name);
            if (entry.isPrefix) {
                try body.print(allocator, "<CommonPrefixes><Prefix>{s}</Prefix></CommonPrefixes>", .{encodedName});
            }
            else {
                try body.print(allocator, "<Contents><Key>{s}</Key><Size>0</Size></Contents>", .{encodedName});
            }
        }
        if (isTruncated) {
            try body.print(allocator, "<NextContinuationToken>{s}</NextContinuationToken>", .{try xmlEncode(allocator, entries.items[endIndex - 1].name)});
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
        const keys = try xmlElements(allocator, parsed.body, "Key");
        for (keys) |encodedKey| {
            const key = try xmlDecode(allocator, encodedKey);
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
    var headers: std.ArrayList(IHeader) = .empty;
    var iterator = request.iterateHeaders();
    while (iterator.next()) |header| {
        try headers.append(allocator, .{ .name = try allocator.dupe(u8, header.name), .value = try allocator.dupe(u8, header.value) });
    }
    const method = request.head.method;
    // A request with neither Content-Length nor Transfer-Encoding has no body (RFC 9112 section 6.3), but std.http
    // reads such a body until the connection closes, so its length is set to zero.
    if (request.head.content_length == null and request.head.transfer_encoding == .none) {
        request.head.content_length = 0;
    }
    var bodyBuffer: [4096]u8 = undefined;
    const bodyReader = request.readerExpectNone(&bodyBuffer);
    const body = try bodyReader.allocRemaining(allocator, .unlimited);

    const queryIndex = std.mem.indexOfScalar(u8, target, '?');
    const rawPath = if (queryIndex) |index| target[0..index] else target;
    var query: std.ArrayList(IQueryParameter) = .empty;
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
        .target = target,
        .bucket = if (slashIndex) |index| withoutSlash[0..index] else withoutSlash,
        .key = if (slashIndex) |index| withoutSlash[index + 1 ..] else "",
        .query = query.items,
        .headers = headers.items,
        .body = body,
    };
}


//
// Checks the SigV4 Authorization header of a request: the access key id, the payload hash against the body, and the
// signature, which the SDK's signer (aws-c-auth) computes again from the signed headers the request lists, the request
// time and the test credentials.
//
fn verifySignature(parsed: ParsedRequest) !bool {
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
    // S3 accepts "UNSIGNED-PAYLOAD" in place of the hash of the body.
    var bodyHash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(parsed.body, &bodyHash, .{});
    if (!std.mem.eql(u8, payloadHash, "UNSIGNED-PAYLOAD") and !std.mem.eql(u8, payloadHash, &std.fmt.bytesToHex(bodyHash, .lower))) {
        return false;
    }
    const amzDate = parsed.header("x-amz-date") orelse {
        return false;
    };

    // The request as the client signed it: the method, the target and the signed headers, except the ones the signer
    // adds itself.
    const sdkAllocator = aws.aws_default_allocator();
    const message = aws.aws_http_message_new_request(sdkAllocator) orelse {
        return error.OutOfMemory;
    };
    defer _ = aws.aws_http_message_release(message);
    _ = aws.aws_http_message_set_request_method(message, s3_client.cursorOf(@tagName(parsed.method)));
    _ = aws.aws_http_message_set_request_path(message, s3_client.cursorOf(parsed.target));
    var names = std.mem.splitScalar(u8, authorization[signedHeadersStart..signedHeadersEnd], ';');
    while (names.next()) |name| {
        if (std.mem.eql(u8, name, "x-amz-date") or std.mem.eql(u8, name, "x-amz-content-sha256")) {
            continue;
        }
        const messageHeader: aws.aws_http_header = .{
            .name = s3_client.cursorOf(name),
            .value = s3_client.cursorOf(parsed.header(name) orelse ""),
            .compression = aws.AWS_HTTP_HEADER_COMPRESSION_USE_CACHE,
        };
        _ = aws.aws_http_message_add_header(message, messageHeader);
    }

    var signingDate: aws.struct_aws_date_time = undefined;
    var amzDateCursor = s3_client.cursorOf(amzDate);
    if (aws.aws_date_time_init_from_str_cursor(&signingDate, &amzDateCursor, aws.AWS_DATE_FORMAT_ISO_8601_BASIC) != aws.AWS_OP_SUCCESS) {
        return false;
    }
    const credentials = aws.aws_credentials_new(sdkAllocator, s3_client.cursorOf(ACCESS_KEY_ID), s3_client.cursorOf(SECRET_ACCESS_KEY), s3_client.cursorOf(""), std.math.maxInt(u64)) orelse {
        return error.OutOfMemory;
    };
    defer aws.aws_credentials_release(credentials);
    var config = std.mem.zeroes(s3_client.SigningConfigAws);
    config.config_type = aws.AWS_SIGNING_CONFIG_AWS;
    config.algorithm = aws.AWS_SIGNING_ALGORITHM_V4;
    config.signature_type = aws.AWS_ST_HTTP_REQUEST_HEADERS;
    config.region = s3_client.cursorOf(region);
    config.service = s3_client.cursorOf("s3");
    config.date = signingDate;
    config.signed_body_value = s3_client.cursorOf(payloadHash);
    config.signed_body_header = aws.AWS_SBHT_X_AMZ_CONTENT_SHA256;
    config.credentials = credentials;

    const signable = aws.aws_signable_new_http_request(sdkAllocator, message) orelse {
        return error.OutOfMemory;
    };
    defer aws.aws_signable_destroy(signable);
    var signing: SigningOutcome = .{
        .message = message,
        .completed = false,
        .errorCode = 0,
    };
    if (aws.aws_sign_request_aws(sdkAllocator, signable, @ptrCast(&config), SigningOutcome.onComplete, &signing) != aws.AWS_OP_SUCCESS) {
        return false;
    }
    // With the credentials in the config the signer completes before aws_sign_request_aws returns.
    if (!signing.completed) {
        return error.SigningDidNotComplete;
    }
    if (signing.errorCode != 0) {
        return false;
    }
    const headers = aws.aws_http_message_get_headers(message);
    var expected: aws.aws_byte_cursor = undefined;
    if (aws.aws_http_headers_get(headers, s3_client.cursorOf("Authorization"), &expected) != aws.AWS_OP_SUCCESS) {
        return false;
    }
    return std.mem.eql(u8, s3_client.sliceOf(expected), authorization);
}

//
// The result of signing a request again in verifySignature.
//
const SigningOutcome = struct {
    // The request the signing result is applied to.
    message: *aws.struct_aws_http_message,

    // True once the signer called back.
    completed: bool,

    // The error of the signer (0 for success).
    errorCode: c_int,

    //
    // The signer's completion callback: applies the signature to the request.
    //
    fn onComplete(result: ?*aws.struct_aws_signing_result, error_code: c_int, userdata: ?*anyopaque) callconv(.c) void {
        const self: *SigningOutcome = @ptrCast(@alignCast(userdata.?));
        self.completed = true;
        self.errorCode = error_code;
        if (error_code == 0) {
            if (aws.aws_apply_signing_result_to_http_request(self.message, aws.aws_default_allocator(), result) != aws.AWS_OP_SUCCESS) {
                self.errorCode = aws.aws_last_error();
            }
        }
    }
};
