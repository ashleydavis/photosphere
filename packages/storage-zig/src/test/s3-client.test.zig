const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");
const helpers = @import("test-helpers.zig");
const mock = @import("mock-s3-server.zig");
const MockS3Server = mock.MockS3Server;

const s3_client = storage_zig.s3_client;
const S3Client = s3_client.S3Client;
const Upload = s3_client.Upload;

test "resolveEndpoint builds the AWS endpoint for the region and parses custom endpoints" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const aws = try s3_client.resolveEndpoint(allocator, null, "ap-southeast-2");
    try std.testing.expectEqualStrings("https", aws.scheme);
    try std.testing.expectEqualStrings("s3.ap-southeast-2.amazonaws.com", aws.hostname);
    try std.testing.expect(aws.port == null);

    const custom = try s3_client.resolveEndpoint(allocator, "http://127.0.0.1:9000/base/", "us-east-1");
    try std.testing.expectEqualStrings("http", custom.scheme);
    try std.testing.expectEqualStrings("127.0.0.1", custom.hostname);
    try std.testing.expectEqual(@as(?u16, 9000), custom.port);
    try std.testing.expectEqualStrings("/base", custom.basePath);

    try std.testing.expectError(error.Thrown, s3_client.resolveEndpoint(allocator, "not a url", "us-east-1"));
    try std.testing.expectEqualStrings("Invalid endpoint: not a url", utils.errors.lastErrorMessage());
}

test "resolveRequestLocation uses virtual-hosted-style requests unless the host is an IP address or the bucket is not a host label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const spaces = try s3_client.resolveEndpoint(allocator, "https://nyc3.digitaloceanspaces.com", "us-east-1");
    const virtualHosted = try s3_client.resolveRequestLocation(allocator, spaces, "my-bucket", "db/asset/a b+c");
    try std.testing.expectEqualStrings("my-bucket.nyc3.digitaloceanspaces.com", virtualHosted.host);
    try std.testing.expectEqualStrings("/db/asset/a%20b%2Bc", virtualHosted.path);
    const bucketRequest = try s3_client.resolveRequestLocation(allocator, spaces, "my-bucket", null);
    try std.testing.expectEqualStrings("/", bucketRequest.path);

    const dotted = try s3_client.resolveRequestLocation(allocator, spaces, "my.bucket", "key");
    try std.testing.expectEqualStrings("nyc3.digitaloceanspaces.com", dotted.host);
    try std.testing.expectEqualStrings("/my.bucket/key", dotted.path);

    const local = try s3_client.resolveEndpoint(allocator, "http://127.0.0.1:9000", "us-east-1");
    const pathStyle = try s3_client.resolveRequestLocation(allocator, local, "my-bucket", "key");
    try std.testing.expectEqualStrings("127.0.0.1:9000", pathStyle.host);
    try std.testing.expectEqualStrings("/my-bucket/key", pathStyle.path);
    const pathStyleBucket = try s3_client.resolveRequestLocation(allocator, local, "my-bucket", null);
    try std.testing.expectEqualStrings("/my-bucket", pathStyleBucket.path);

    const aws = try s3_client.resolveEndpoint(allocator, null, "us-east-1");
    const awsLocation = try s3_client.resolveRequestLocation(allocator, aws, "photos", "a/b");
    try std.testing.expectEqualStrings("photos.s3.us-east-1.amazonaws.com", awsLocation.host);
    try std.testing.expectEqualStrings("/a/b", awsLocation.path);
}

test "isVirtualHostableBucket follows the S3 bucket naming rules" {
    try std.testing.expect(s3_client.isVirtualHostableBucket("my-bucket", false));
    try std.testing.expect(!s3_client.isVirtualHostableBucket("my.bucket", false));
    try std.testing.expect(s3_client.isVirtualHostableBucket("my.bucket", true));
    try std.testing.expect(!s3_client.isVirtualHostableBucket("My-Bucket", false));
    try std.testing.expect(!s3_client.isVirtualHostableBucket("ab", false));
    try std.testing.expect(!s3_client.isVirtualHostableBucket("-bucket", false));
    try std.testing.expect(!s3_client.isVirtualHostableBucket("192.168.1.1", true));
}

test "parseHttpDate parses RFC 7231 dates" {
    try std.testing.expectEqual(@as(?i64, mock.LAST_MODIFIED_MS), s3_client.parseHttpDate(mock.LAST_MODIFIED_TEXT));
    try std.testing.expectEqual(@as(?i64, 0), s3_client.parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 1709251199000), s3_client.parseHttpDate("Thu, 29 Feb 2024 23:59:59 GMT"));
    try std.testing.expect(s3_client.parseHttpDate("garbage") == null);
}

test "xml helpers extract, decode and encode text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const xml = "<R><Contents><Key>a&amp;b</Key></Contents><Contents><Key>&lt;c&gt; &#233;&#x41;</Key></Contents></R>";
    const elements = try s3_client.xmlElements(allocator, xml, "Contents");
    try std.testing.expectEqual(@as(usize, 2), elements.len);
    try std.testing.expectEqualStrings("a&b", (try s3_client.xmlText(allocator, elements[0], "Key")).?);
    try std.testing.expectEqualStrings("<c> \xc3\xa9A", (try s3_client.xmlText(allocator, elements[1], "Key")).?);
    try std.testing.expect((try s3_client.xmlText(allocator, xml, "Missing")) == null);
    try std.testing.expectEqualStrings("a&amp;&lt;b&gt;&quot;&apos;", try s3_client.xmlEncode(allocator, "a&<b>\"'"));
}

