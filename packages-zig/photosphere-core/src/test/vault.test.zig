const std = @import("std");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

test "vault-set then vault-get returns the secret" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const set_reply = try app.requestOk("vault-set", "{\"name\":\"vault-test-roundtrip\",\"type\":\"api-key\",\"value\":\"s3cret\"}");
    defer allocator.free(set_reply);
    try std.testing.expectEqualStrings("null", set_reply);
    const get_reply = try app.requestOk("vault-get", "\"vault-test-roundtrip\"");
    defer allocator.free(get_reply);
    try std.testing.expectEqualStrings("{\"name\":\"vault-test-roundtrip\",\"type\":\"api-key\",\"value\":\"s3cret\"}", get_reply);
}

test "vault-get replies null for a name that is not in the vault" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestOk("vault-get", "\"vault-test-no-such-secret\"");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
}

test "vault-set overwrites a secret of the same name" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"vault-test-overwrite\",\"type\":\"api-key\",\"value\":\"first\"}"));
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"vault-test-overwrite\",\"type\":\"password\",\"value\":\"second\"}"));
    const reply = try app.requestOk("vault-get", "\"vault-test-overwrite\"");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("{\"name\":\"vault-test-overwrite\",\"type\":\"password\",\"value\":\"second\"}", reply);
}

test "vault-delete removes a secret, and a name that is not there is not an error" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"vault-test-delete\",\"type\":\"api-key\",\"value\":\"x\"}"));
    const deleted = try app.requestOk("vault-delete", "\"vault-test-delete\"");
    defer allocator.free(deleted);
    try std.testing.expectEqualStrings("null", deleted);
    const gone = try app.requestOk("vault-get", "\"vault-test-delete\"");
    defer allocator.free(gone);
    try std.testing.expectEqualStrings("null", gone);
    allocator.free(try app.requestOk("vault-delete", "\"vault-test-delete\""));
}

test "vault-list includes every secret that was set" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"vault-test-list-a\",\"type\":\"api-key\",\"value\":\"a\"}"));
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"vault-test-list-b\",\"type\":\"password\",\"value\":\"b\"}"));
    const reply = try app.requestOk("vault-list", "null");
    defer allocator.free(reply);
    try std.testing.expect(std.mem.indexOf(u8, reply, "{\"name\":\"vault-test-list-a\",\"type\":\"api-key\",\"value\":\"a\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, reply, "{\"name\":\"vault-test-list-b\",\"type\":\"password\",\"value\":\"b\"}") != null);
}

test "vault-set without a value is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("vault-set", "{\"name\":\"vault-test-no-value\",\"type\":\"api-key\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: the field \"value\" is missing", reply);
}

test "vault-get without a name is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("vault-get", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: UnexpectedToken", reply);
}

test "vault-set without a name is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("vault-set", "{\"type\":\"api-key\",\"value\":\"v\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: the field \"name\" is missing", reply);
}

test "vault-set without a type is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("vault-set", "{\"name\":\"vault-test-no-type\",\"value\":\"v\"}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: the field \"type\" is missing", reply);
}

test "vault-delete without a name is an error reply" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("vault-delete", "null");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("InvalidMessageData: UnexpectedToken", reply);
}

test "a failing vault request logs the error with the message of its handler" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    try app.queueFailingTask("vault-get", "null");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error getting vault secret") != null);
    try app.queueFailingTask("vault-set", "{\"name\":\"vault-test-log\",\"type\":\"api-key\"}");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error setting vault secret") != null);
    try app.queueFailingTask("vault-delete", "null");
    try std.testing.expect(std.mem.indexOf(u8, (try app.consoleErr()), "Error deleting vault secret") != null);
}

test "a vault request that succeeds logs nothing to the error output" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"vault-test-quiet\",\"type\":\"api-key\",\"value\":\"x\"}"));
    allocator.free(try app.requestOk("vault-list", "null"));
    try std.testing.expectEqual(@as(usize, 0), (try app.consoleErr()).len);
}
