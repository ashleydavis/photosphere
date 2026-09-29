const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const CloudStorage = storage_zig.cloud_storage.CloudStorage;
const s3_client = storage_zig.s3_client;
const errors = utils.errors;

//
// How a CannedServer answers the requests of one method.
//
const ICannedAnswer = struct {
    // The method answered (null for any).
    method: ?std.http.Method,

    // The status of the response.
    status: std.http.Status,

    // The body of the response (empty for none).
    body: []const u8,

    // The headers of the response besides its Content-Type.
    headers: []const std.http.Header,
};

//
// An S3 endpoint on this machine that answers the requests of each method with one status and body, and remembers
// the target of the last request: a server failing the way a real S3 service does when it is having trouble, or
// answering the way no S3 service should (the real S3 client talks to it over HTTP, as it does to MinIO).
//
const CannedServer = struct {
    // The io the server runs on.
    io: std.Io,

    // The listening socket.
    server: std.Io.net.Server,

    // The port the system chose.
    port: u16,

    // Runs the loop that answers requests.
    group: std.Io.Group,

    // The answers, the first one for the method of a request being the one given.
    answers: []const ICannedAnswer,

    // The answer of start, for every request.
    onlyAnswer: [1]ICannedAnswer,

    // Set to stop the loop: it is checked after each connection, and stop makes a last connection to wake it.
    stopping: std.atomic.Value(bool),

    // Guards target and targetLength.
    targetMutex: std.Io.Mutex,

    // The target (path and query) of the last request.
    target: [4096]u8,

    // The length of the target in `target`.
    targetLength: usize,

    //
    // Starts the server on a free port of 127.0.0.1, answering every request with the status and body.
    //
    fn start(self: *CannedServer, io: std.Io, status: std.http.Status, body: []const u8) !void {
        try self.open(io);
        self.onlyAnswer = .{
            .{
                .method = null,
                .status = status,
                .body = body,
                .headers = &.{},
            },
        };
        self.answers = &self.onlyAnswer;
        try self.group.concurrent(io, serve, .{self});
    }

    //
    // Starts the server on a free port of 127.0.0.1, answering with the answers (which must outlive it).
    //
    fn startWithAnswers(self: *CannedServer, io: std.Io, answers: []const ICannedAnswer) !void {
        try self.open(io);
        self.answers = answers;
        try self.group.concurrent(io, serve, .{self});
    }

    //
    // Listens on a free port of 127.0.0.1, without answers yet.
    //
    fn open(self: *CannedServer, io: std.Io) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
        self.* = .{
            .io = io,
            .server = try address.listen(io, .{
                .reuse_address = true,
            }),
            .port = 0,
            .group = .init,
            .answers = &.{},
            .onlyAnswer = undefined,
            .stopping = .init(false),
            .targetMutex = .init,
            .target = undefined,
            .targetLength = 0,
        };
        self.port = self.server.socket.address.getPort();
    }

    //
    // Stops the loop and closes the socket.
    //
    fn stop(self: *CannedServer) void {
        self.stopping.store(true, .release);
        const address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch unreachable;
        if (address.connect(self.io, .{
            .mode = .stream,
        })) |stream| {
            stream.close(self.io);
        }
        else |_| {}
        self.group.await(self.io) catch {};
        self.server.deinit(self.io);
    }

    //
    // Answers connections until stopped.
    //
    fn serve(self: *CannedServer) void {
        while (!self.stopping.load(.acquire)) {
            const stream = self.server.accept(self.io) catch {
                return;
            };
            self.answer(stream);
        }
    }

    //
    // Answers the request of one connection with the status and body, then closes the connection.
    //
    fn answer(self: *CannedServer, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);
        var receiveBuffer: [16 * 1024]u8 = undefined;
        var sendBuffer: [4096]u8 = undefined;
        var connectionReader = stream.reader(self.io, &receiveBuffer);
        var connectionWriter = stream.writer(self.io, &sendBuffer);
        var httpServer = std.http.Server.init(&connectionReader.interface, &connectionWriter.interface);
        var request = httpServer.receiveHead() catch {
            return;
        };
        self.targetMutex.lockUncancelable(self.io);
        self.targetLength = @min(request.head.target.len, self.target.len);
        @memcpy(self.target[0..self.targetLength], request.head.target[0..self.targetLength]);
        self.targetMutex.unlock(self.io);

        // Read the body of the request, if its method has one, before answering. (For a method without a body,
        // readerExpectNone returns std.Io.Reader.ending, a constant that discarding would write to.)
        var bodyBuffer: [4096]u8 = undefined;
        const bodyReader = request.readerExpectNone(&bodyBuffer);
        if (request.head.method.requestHasBody()) {
            _ = bodyReader.discardRemaining() catch {
                return;
            };
        }
        const chosenAnswer = for (self.answers) |candidate| {
            if (candidate.method == null or candidate.method.? == request.head.method) {
                break candidate;
            }
        } else {
            request.respond("", .{
                .status = .method_not_allowed,
                .keep_alive = false,
            }) catch {};
            return;
        };
        var headers: [8]std.http.Header = undefined;
        headers[0] = .{
            .name = "Content-Type",
            .value = "application/xml",
        };
        const headerCount = 1 + chosenAnswer.headers.len;
        @memcpy(headers[1..headerCount], chosenAnswer.headers);
        request.respond(chosenAnswer.body, .{
            .status = chosenAnswer.status,
            .keep_alive = false,
            .extra_headers = headers[0..headerCount],
        }) catch {};
    }

    //
    // Gets a copy of the target of the last request.
    //
    fn lastTarget(self: *CannedServer, allocator: std.mem.Allocator) ![]const u8 {
        self.targetMutex.lockUncancelable(self.io);
        defer self.targetMutex.unlock(self.io);
        return allocator.dupe(u8, self.target[0..self.targetLength]);
    }

    //
    // The endpoint of the server.
    //
    fn endpoint(self: *CannedServer, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.port});
    }
};

