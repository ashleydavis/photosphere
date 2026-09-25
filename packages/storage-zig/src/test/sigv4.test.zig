const std = @import("std");
const storage_zig = @import("storage-zig");

const sigv4 = storage_zig.sigv4;

//
// The credentials of the AWS SigV4 test suite (aws-sig-v4-test-suite).
//
const suite_credentials: sigv4.ICredentials = .{
    .accessKeyId = "AKIDEXAMPLE",
    .secretAccessKey = "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    .sessionToken = null,
};

//
// The credentials of the examples in the Amazon S3 SigV4 documentation.
//
const s3_documentation_credentials: sigv4.ICredentials = .{
    .accessKeyId = "AKIAIOSFODNN7EXAMPLE",
    .secretAccessKey = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
    .sessionToken = null,
};

test "deriveSigningKey matches the AWS documentation example" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const signingKey = try sigv4.deriveSigningKey(arena.allocator(), "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", "20120215", "us-east-1", "iam");
    try std.testing.expectEqualStrings("f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d", &std.fmt.bytesToHex(signingKey, .lower));
}

test "aws-sig-v4-test-suite get-vanilla" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const signature = try sigv4.sign(arena.allocator(), suite_credentials, .{
        .method = "GET",
        .canonicalUri = "/",
        .query = &.{},
        .headers = &.{
            .{ .name = "Host", .value = "example.amazonaws.com" },
            .{ .name = "X-Amz-Date", .value = "20150830T123600Z" },
        },
        .payloadHash = sigv4.EMPTY_PAYLOAD_HASH,
        .region = "us-east-1",
        .service = "service",
        .amzDate = "20150830T123600Z",
    });
    try std.testing.expectEqualStrings(
        "GET\n/\n\nhost:example.amazonaws.com\nx-amz-date:20150830T123600Z\n\nhost;x-amz-date\ne3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        signature.canonicalRequest,
    );
    try std.testing.expectEqualStrings(
        "AWS4-HMAC-SHA256\n20150830T123600Z\n20150830/us-east-1/service/aws4_request\nbb579772317eb040ac9ed261061d46c1f17a8133879d6129b6e1c25292927e63",
        signature.stringToSign,
    );
    try std.testing.expectEqualStrings("5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31", signature.signature);
    try std.testing.expectEqualStrings(
        "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31",
        signature.authorization,
    );
}

test "aws-sig-v4-test-suite get-vanilla-query-order-key-case" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const signature = try sigv4.sign(arena.allocator(), suite_credentials, .{
        .method = "GET",
        .canonicalUri = "/",
        .query = &.{
            .{ .name = "Param2", .value = "value2" },
            .{ .name = "Param1", .value = "value1" },
        },
        .headers = &.{
            .{ .name = "Host", .value = "example.amazonaws.com" },
            .{ .name = "X-Amz-Date", .value = "20150830T123600Z" },
        },
        .payloadHash = sigv4.EMPTY_PAYLOAD_HASH,
        .region = "us-east-1",
        .service = "service",
        .amzDate = "20150830T123600Z",
    });
    try std.testing.expectEqualStrings("b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500", signature.signature);
}

test "S3 documentation example: GET object with a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const signature = try sigv4.sign(arena.allocator(), s3_documentation_credentials, .{
        .method = "GET",
        .canonicalUri = "/test.txt",
        .query = &.{},
        .headers = &.{
            .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
            .{ .name = "Range", .value = "bytes=0-9" },
            .{ .name = "x-amz-content-sha256", .value = sigv4.EMPTY_PAYLOAD_HASH },
            .{ .name = "x-amz-date", .value = "20130524T000000Z" },
        },
        .payloadHash = sigv4.EMPTY_PAYLOAD_HASH,
        .region = "us-east-1",
        .service = "s3",
        .amzDate = "20130524T000000Z",
    });
    try std.testing.expectEqualStrings("7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972", &sigv4.sha256Hex(signature.canonicalRequest));
    try std.testing.expectEqualStrings("host;range;x-amz-content-sha256;x-amz-date", signature.signedHeaders);
    try std.testing.expectEqualStrings("f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41", signature.signature);
}

