//
// Tests for the aws-c-s3 binding (src/lib/s3-client.zig), which has no TypeScript counterpart.
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const aws = @import("aws-c");

const canResendOnClosedConnection = storage_zig.s3_client.canResendOnClosedConnection;

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