//
// Makes a CloudStorage whose S3 endpoint is the server.
//
fn storageOf(server: *CannedServer, allocator: std.mem.Allocator, io: std.Io) !CloudStorage {
    return CloudStorage.init(io, "bucket", .{
        .accessKeyId = "key",
        .secretAccessKey = "secret",
        .region = "us-east-1",
        .endpoint = try server.endpoint(allocator),
    });
}

//
// Expects an operation to have thrown a WrappedError with the message, whose cause is the S3 error with the name
// and the HTTP status (0 for an S3 request without a response, null for an error that is not the S3 client's, which
// leaves the status of the last S3 error as it was).
//
fn expectFailure(result: anytype, expectedMessage: []const u8, expectedCauseName: []const u8, expectedStatus: ?u16) !void {
    if (result) |_| {
        return error.TestExpectedError;
    }
    else |err| {
        try std.testing.expectEqual(error.Thrown, err);
        try std.testing.expectEqualStrings("WrappedError", errors.lastErrorName());
        try std.testing.expectEqualStrings(expectedMessage, errors.lastErrorMessage());
        try std.testing.expectEqualStrings(expectedCauseName, errors.lastErrorCauseNames()[0]);
        if (expectedStatus) |status| {
            try std.testing.expectEqual(status, s3_client.lastHttpStatusCode());
        }
    }
}

test "an S3 error response without a body is thrown as the SDK throws it, Unknown with the message UnknownError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .bad_request, "");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    try expectFailure(storage.read(allocator, io, "dir/file.txt"), "Failed to read dir/file.txt: UnknownError: UnknownError", "Unknown", 400);
    try expectFailure(storage.info(allocator, io, "dir/file.txt"), "Failed to get info for dir/file.txt: UnknownError: UnknownError", "Unknown", 400);
    try expectFailure(storage.write(allocator, io, "dir/file.txt", "text/plain", "data"), "Failed to write to dir/file.txt: UnknownError: UnknownError", "Unknown", 400);
    try expectFailure(storage.listFiles(allocator, io, "dir", 10, null), "Failed to list files in dir: UnknownError: UnknownError", "Unknown", 400);
    try expectFailure(storage.fileExists(allocator, io, "dir/file.txt"), "Failed to check if file exists: UnknownError: UnknownError", "Unknown", 400);

    // deleteFile ignores the failure, as CloudStorage.deleteFile does.
    try storage.deleteFile(allocator, io, "dir/file.txt");
}

test "an S3 404 without a body is NotFound, so info and fileExists report a missing file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .not_found, "");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    try std.testing.expectEqual(null, try storage.info(allocator, io, "dir/file.txt"));
    try std.testing.expect(!try storage.fileExists(allocator, io, "dir/file.txt"));
    try expectFailure(storage.read(allocator, io, "dir/file.txt"), "Failed to read dir/file.txt: UnknownError: UnknownError", "NotFound", 404);
}