test "S3 documentation example: PUT object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const payloadHash = sigv4.sha256Hex("Welcome to Amazon S3.");
    try std.testing.expectEqualStrings("44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072", &payloadHash);
    const signature = try sigv4.sign(allocator, s3_documentation_credentials, .{
        .method = "PUT",
        .canonicalUri = try sigv4.uriEncode(allocator, "/test$file.text", false),
        .query = &.{},
        .headers = &.{
            .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
            .{ .name = "Date", .value = "Fri, 24 May 2013 00:00:00 GMT" },
            .{ .name = "x-amz-date", .value = "20130524T000000Z" },
            .{ .name = "x-amz-storage-class", .value = "REDUCED_REDUNDANCY" },
            .{ .name = "x-amz-content-sha256", .value = &payloadHash },
        },
        .payloadHash = &payloadHash,
        .region = "us-east-1",
        .service = "s3",
        .amzDate = "20130524T000000Z",
    });
    try std.testing.expectEqualStrings("98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd", signature.signature);
}

test "S3 documentation example: GET bucket lifecycle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const signature = try sigv4.sign(arena.allocator(), s3_documentation_credentials, .{
        .method = "GET",
        .canonicalUri = "/",
        .query = &.{.{ .name = "lifecycle", .value = "" }},
        .headers = &.{
            .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
            .{ .name = "x-amz-date", .value = "20130524T000000Z" },
            .{ .name = "x-amz-content-sha256", .value = sigv4.EMPTY_PAYLOAD_HASH },
        },
        .payloadHash = sigv4.EMPTY_PAYLOAD_HASH,
        .region = "us-east-1",
        .service = "s3",
        .amzDate = "20130524T000000Z",
    });
    try std.testing.expectEqualStrings("fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543", signature.signature);
}

test "S3 documentation example: GET bucket (list objects)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const signature = try sigv4.sign(arena.allocator(), s3_documentation_credentials, .{
        .method = "GET",
        .canonicalUri = "/",
        .query = &.{
            .{ .name = "max-keys", .value = "2" },
            .{ .name = "prefix", .value = "J" },
        },
        .headers = &.{
            .{ .name = "Host", .value = "examplebucket.s3.amazonaws.com" },
            .{ .name = "x-amz-date", .value = "20130524T000000Z" },
            .{ .name = "x-amz-content-sha256", .value = sigv4.EMPTY_PAYLOAD_HASH },
        },
        .payloadHash = sigv4.EMPTY_PAYLOAD_HASH,
        .region = "us-east-1",
        .service = "s3",
        .amzDate = "20130524T000000Z",
    });
    try std.testing.expectEqualStrings("34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7", signature.signature);
}

test "uriEncode encodes everything but unreserved characters, keeping slashes on request" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("a-b_c.d~e%20f%2Bg%2Fh", try sigv4.uriEncode(allocator, "a-b_c.d~e f+g/h", true));
    try std.testing.expectEqualStrings("dir/sub%20dir/%C3%A9.txt", try sigv4.uriEncode(allocator, "dir/sub dir/\xc3\xa9.txt", false));
}

test "canonicalQueryString sorts by encoded name and value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const query = try sigv4.canonicalQueryString(arena.allocator(), &.{
        .{ .name = "prefix", .value = "a b/" },
        .{ .name = "delimiter", .value = "/" },
        .{ .name = "list-type", .value = "2" },
    });
    try std.testing.expectEqualStrings("delimiter=%2F&list-type=2&prefix=a%20b%2F", query);
}

test "formatAmzDate formats milliseconds since the epoch" {
    try std.testing.expectEqualStrings("20130524T000000Z", &sigv4.formatAmzDate(1369353600000));
    try std.testing.expectEqualStrings("20150830T123600Z", &sigv4.formatAmzDate(1440938160123));
    try std.testing.expectEqualStrings("19700101T000000Z", &sigv4.formatAmzDate(0));
}
