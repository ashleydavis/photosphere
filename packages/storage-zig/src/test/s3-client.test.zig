const std = @import("std");
const storage_zig = @import("storage-zig");
const utils = @import("utils-zig");
const aws = @import("aws-c");
const helpers = @import("test-helpers.zig");
const mock = @import("mock-s3-server.zig");
const MockS3Server = mock.MockS3Server;

const s3_client = storage_zig.s3_client;
const S3Client = s3_client.S3Client;
const Upload = s3_client.Upload;

//
// Credentials for the clients of the tests that make no request to a server.
//
const test_credentials: s3_client.ICredentials = .{
    .accessKeyId = "id",
    .secretAccessKey = "secret",
    .sessionToken = null,
};

test "resolveEndpoint applies the S3 endpoint rules: virtual-hosted-style unless the host is an IP address or the bucket is not a host label" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var awsClient = S3Client.init(std.testing.io, .{
        .endpoint = null,
        .region = "ap-southeast-2",
        .credentials = test_credentials,
    });
    defer awsClient.deinit();
    try std.testing.expectEqualStrings("https://photos.s3.ap-southeast-2.amazonaws.com", try awsClient.resolveEndpoint(allocator, "photos"));

    var spaces = S3Client.init(std.testing.io, .{
        .endpoint = "https://nyc3.digitaloceanspaces.com",
        .region = "us-east-1",
        .credentials = test_credentials,
    });
    defer spaces.deinit();
    try std.testing.expectEqualStrings("https://my-bucket.nyc3.digitaloceanspaces.com", try spaces.resolveEndpoint(allocator, "my-bucket"));
    try std.testing.expectEqualStrings("https://nyc3.digitaloceanspaces.com/my.bucket", try spaces.resolveEndpoint(allocator, "my.bucket"));

    var local = S3Client.init(std.testing.io, .{
        .endpoint = "http://127.0.0.1:9000",
        .region = "us-east-1",
        .credentials = test_credentials,
    });
    defer local.deinit();
    try std.testing.expectEqualStrings("http://127.0.0.1:9000/my-bucket", try local.resolveEndpoint(allocator, "my-bucket"));
}

test "resolveEndpoint throws the endpoint rules' error for an endpoint that is not a URL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var client = S3Client.init(std.testing.io, .{
        .endpoint = "not a url",
        .region = "us-east-1",
        .credentials = test_credentials,
    });
    defer client.deinit();
    try std.testing.expectError(error.Thrown, client.resolveEndpoint(arena.allocator(), "bucket"));
    try std.testing.expectEqualStrings("Custom endpoint `not a url` was not a valid URI", utils.errors.lastErrorMessage());
}

test "parseHttpDate parses RFC 7231 dates" {
    try std.testing.expectEqual(@as(?i64, mock.LAST_MODIFIED_MS), s3_client.parseHttpDate(mock.LAST_MODIFIED_TEXT));
    try std.testing.expectEqual(@as(?i64, 0), s3_client.parseHttpDate("Thu, 01 Jan 1970 00:00:00 GMT"));
    try std.testing.expectEqual(@as(?i64, 1709251199000), s3_client.parseHttpDate("Thu, 29 Feb 2024 23:59:59 GMT"));
    try std.testing.expect(s3_client.parseHttpDate("garbage") == null);
}

test "parseListObjectsV2 reads the keys, common prefixes and continuation of a listing with the XML escapes removed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<ListBucketResult><Name>b</Name><IsTruncated>true</IsTruncated><Contents><Key>a&amp;b</Key><Size>1</Size></Contents><Contents><Key>&lt;c&gt; &quot;d&quot;</Key></Contents><CommonPrefixes><Prefix>dir/</Prefix></CommonPrefixes><NextContinuationToken>next&amp;token</NextContinuationToken></ListBucketResult>";
    const output = try s3_client.parseListObjectsV2(allocator, xml);
    try std.testing.expectEqual(@as(usize, 2), output.Contents.?.len);
    try std.testing.expectEqualStrings("a&b", output.Contents.?[0].Key);
    try std.testing.expectEqualStrings("<c> \"d\"", output.Contents.?[1].Key);
    try std.testing.expectEqual(@as(usize, 1), output.CommonPrefixes.?.len);
    try std.testing.expectEqualStrings("dir/", output.CommonPrefixes.?[0].Prefix);
    try std.testing.expectEqualStrings("next&token", output.NextContinuationToken.?);
    try std.testing.expect(output.IsTruncated);

    const empty = try s3_client.parseListObjectsV2(allocator, "<ListBucketResult><IsTruncated>false</IsTruncated></ListBucketResult>");
    try std.testing.expect(empty.Contents == null);
    try std.testing.expect(empty.CommonPrefixes == null);
    try std.testing.expect(empty.NextContinuationToken == null);
    try std.testing.expect(!empty.IsTruncated);

    try std.testing.expectError(error.Thrown, s3_client.parseListObjectsV2(allocator, "not xml"));
}

test "appendXmlEscaped escapes the five XML special characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var output: std.ArrayList(u8) = .empty;
    try s3_client.appendXmlEscaped(arena.allocator(), &output, "a&<b>\"'c");
    try std.testing.expectEqualStrings("a&amp;&lt;b&gt;&quot;&apos;c", output.items);
}

test "contentMd5 is the base64 MD5 of the body" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // RFC 1321 test suite: MD5("abc") = 900150983cd24fb0d6963f7d28e17f72.
    try std.testing.expectEqualStrings("kAFQmDzST7DWlj99KOF/cg==", try s3_client.contentMd5(arena.allocator(), "abc"));
    try std.testing.expectEqualStrings("1B2M2Y8AsgTpgAmY7PhCfg==", try s3_client.contentMd5(arena.allocator(), ""));
}