test "an S3 error response is thrown with the Code and Message of its body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .forbidden, "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>AccessDenied</Code><Message>Access &amp; Denied</Message></Error>");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    try expectFailure(storage.read(allocator, io, "dir/file.txt"), "Failed to read dir/file.txt: Access & Denied: Access & Denied", "AccessDenied", 403);
    try expectFailure(storage.write(allocator, io, "dir/file.txt", "text/plain", "data"), "Failed to write to dir/file.txt: Access & Denied: Access & Denied", "AccessDenied", 403);
    try expectFailure(storage.listFiles(allocator, io, "dir", 10, null), "Failed to list files in dir: Access & Denied: Access & Denied", "AccessDenied", 403);

    // A HEAD response has no body.
    try expectFailure(storage.info(allocator, io, "dir/file.txt"), "Failed to get info for dir/file.txt: UnknownError: UnknownError", "Unknown", 403);
}

test "an S3 error response without a Message is thrown with the message UnknownError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .forbidden, "<Error><Code>AccessDenied</Code></Error>");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    try expectFailure(storage.read(allocator, io, "dir/file.txt"), "Failed to read dir/file.txt: UnknownError: UnknownError", "AccessDenied", 403);
}

test "an S3 error response without a Code is thrown as Unknown with its Message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .bad_request, "<Error><Message>Bad thing.</Message></Error>");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    try expectFailure(storage.read(allocator, io, "dir/file.txt"), "Failed to read dir/file.txt: Bad thing.: Bad thing.", "Unknown", 400);
}

//
// TODO: the JavaScript SDK throws the Code and Message of the body of a 500 or 503 (InternalError, "We encountered
// an internal error. Please try again."), but aws-c-s3 keeps neither the status nor the body of a response it would
// retry (see s3-client.zig, throwResultError), so the port throws the SDK's own error for them.
//
test "an S3 500 or 503 fails with the error aws-c-s3 gives it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var internalErrorServer: CannedServer = undefined;
    try internalErrorServer.start(io, .internal_server_error, "<Error><Code>InternalError</Code><Message>We encountered an internal error. Please try again.</Message></Error>");
    defer internalErrorServer.stop();
    var internalErrorStorage = try storageOf(&internalErrorServer, allocator, io);
    defer internalErrorStorage.s3.deinit();
    var slowDownServer: CannedServer = undefined;
    try slowDownServer.start(io, .service_unavailable, "");
    defer slowDownServer.stop();
    var slowDownStorage = try storageOf(&slowDownServer, allocator, io);
    defer slowDownStorage.s3.deinit();

    try expectFailure(internalErrorStorage.read(allocator, io, "dir/file.txt"), "Failed to read dir/file.txt: Response code indicates internal server error: Response code indicates internal server error", "AWS_ERROR_S3_INTERNAL_ERROR", 0);
    try expectFailure(internalErrorStorage.write(allocator, io, "dir/file.txt", "text/plain", "data"), "Failed to write to dir/file.txt: Response code indicates internal server error: Response code indicates internal server error", "AWS_ERROR_S3_INTERNAL_ERROR", 0);
    try expectFailure(slowDownStorage.listFiles(allocator, io, "dir", 10, null), "Failed to list files in dir: Response code indicates throttling: Response code indicates throttling", "AWS_ERROR_S3_SLOW_DOWN", 0);
}

test "writeStream and writeStreamHashed report the error of the server, for a stream in one part or in several" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .forbidden, "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();
    const expected = "Failed to write stream to dir/file.txt: Access Denied: Access Denied";

    var small = std.Io.Reader.fixed("small");
    try expectFailure(storage.writeStream(allocator, io, "dir/file.txt", "text/plain", &small, null), expected, "AccessDenied", 403);

    // More than the 5MB of one part, so it goes up as a multipart upload of a stream.
    const large = try allocator.alloc(u8, 6 * 1024 * 1024);
    @memset(large, 'x');
    var largeReader = std.Io.Reader.fixed(large);
    try expectFailure(storage.writeStream(allocator, io, "dir/file.txt", "text/plain", &largeReader, null), expected, "AccessDenied", 403);

    var hashed = std.Io.Reader.fixed("hashed");
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("hashed", &hash, .{});
    try expectFailure(storage.writeStreamHashed(allocator, io, "dir/file.txt", "text/plain", &hashed, "hashed".len, &hash), expected, "AccessDenied", 403);

    // Declared larger than one request may carry, so it goes up as a multipart upload without the hash.
    var declaredLarge = std.Io.Reader.fixed("hashed");
    try expectFailure(storage.writeStreamHashed(allocator, io, "dir/file.txt", "text/plain", &declaredLarge, 2 * 1024 * 1024 * 1024, &hash), expected, "AccessDenied", 403);
}