test "a request without a region fails with the SDK message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var client = S3Client.init(std.testing.io, .{
        .endpoint = "http://127.0.0.1:1",
        .region = null,
        .credentials = .{ .accessKeyId = "id", .secretAccessKey = "secret", .sessionToken = null },
    });
    defer client.deinit();
    try std.testing.expectError(error.Thrown, client.headObject(arena.allocator(), std.testing.io, "bucket", "key"));
    try std.testing.expectEqualStrings("Region is missing", utils.errors.lastErrorMessage());
}

test "a request without credentials fails with the SDK message" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var client = S3Client.init(std.testing.io, .{
        .endpoint = "http://127.0.0.1:1",
        .region = "us-east-1",
        .credentials = null,
    });
    defer client.deinit();
    try std.testing.expectError(error.Thrown, client.headObject(arena.allocator(), std.testing.io, "bucket", "key"));
    try std.testing.expectEqualStrings("Could not load credentials from any providers", utils.errors.lastErrorMessage());
    try std.testing.expectEqualStrings("CredentialsProviderError", utils.errors.lastErrorName());
}

//
// A mock server and a client connected to it.
//
const Fixture = struct {
    // The arena for the test.
    arena: std.heap.ArenaAllocator,

    // The mock server.
    server: *MockS3Server,

    // The client.
    client: S3Client,

    //
    // Starts the server and creates the client.
    //
    fn init(fixture: *Fixture) !void {
        fixture.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        fixture.server = try MockS3Server.start(std.testing.io);
        fixture.client = S3Client.init(std.testing.io, .{
            .endpoint = try fixture.server.endpoint(fixture.arena.allocator()),
            .region = mock.REGION,
            .credentials = .{ .accessKeyId = mock.ACCESS_KEY_ID, .secretAccessKey = mock.SECRET_ACCESS_KEY, .sessionToken = null },
        });
    }

    //
    // Stops everything.
    //
    fn deinit(fixture: *Fixture) void {
        fixture.client.deinit();
        fixture.server.stop();
        fixture.arena.deinit();
    }
};

test "S3 errors are thrown with the S3 code as the name and the HTTP status" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    try std.testing.expectError(error.Thrown, fixture.client.getObject(allocator, std.testing.io, "bucket", "missing", null));
    try std.testing.expectEqualStrings("NoSuchKey", utils.errors.lastErrorName());
    try std.testing.expectEqualStrings("The specified key does not exist.", utils.errors.lastErrorMessage());
    try std.testing.expectEqual(@as(u16, 404), s3_client.lastHttpStatusCode());

    try std.testing.expectError(error.Thrown, fixture.client.headObject(allocator, std.testing.io, "bucket", "missing"));
    try std.testing.expectEqualStrings("NotFound", utils.errors.lastErrorName());
    try std.testing.expectEqual(@as(u16, 404), s3_client.lastHttpStatusCode());
}

test "Upload uses a single PutObject when the body fits in one part" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var upload = Upload.init(.{
        .client = &fixture.client,
        .params = .{ .Bucket = "bucket", .Key = "small", .Body = .{ .buffer = "12345" }, .ContentType = "text/plain", .ContentLength = 5 },
        .partSize = 10,
        .queueSize = 1,
    });
    try upload.done(allocator, std.testing.io);
    try std.testing.expectEqualStrings("12345", (try fixture.server.getObject(allocator, "bucket/small")).?);
    try std.testing.expectEqual(@as(usize, 0), fixture.server.countRequests("POST"));

    var exact = std.Io.Reader.fixed("0123456789");
    var exactUpload = Upload.init(.{
        .client = &fixture.client,
        .params = .{ .Bucket = "bucket", .Key = "exact", .Body = .{ .stream = &exact }, .ContentType = null, .ContentLength = null },
        .partSize = 10,
        .queueSize = 1,
    });
    try exactUpload.done(allocator, std.testing.io);
    try std.testing.expectEqualStrings("0123456789", (try fixture.server.getObject(allocator, "bucket/exact")).?);
    try std.testing.expectEqual(@as(usize, 0), fixture.server.countRequests("POST"));
}

test "Upload uses a multipart upload for a stream larger than one part" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const data = try helpers.makeData(allocator, 25);
    var input = std.Io.Reader.fixed(data);
    var upload = Upload.init(.{
        .client = &fixture.client,
        .params = .{ .Bucket = "bucket", .Key = "big", .Body = .{ .stream = &input }, .ContentType = "video/mp4", .ContentLength = null },
        .partSize = 10,
        .queueSize = 1,
    });
    try upload.done(allocator, std.testing.io);
    try std.testing.expectEqualSlices(u8, data, (try fixture.server.getObject(allocator, "bucket/big")).?);
    try std.testing.expectEqualStrings("video/mp4", fixture.server.getContentType("bucket/big").?);
    try std.testing.expectEqual(@as(usize, 1), fixture.server.countRequests("POST /bucket/big?uploads"));
    try std.testing.expectEqual(@as(usize, 3), fixture.server.countRequests("PUT /bucket/big?partNumber"));
    try std.testing.expectEqual(@as(usize, 1), fixture.server.countRequests("POST /bucket/big?uploadId"));

    var bufferUpload = Upload.init(.{
        .client = &fixture.client,
        .params = .{ .Bucket = "bucket", .Key = "big-buffer", .Body = .{ .buffer = data }, .ContentType = null, .ContentLength = data.len },
        .partSize = 10,
        .queueSize = 1,
    });
    try bufferUpload.done(allocator, std.testing.io);
    try std.testing.expectEqualSlices(u8, data, (try fixture.server.getObject(allocator, "bucket/big-buffer")).?);
    try std.testing.expectEqual(@as(u32, 0), fixture.server.signatureFailures);
}