test "staticErrorName and errorNameForStatus name errors like the SDK" {
    try std.testing.expectEqualStrings("NoSuchKey", s3_client.staticErrorName("NoSuchKey"));
    try std.testing.expectEqualStrings("S3ServiceException", s3_client.staticErrorName("SomethingNew"));
    try std.testing.expectEqualStrings("NotFound", s3_client.errorNameForStatus(404));
    try std.testing.expectEqualStrings("Forbidden", s3_client.errorNameForStatus(403));
    try std.testing.expectEqualStrings("BadRequest", s3_client.errorNameForStatus(400));
    try std.testing.expectEqualStrings("PreconditionFailed", s3_client.errorNameForStatus(412));
    try std.testing.expectEqualStrings("UnknownError", s3_client.errorNameForStatus(500));
}

test "SigningConfigAws has the layout of the SDK's struct aws_signing_config_aws" {
    const provider = aws.aws_credentials_provider_new_anonymous(aws.aws_default_allocator(), null).?;
    defer _ = aws.aws_credentials_provider_release(provider);
    var config = std.mem.zeroes(s3_client.SigningConfigAws);
    // The SDK fills the struct through its own definition; reading it back through ours must give the same values.
    aws.aws_s3_init_default_signing_config(@ptrCast(&config), s3_client.cursorOf("eu-west-1"), provider);
    try std.testing.expectEqual(@as(aws.enum_aws_signing_config_type, aws.AWS_SIGNING_CONFIG_AWS), config.config_type);
    try std.testing.expectEqual(@as(aws.enum_aws_signing_algorithm, aws.AWS_SIGNING_ALGORITHM_V4), config.algorithm);
    try std.testing.expectEqual(@as(aws.enum_aws_signature_type, aws.AWS_ST_HTTP_REQUEST_HEADERS), config.signature_type);
    try std.testing.expectEqualStrings("eu-west-1", s3_client.sliceOf(config.region));
    try std.testing.expectEqualStrings("s3", s3_client.sliceOf(config.service));
    try std.testing.expectEqual(@as(u1, 0), config.flags.use_double_uri_encode);
    try std.testing.expectEqual(@as(u1, 0), config.flags.should_normalize_uri_path);
    try std.testing.expectEqual(@as(aws.enum_aws_signed_body_header_type, aws.AWS_SBHT_X_AMZ_CONTENT_SHA256), config.signed_body_header);
    try std.testing.expect(config.credentials_provider == provider);
    try std.testing.expectEqual(@as(c_int, aws.AWS_OP_SUCCESS), aws.aws_validate_aws_signing_config_aws(config.sdk()));
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

//
// The part size of the upload tests: 5 MiB, the smallest part S3 accepts (lib-storage and aws-c-s3 both refuse or
// raise a smaller one), which is also the part size CloudStorage uses.
//
const part_size = 5 * 1024 * 1024;

test "Upload uses a single PutObject when the body fits in one part" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    var upload = Upload.init(.{
        .client = &fixture.client,
        .params = .{
            .Bucket = "bucket",
            .Key = "small",
            .Body = .{ .buffer = "12345" },
            .ContentType = "text/plain",
            .ContentLength = 5,
        },
        .partSize = part_size,
        .queueSize = 1,
    });
    try upload.done(allocator, std.testing.io);
    try std.testing.expectEqualStrings("12345", (try fixture.server.getObject(allocator, "bucket/small")).?);
    try std.testing.expectEqualStrings("text/plain", fixture.server.getContentType("bucket/small").?);
    try std.testing.expectEqual(@as(usize, 0), fixture.server.countRequests("POST"));

    const exactData = try helpers.makeData(allocator, part_size);
    var exact = std.Io.Reader.fixed(exactData);
    var exactUpload = Upload.init(.{
        .client = &fixture.client,
        .params = .{
            .Bucket = "bucket",
            .Key = "exact",
            .Body = .{ .stream = &exact },
            .ContentType = null,
            .ContentLength = null,
        },
        .partSize = part_size,
        .queueSize = 1,
    });
    try exactUpload.done(allocator, std.testing.io);
    try std.testing.expectEqualSlices(u8, exactData, (try fixture.server.getObject(allocator, "bucket/exact")).?);
    try std.testing.expectEqual(@as(usize, 0), fixture.server.countRequests("POST"));
    try std.testing.expectEqual(@as(usize, 2), fixture.server.countRequests("PUT"));
}

test "Upload uses a multipart upload for a stream larger than one part" {
    var fixture: Fixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const allocator = fixture.arena.allocator();
    const data = try helpers.makeData(allocator, 2 * part_size + 3);
    var input = std.Io.Reader.fixed(data);
    var upload = Upload.init(.{
        .client = &fixture.client,
        .params = .{
            .Bucket = "bucket",
            .Key = "big",
            .Body = .{ .stream = &input },
            .ContentType = "video/mp4",
            .ContentLength = null,
        },
        .partSize = part_size,
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
        .params = .{
            .Bucket = "bucket",
            .Key = "big-buffer",
            .Body = .{ .buffer = data },
            .ContentType = null,
            .ContentLength = data.len,
        },
        .partSize = part_size,
        .queueSize = 1,
    });
    try bufferUpload.done(allocator, std.testing.io);
    try std.testing.expectEqualSlices(u8, data, (try fixture.server.getObject(allocator, "bucket/big-buffer")).?);
    try std.testing.expectEqual(@as(usize, 3), fixture.server.countRequests("PUT /bucket/big-buffer?partNumber"));
    try std.testing.expectEqual(@as(u32, 0), fixture.server.signatureFailures);
    // queueSize 1: the parts are sent one at a time.
    try std.testing.expectEqual(@as(u32, 1), fixture.server.maxRequestsInFlight);
}