//
// Makes an environment of the variables given, to stand in for the process environment.
//
fn environmentOf(allocator: std.mem.Allocator, variables: []const [2][]const u8) !*std.process.Environ.Map {
    const map = try allocator.create(std.process.Environ.Map);
    map.* = std.process.Environ.Map.init(allocator);
    for (variables) |variable| {
        try map.put(variable[0], variable[1]);
    }
    return map;
}

test "a storage given no credentials, where the environment has none either, cannot load any, like the SDK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .forbidden, "");
    defer server.stop();
    const previous = node_utils.process_env.getEnvironMap();
    defer node_utils.process_env.setEnvironMap(previous);
    node_utils.process_env.setEnvironMap(try environmentOf(allocator, &.{
        .{ "AWS_REGION", "us-east-1" },
        .{ "AWS_ENDPOINT", try server.endpoint(allocator) },
    }));
    var storage = CloudStorage.init(io, "bucket", null);
    defer storage.s3.deinit();

    try expectFailure(storage.info(allocator, io, "dir/file.txt"), "Failed to get info for dir/file.txt: Could not load credentials from any providers: Could not load credentials from any providers", "CredentialsProviderError", 0);
}

test "a storage given no region, where the environment has none either, fails with Region is missing, like the SDK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .forbidden, "");
    defer server.stop();
    const previous = node_utils.process_env.getEnvironMap();
    defer node_utils.process_env.setEnvironMap(previous);
    node_utils.process_env.setEnvironMap(try environmentOf(allocator, &.{
        .{ "AWS_ACCESS_KEY_ID", "key" },
        .{ "AWS_SECRET_ACCESS_KEY", "secret" },
        .{ "AWS_SESSION_TOKEN", "token" },
        .{ "AWS_ENDPOINT", try server.endpoint(allocator) },
    }));
    var storage = CloudStorage.init(io, "bucket", null);
    defer storage.s3.deinit();

    try expectFailure(storage.info(allocator, io, "dir/file.txt"), "Failed to get info for dir/file.txt: Region is missing: Region is missing", "Error", 0);
}

test "a storage given no credentials uses those of the environment, session token included, like the SDK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .forbidden, "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>");
    defer server.stop();
    const previous = node_utils.process_env.getEnvironMap();
    defer node_utils.process_env.setEnvironMap(previous);
    node_utils.process_env.setEnvironMap(try environmentOf(allocator, &.{
        .{ "AWS_ACCESS_KEY_ID", "key" },
        .{ "AWS_SECRET_ACCESS_KEY", "secret" },
        .{ "AWS_SESSION_TOKEN", "token" },
        .{ "AWS_REGION", "us-east-1" },
        .{ "AWS_ENDPOINT", try server.endpoint(allocator) },
    }));
    var storage = CloudStorage.init(io, "bucket", null);
    defer storage.s3.deinit();

    // The request was signed and sent, so the server's answer is the error.
    try expectFailure(storage.read(allocator, io, "dir/file.txt"), "Failed to read dir/file.txt: Access Denied: Access Denied", "AccessDenied", 403);
    try std.testing.expectEqualStrings("/dir/file.txt", try server.lastTarget(allocator));
}

test "an endpoint that is not a URL is a TypeError, and one the endpoint rules refuse is named by its href, like the SDK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var notAUrl = CloudStorage.init(io, "bucket", .{
        .accessKeyId = "key",
        .secretAccessKey = "secret",
        .region = "us-east-1",
        .endpoint = "not a url",
    });
    defer notAUrl.s3.deinit();
    var notHttp = CloudStorage.init(io, "bucket", .{
        .accessKeyId = "key",
        .secretAccessKey = "secret",
        .region = "us-east-1",
        .endpoint = "ftp://127.0.0.1",
    });
    defer notHttp.s3.deinit();

    try expectFailure(notAUrl.info(allocator, io, "dir/file.txt"), "Failed to get info for dir/file.txt: \"not a url\" cannot be parsed as a URL.: \"not a url\" cannot be parsed as a URL.", "TypeError", 0);
    try expectFailure(notHttp.info(allocator, io, "dir/file.txt"), "Failed to get info for dir/file.txt: Custom endpoint `ftp://127.0.0.1/` was not a valid URI: Custom endpoint `ftp://127.0.0.1/` was not a valid URI", "Error", 0);
}

