//
// Tests for endpointFromEnvironment.
//

const std = @import("std");
const storage_zig = @import("storage-zig");
const endpointFromEnvironment = storage_zig.cloud_storage.endpointFromEnvironment;

//
// Makes an environment holding only the variables given, to stand in for the process environment.
//
fn environmentOf(allocator: std.mem.Allocator, variables: []const [2][]const u8) !std.process.Environ.Map {
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();
    for (variables) |variable| {
        try map.put(variable[0], variable[1]);
    }
    return map;
}

test "endpointFromEnvironment returns null when neither variable is set" {
    var environment = try environmentOf(std.testing.allocator, &.{});
    defer environment.deinit();

    try std.testing.expect(endpointFromEnvironment(&environment) == null);
}

test "endpointFromEnvironment returns null when there is no environment" {
    try std.testing.expect(endpointFromEnvironment(null) == null);
}

test "endpointFromEnvironment returns AWS_ENDPOINT_URL when only that is set" {
    var environment = try environmentOf(std.testing.allocator, &.{
        .{ "AWS_ENDPOINT_URL", "http://127.0.0.1:9000" },
    });
    defer environment.deinit();

    try std.testing.expectEqualStrings("http://127.0.0.1:9000", endpointFromEnvironment(&environment).?);
}

test "endpointFromEnvironment returns AWS_ENDPOINT_URL_S3 when only that is set" {
    var environment = try environmentOf(std.testing.allocator, &.{
        .{ "AWS_ENDPOINT_URL_S3", "http://127.0.0.1:9001" },
    });
    defer environment.deinit();

    try std.testing.expectEqualStrings("http://127.0.0.1:9001", endpointFromEnvironment(&environment).?);
}

test "endpointFromEnvironment prefers AWS_ENDPOINT_URL_S3 over AWS_ENDPOINT_URL when both are set" {
    var environment = try environmentOf(std.testing.allocator, &.{
        .{ "AWS_ENDPOINT_URL", "http://127.0.0.1:9000" },
        .{ "AWS_ENDPOINT_URL_S3", "http://127.0.0.1:9001" },
    });
    defer environment.deinit();

    try std.testing.expectEqualStrings("http://127.0.0.1:9001", endpointFromEnvironment(&environment).?);
}

test "endpointFromEnvironment treats an empty AWS_ENDPOINT_URL as not set" {
    var environment = try environmentOf(std.testing.allocator, &.{
        .{ "AWS_ENDPOINT_URL", "" },
    });
    defer environment.deinit();

    try std.testing.expect(endpointFromEnvironment(&environment) == null);
}

test "endpointFromEnvironment treats an empty AWS_ENDPOINT_URL_S3 as not set and falls through to AWS_ENDPOINT_URL" {
    var environment = try environmentOf(std.testing.allocator, &.{
        .{ "AWS_ENDPOINT_URL", "http://127.0.0.1:9000" },
        .{ "AWS_ENDPOINT_URL_S3", "" },
    });
    defer environment.deinit();

    try std.testing.expectEqualStrings("http://127.0.0.1:9000", endpointFromEnvironment(&environment).?);
}

test "endpointFromEnvironment ignores AWS_ENDPOINT, which is no longer read" {
    var environment = try environmentOf(std.testing.allocator, &.{
        .{ "AWS_ENDPOINT", "http://127.0.0.1:9000" },
    });
    defer environment.deinit();

    try std.testing.expect(endpointFromEnvironment(&environment) == null);
}
