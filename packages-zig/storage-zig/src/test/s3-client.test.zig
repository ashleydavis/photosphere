//
// Tests for the aws-c-s3 binding (src/lib/s3-client.zig), which has no TypeScript counterpart.
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const aws = @import("aws-c");

const canResendOnClosedConnection = storage_zig.s3_client.canResendOnClosedConnection;
const decodeXmlEntities = storage_zig.s3_client.decodeXmlEntities;

test "a request that could not be written to a closed connection is sent again, whatever its method" {
    try std.testing.expect(canResendOnClosedConnection(aws.AWS_IO_SOCKET_CLOSED, 0, "GET", false));
    try std.testing.expect(canResendOnClosedConnection(aws.AWS_IO_SOCKET_CLOSED, 0, "PUT", false));
}

test "a read whose connection closed before it was answered is sent again" {
    try std.testing.expect(canResendOnClosedConnection(aws.AWS_ERROR_HTTP_CONNECTION_CLOSED, 0, "GET", false));
    try std.testing.expect(canResendOnClosedConnection(aws.AWS_ERROR_HTTP_CONNECTION_CLOSED, 0, "HEAD", false));
}

test "a write whose connection closed before it was answered is not sent again, because the server may have acted on it" {
    try std.testing.expect(!canResendOnClosedConnection(aws.AWS_ERROR_HTTP_CONNECTION_CLOSED, 0, "PUT", false));
    try std.testing.expect(!canResendOnClosedConnection(aws.AWS_ERROR_HTTP_CONNECTION_CLOSED, 0, "DELETE", false));
    try std.testing.expect(!canResendOnClosedConnection(aws.AWS_ERROR_HTTP_CONNECTION_CLOSED, 0, "POST", false));
}

test "a request that got a response is not sent again" {
    try std.testing.expect(!canResendOnClosedConnection(aws.AWS_IO_SOCKET_CLOSED, 412, "GET", false));
    try std.testing.expect(!canResendOnClosedConnection(aws.AWS_ERROR_HTTP_CONNECTION_CLOSED, 500, "GET", false));
}

test "a request with a streamed body is not sent again, because the body cannot be replayed" {
    try std.testing.expect(!canResendOnClosedConnection(aws.AWS_IO_SOCKET_CLOSED, 0, "PUT", true));
}

test "a request that failed for another reason is not sent again" {
    try std.testing.expect(!canResendOnClosedConnection(0, 0, "GET", false));
    try std.testing.expect(!canResendOnClosedConnection(aws.AWS_IO_SOCKET_TIMEOUT, 0, "GET", false));
}


test "decodeXmlEntities decodes the entities the SDK decodes, one entity after another, and leaves the others" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // What the JavaScript SDK made of the same keys (read from a server by the TypeScript CloudStorage).
    try std.testing.expectEqualStrings("1A2B3©4 5&bogus;6&lt;7<8>9\"10'11¢12£13¥14€15®16₹17&#1234567;18😀19\x0020&AMP;", try decodeXmlEntities(allocator, "1&#65;2&#x42;3&copy;4&nbsp;5&bogus;6&amp;lt;7&lt;8&gt;9&quot;10&apos;11&cent;12&pound;13&yen;14&euro;15&reg;16&inr;17&#1234567;18&#x1F600;19&#0;20&AMP;"));
    try std.testing.expectEqualStrings("a\u{FFFD}b&#60;c>e>fAg&#12345678;h&#x0000041;i&#x110000;j k", try decodeXmlEntities(allocator, "a&#xD800;b&#38;#60;c&#x3e;e&#x3E;f&#00065;g&#12345678;h&#x0000041;i&#x110000;j&nbsp;k"));
    try std.testing.expectEqualStrings("'''>><<\"\"&&&", try decodeXmlEntities(allocator, "&apos;&#39;&#x27;&gt;&#62;&lt;&#x3C;&quot;&#34;&amp;&#38;&#x26;"));
    try std.testing.expectEqualStrings("no entities", try decodeXmlEntities(allocator, "no entities"));
    try std.testing.expectEqualStrings("&;&#;&#x;&", try decodeXmlEntities(allocator, "&;&#;&#x;&"));
}

test "parseListObjectsV2 leaves an entity it does not know as it is, like the SDK" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const output = try storage_zig.s3_client.parseListObjectsV2(allocator, "<ListBucketResult><Contents><Key>a&bogus;b&amp;c</Key></Contents><CommonPrefixes><Prefix>p&copy;</Prefix></CommonPrefixes><IsTruncated>true</IsTruncated><NextContinuationToken>t&#65;</NextContinuationToken></ListBucketResult>");
    try std.testing.expectEqualStrings("a&bogus;b&c", output.Contents.?[0].Key);
    try std.testing.expectEqualStrings("p©", output.CommonPrefixes.?[0].Prefix);
    try std.testing.expect(output.IsTruncated);
    try std.testing.expectEqualStrings("tA", output.NextContinuationToken.?);
}

test "appendXmlEscaped escapes the text of an element as the SDK's XML serializer does, line breaks included" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var output: std.ArrayList(u8) = .empty;

    // escapeElement of @aws-sdk/xml-builder writes this for the same text.
    try storage_zig.s3_client.appendXmlEscaped(allocator, &output, "a&b<c>d\"e'f\rg\nh\u{85}i\u{2028}j\u{2029}é");
    try std.testing.expectEqualStrings("a&amp;b&lt;c&gt;d&quot;e&apos;f&#x0D;g&#x0A;h&#x85;i&#x2028;j\u{2029}é", output.items);
}

test "sliceOf gives an empty slice for an empty cursor, whose pointer may be null" {
    try std.testing.expectEqualStrings("", storage_zig.s3_client.sliceOf(.{
        .len = 0,
        .ptr = null,
    }));
}

test "parseHttpDate reads an HTTP date, and gives null for text that is not one" {
    try std.testing.expectEqual(@as(?i64, 1255369800000), storage_zig.s3_client.parseHttpDate("Mon, 12 Oct 2009 17:50:00 GMT"));
    try std.testing.expectEqual(@as(?i64, null), storage_zig.s3_client.parseHttpDate("not a date"));
}