test "endpointHref gives the href new URL gives: a path of / for a special scheme without one, and the endpoint otherwise" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    try std.testing.expectEqualStrings("http://127.0.0.1:9000/", try s3_client.endpointHref(allocator, "http://127.0.0.1:9000"));
    try std.testing.expectEqualStrings("HTTPS://example.com/", try s3_client.endpointHref(allocator, "HTTPS://example.com"));
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/path", try s3_client.endpointHref(allocator, "http://127.0.0.1:9000/path"));
    try std.testing.expectEqualStrings("http://127.0.0.1:9000?query", try s3_client.endpointHref(allocator, "http://127.0.0.1:9000?query"));
    try std.testing.expectEqualStrings("http://127.0.0.1:9000#fragment", try s3_client.endpointHref(allocator, "http://127.0.0.1:9000#fragment"));
    try std.testing.expectEqualStrings("custom://example.com", try s3_client.endpointHref(allocator, "custom://example.com"));
    try std.testing.expectEqualStrings("localhost:9000", try s3_client.endpointHref(allocator, "localhost:9000"));
    try std.testing.expectError(error.Thrown, s3_client.endpointHref(allocator, "not a url"));
    try std.testing.expectEqualStrings("TypeError", errors.lastErrorName());
    try std.testing.expectEqualStrings("\"not a url\" cannot be parsed as a URL.", errors.lastErrorMessage());
}

test "an S3 error is named by its Code even when the port does not list the Code, like the SDK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .conflict, "<Error><Code>OperationAborted</Code><Message>A conflicting operation is in progress.</Message></Error>");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    try expectFailure(storage.read(allocator, io, "dir/file.txt"), "Failed to read dir/file.txt: A conflicting operation is in progress.: A conflicting operation is in progress.", "OperationAborted", 409);
}

test "staticErrorName keeps one copy of each code, and names the codes past its limit S3ServiceException" {
    const io = std.testing.io;
    const first = try s3_client.staticErrorName(io, "OperationAborted");
    try std.testing.expectEqualStrings("OperationAborted", first);
    try std.testing.expectEqual(first.ptr, (try s3_client.staticErrorName(io, "OperationAborted")).ptr);
    try std.testing.expectEqualStrings("NoSuchKey", try s3_client.staticErrorName(io, "NoSuchKey"));

    var buffer: [32]u8 = undefined;
    var count: usize = 0;
    while (count < 300) {
        const code = try std.fmt.bufPrint(&buffer, "LimitTestCode{d}", .{count});
        if (std.mem.eql(u8, try s3_client.staticErrorName(io, code), "S3ServiceException")) {
            break;
        }
        count += 1;
    }
    try std.testing.expect(count < 256);
    try std.testing.expectEqual(first.ptr, (try s3_client.staticErrorName(io, "OperationAborted")).ptr);
}

test "the root of a bucket, a path ending in //, is listed with the prefix of the whole bucket" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .ok, "<ListBucketResult><Contents><Key>top.txt</Key></Contents><CommonPrefixes><Prefix>dir/</Prefix></CommonPrefixes></ListBucketResult>");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    const files = try storage.listFiles(allocator, io, "bucket//", 10, null);
    try std.testing.expectEqual(@as(usize, 1), files.names.len);
    try std.testing.expectEqualStrings("top.txt", files.names[0]);
    try std.testing.expectEqualStrings("/bucket/?list-type=2&delimiter=%2F&max-keys=10&prefix=", try server.lastTarget(allocator));
    const dirs = try storage.listDirs(allocator, io, "bucket//", 10, null);
    try std.testing.expectEqual(@as(usize, 1), dirs.names.len);
    try std.testing.expectEqualStrings("dir", dirs.names[0]);
    try std.testing.expectEqualStrings("/bucket/?list-type=2&delimiter=%2F&max-keys=10&prefix=", try server.lastTarget(allocator));
    try std.testing.expect(try storage.dirExists(allocator, io, "bucket//"));
    try std.testing.expectEqualStrings("/bucket/?list-type=2&max-keys=1&prefix=", try server.lastTarget(allocator));
    _ = try storage.listFiles(allocator, io, "bucket//", 10, "next/token");
    try std.testing.expectEqualStrings("/bucket/?list-type=2&delimiter=%2F&max-keys=10&prefix=&continuation-token=next%2Ftoken", try server.lastTarget(allocator));
}

test "a directory with only subdirectories is not empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .ok, "<ListBucketResult><CommonPrefixes><Prefix>dir/sub/</Prefix></CommonPrefixes></ListBucketResult>");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    try std.testing.expect(!try storage.isEmpty(allocator, io, "bucket/dir"));
}

test "info fails for a file whose HEAD response has no Last-Modified, like the TypeScript" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .ok, "");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    try expectFailure(storage.info(allocator, io, "bucket/dir/file.txt"), "Failed to get info for bucket/dir/file.txt: LastModified is undefined for bucket/dir/file.txt: LastModified is undefined for bucket/dir/file.txt", "Error", null);
}

test "storedHash reports an error of the server other than not found" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var server: CannedServer = undefined;
    try server.start(io, .forbidden, "");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    try expectFailure(storage.storedHash(allocator, io, "bucket/dir/file.txt"), "Failed to get the stored hash of bucket/dir/file.txt: UnknownError: UnknownError", "Unknown", 403);
}

test "writeStream reports the error of a stream that cannot be read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    // A multipart upload is started and its parts are taken, until it is aborted.
    const answers = [_]ICannedAnswer{
        .{
            .method = .POST,
            .status = .ok,
            .body = "<InitiateMultipartUploadResult><Bucket>bucket</Bucket><Key>dir/file.txt</Key><UploadId>upload</UploadId></InitiateMultipartUploadResult>",
            .headers = &.{},
        },
        .{
            .method = .PUT,
            .status = .ok,
            .body = "",
            .headers = &.{
                .{
                    .name = "ETag",
                    .value = "\"etag\"",
                },
            },
        },
        .{
            .method = .DELETE,
            .status = .no_content,
            .body = "",
            .headers = &.{},
        },
    };
    var server: CannedServer = undefined;
    try server.startWithAnswers(io, &answers);
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    var failing = std.Io.Reader.failing;
    try expectFailure(storage.writeStream(allocator, io, "bucket/dir/file.txt", "text/plain", &failing, null), "Failed to write stream to bucket/dir/file.txt: ReadFailed: ReadFailed", "ReadFailed", null);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash("", &hash, .{});
    var failingHashed = std.Io.Reader.failing;
    try expectFailure(storage.writeStreamHashed(allocator, io, "bucket/dir/file.txt", "text/plain", &failingHashed, 10, &hash), "Failed to write stream to bucket/dir/file.txt: ReadFailed: ReadFailed", "ReadFailed", null);

    // A stream that fails after its first part, which has gone to the SDK already.
    var partThenFailure: PartThenFailureReader = undefined;
    partThenFailure.init(6 * 1024 * 1024);
    try expectFailure(storage.writeStream(allocator, io, "bucket/dir/file.txt", "text/plain", &partThenFailure.reader, null), "Failed to write stream to bucket/dir/file.txt: ReadFailed: ReadFailed", "ReadFailed", null);
}

//
// A stream of a number of zero bytes that then fails to read.
//
const PartThenFailureReader = struct {
    // The stream.
    reader: std.Io.Reader,

    // The bytes left before the failure.
    remaining: usize,

    // The buffer of the stream.
    buffer: [64 * 1024]u8,

    //
    // Makes a stream of `length` zero bytes then a failure, in place (the stream holds its own buffer).
    //
    fn init(self: *PartThenFailureReader, length: usize) void {
        self.* = .{
            .reader = .{
                .vtable = &.{
                    .stream = stream,
                },
                .buffer = &self.buffer,
                .seek = 0,
                .end = 0,
            },
            .remaining = length,
            .buffer = undefined,
        };
    }

    //
    // Writes the next zero bytes, or fails once they are all read.
    //
    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *PartThenFailureReader = @fieldParentPtr("reader", reader);
        if (self.remaining == 0) {
            return error.ReadFailed;
        }
        const count = try writer.splatByte(0, limit.minInt(self.remaining));
        self.remaining -= count;
        return count;
    }
};

//
// A log that keeps its verbose lines (the [LOCK] lines of the lock functions) and drops everything else.
//
const RecordingLog = struct {
    // Allocates the lines.
    allocator: std.mem.Allocator,

    // The verbose lines, in the order they were logged.
    lines: std.ArrayList([]const u8),

    //
    // Gets the log interface of the recording log.
    //
    fn ilog(self: *RecordingLog) utils.log.ILog {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    //
    // Whether a line containing the text was logged.
    //
    fn logged(self: *RecordingLog, text: []const u8) bool {
        for (self.lines.items) |line| {
            if (std.mem.indexOf(u8, line, text) != null) {
                return true;
            }
        }
        return false;
    }

    //
    // The functions of the recording log.
    //
    const vtable: utils.log.ILog.VTable = .{
        .info = ignore,
        .verbose = verbose,
        .@"error" = ignore,
        .exception = ignoreException,
        .warn = ignore,
        .debug = ignore,
        .tool = ignoreTool,
        .event = ignore,
        .verboseEnabled = verboseEnabled,
        .getLogDetails = getLogDetails,
    };

    //
    // Keeps a verbose line.
    //
    fn verbose(pointer: *anyopaque, message: []const u8) void {
        const self: *RecordingLog = @ptrCast(@alignCast(pointer));
        const line = self.allocator.dupe(u8, message) catch @panic("out of memory");
        self.lines.append(self.allocator, line) catch @panic("out of memory");
    }

    //
    // Drops a message.
    //
    fn ignore(pointer: *anyopaque, message: []const u8) void {
        _ = pointer;
        _ = message;
    }

    //
    // Drops an exception.
    //
    fn ignoreException(pointer: *anyopaque, message: []const u8, _: anyerror) void {
        _ = pointer;
        _ = message;
    }

    //
    // Drops the output of a tool.
    //
    fn ignoreTool(pointer: *anyopaque, toolName: []const u8, data: utils.log.IToolOutput) void {
        _ = pointer;
        _ = toolName;
        _ = data;
    }

    //
    // Verbose logging is on.
    //
    fn verboseEnabled(pointer: *anyopaque) bool {
        _ = pointer;
        return true;
    }

    //
    // There is no log file.
    //
    fn getLogDetails(pointer: *anyopaque, allocator: std.mem.Allocator, io: std.Io) anyerror!utils.log.ILogDetails {
        _ = pointer;
        _ = allocator;
        _ = io;
        return error.NoLogFile;
    }
};

//
// A lock written a minute ago, older than the timeout of a write lock.
//
fn staleLock(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std.Io.Clock.real.now(std.testing.io).toMilliseconds() - 60_000;
    return std.fmt.allocPrint(allocator, "{{\"owner\":\"dead-owner\",\"acquiredAt\":\"2020-01-01T00:00:00.000Z\",\"timestamp\":{d}}}", .{timestamp});
}

test "a lock is taken, released, and refused when the server fails, and the verbose log says each, for a key with a leading slash" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var recordingLog: RecordingLog = .{
        .allocator = allocator,
        .lines = .empty,
    };
    const previousLog = utils.log.log;
    utils.log.setLog(recordingLog.ilog());
    defer utils.log.setLog(previousLog);
    var server: CannedServer = undefined;
    try server.start(io, .ok, "");
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();
    var failingServer: CannedServer = undefined;
    try failingServer.start(io, .forbidden, "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>");
    defer failingServer.stop();
    var failingStorage = try storageOf(&failingServer, allocator, io);
    defer failingStorage.s3.deinit();

    try std.testing.expect(try storage.acquireWriteLock(allocator, io, "bucket//dir/file.lock", "owner"));
    try std.testing.expectEqualStrings("/bucket/dir/file.lock", try server.lastTarget(allocator));
    try std.testing.expect(recordingLog.logged(",ACQUIRE_SUCCESS,"));
    try std.testing.expectEqual(null, try storage.checkWriteLock(allocator, io, "bucket//dir/file.lock"));
    try std.testing.expectEqualStrings("/bucket/dir/file.lock", try server.lastTarget(allocator));
    try storage.releaseWriteLock(allocator, io, "bucket//dir/file.lock");
    try std.testing.expectEqualStrings("/bucket/dir/file.lock", try server.lastTarget(allocator));
    try std.testing.expect(recordingLog.logged(",RELEASE_SUCCESS,"));

    try expectFailure(failingStorage.acquireWriteLock(allocator, io, "bucket/dir/file.lock", "owner"), "Failed to acquire write lock for bucket/dir/file.lock: Access Denied: Access Denied", "AccessDenied", 403);
    try std.testing.expect(recordingLog.logged(",ACQUIRE_FAILED_ERROR,"));
    try failingStorage.releaseWriteLock(allocator, io, "bucket/dir/file.lock");
    try std.testing.expect(recordingLog.logged(",RELEASE_FAILED,"));
}

test "a lock that exists but reads back as nothing is refused, not broken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var recordingLog: RecordingLog = .{
        .allocator = allocator,
        .lines = .empty,
    };
    const previousLog = utils.log.log;
    utils.log.setLog(recordingLog.ilog());
    defer utils.log.setLog(previousLog);
    const answers = [_]ICannedAnswer{
        .{
            .method = .PUT,
            .status = .precondition_failed,
            .body = "",
            .headers = &.{},
        },
        .{
            .method = .GET,
            .status = .ok,
            .body = "",
            .headers = &.{},
        },
    };
    var server: CannedServer = undefined;
    try server.startWithAnswers(io, &answers);
    defer server.stop();
    var storage = try storageOf(&server, allocator, io);
    defer storage.s3.deinit();

    try std.testing.expect(!try storage.acquireWriteLock(allocator, io, "bucket/dir/file.lock", "owner"));
    try std.testing.expect(recordingLog.logged(",ACQUIRE_FAILED_UNREADABLE,"));
}

test "a stale lock that cannot be deleted, or cannot be written again once deleted, is not taken" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const io = std.testing.io;
    var recordingLog: RecordingLog = .{
        .allocator = allocator,
        .lines = .empty,
    };
    const previousLog = utils.log.log;
    utils.log.setLog(recordingLog.ilog());
    defer utils.log.setLog(previousLog);
    const lock = try staleLock(allocator);
    const undeletableAnswers = [_]ICannedAnswer{
        .{
            .method = .PUT,
            .status = .precondition_failed,
            .body = "",
            .headers = &.{},
        },
        .{
            .method = .GET,
            .status = .ok,
            .body = lock,
            .headers = &.{},
        },
        .{
            .method = .DELETE,
            .status = .forbidden,
            .body = "<Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>",
            .headers = &.{},
        },
    };
    var undeletableServer: CannedServer = undefined;
    try undeletableServer.startWithAnswers(io, &undeletableAnswers);
    defer undeletableServer.stop();
    var undeletableStorage = try storageOf(&undeletableServer, allocator, io);
    defer undeletableStorage.s3.deinit();
    const unwritableAnswers = [_]ICannedAnswer{
        .{
            .method = .PUT,
            .status = .precondition_failed,
            .body = "",
            .headers = &.{},
        },
        .{
            .method = .GET,
            .status = .ok,
            .body = lock,
            .headers = &.{},
        },
        .{
            .method = .DELETE,
            .status = .no_content,
            .body = "",
            .headers = &.{},
        },
    };
    var unwritableServer: CannedServer = undefined;
    try unwritableServer.startWithAnswers(io, &unwritableAnswers);
    defer unwritableServer.stop();
    var unwritableStorage = try storageOf(&unwritableServer, allocator, io);
    defer unwritableStorage.s3.deinit();

    try std.testing.expect(!try undeletableStorage.acquireWriteLock(allocator, io, "bucket/dir/file.lock", "owner"));
    try std.testing.expect(recordingLog.logged(",ACQUIRE_TIMEOUT_BREAK,"));
    try std.testing.expect(recordingLog.logged(",ACQUIRE_FAILED_RETRY,"));
    try std.testing.expectEqualStrings("/bucket/dir/file.lock", try undeletableServer.lastTarget(allocator));

    recordingLog.lines.clearRetainingCapacity();
    try std.testing.expect(!try unwritableStorage.acquireWriteLock(allocator, io, "bucket/dir/file.lock", "owner"));
    try std.testing.expect(recordingLog.logged(",ACQUIRE_FAILED_RETRY,"));
    try std.testing.expect(!recordingLog.logged(",ACQUIRE_SUCCESS_AFTER_TIMEOUT,"));
}
