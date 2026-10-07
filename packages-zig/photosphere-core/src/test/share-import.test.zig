const std = @import("std");
const node_api = @import("node-api-zig");
const support = @import("test-support.zig");

const TestApp = support.TestApp;

fn expectVaultSecret(app: *TestApp, name: []const u8, expected_type: []const u8, expected_value_json: []const u8) !void {
    const allocator = std.testing.allocator;
    const name_json = try std.json.Stringify.valueAlloc(allocator, name, .{});
    defer allocator.free(name_json);
    const reply = try app.requestOk("vault-get", name_json);
    defer allocator.free(reply);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, reply, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(expected_type, parsed.value.object.get("type").?.string);
    try std.testing.expectEqualStrings(expected_value_json, parsed.value.object.get("value").?.string);
}

test "import-share-payload imports a secret under the name the user chose" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const reply = try app.requestOk("import-share-payload", "{\"payload\":{\"type\":\"secret\",\"name\":\"sender's name\",\"secretType\":\"api-key\",\"value\":\"abc123\",\"saveName\":\"share-import-test-secret\"},\"conflictResolutions\":{}}");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try expectVaultSecret(&app, "share-import-test-secret", "api-key", "abc123");
}

test "import-share-payload imports a database: its secrets go to the vault and its entry to the databases list" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    const reply = try app.requestOk("import-share-payload", "{\"payload\":{\"type\":\"database\",\"name\":\"Shared photos\",\"description\":\"from another device\",\"path\":\"fs:/photos/shared\",\"origin\":\"origin-text\",\"geocodingKey\":{\"name\":\"share-import-test-geocoding\",\"apiKey\":\"geo-key-value\"}},\"conflictResolutions\":{}}");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("null", reply);
    try expectVaultSecret(&app, "share-import-test-geocoding", "api-key", "geo-key-value");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const entry = (try node_api.databases_config.findDatabase(arena.allocator(), std.testing.io, "Shared photos")).?;
    try std.testing.expectEqualStrings("fs:/photos/shared", entry.path);
    try std.testing.expectEqualStrings("from another device", entry.description);
    try std.testing.expectEqualStrings("share-import-test-geocoding", entry.geocodingKey.?);
}

test "import-share-payload replaces a secret whose name is taken when the page chose nothing for it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"share-import-test-taken-default\",\"type\":\"api-key\",\"value\":\"old\"}"));
    allocator.free(try app.requestOk("import-share-payload", "{\"payload\":{\"type\":\"database\",\"name\":\"Taken default\",\"description\":\"\",\"path\":\"fs:/photos/taken-default\",\"geocodingKey\":{\"name\":\"share-import-test-taken-default\",\"apiKey\":\"new\"}},\"conflictResolutions\":{}}"));
    try expectVaultSecret(&app, "share-import-test-taken-default", "api-key", "new");
}

test "import-share-payload keeps the existing secret when the page chose to reuse it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"share-import-test-taken-reuse\",\"type\":\"api-key\",\"value\":\"old\"}"));
    allocator.free(try app.requestOk("import-share-payload", "{\"payload\":{\"type\":\"database\",\"name\":\"Taken reuse\",\"description\":\"\",\"path\":\"fs:/photos/taken-reuse\",\"geocodingKey\":{\"name\":\"share-import-test-taken-reuse\",\"apiKey\":\"new\"}},\"conflictResolutions\":{\"share-import-test-taken-reuse\":{\"action\":\"reuse\"}}}"));
    try expectVaultSecret(&app, "share-import-test-taken-reuse", "api-key", "old");
}

test "import-share-payload saves the incoming secret under a new name when the page chose to rename it" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"share-import-test-taken-rename\",\"type\":\"api-key\",\"value\":\"old\"}"));
    allocator.free(try app.requestOk("import-share-payload", "{\"payload\":{\"type\":\"database\",\"name\":\"Taken rename\",\"description\":\"\",\"path\":\"fs:/photos/taken-rename\",\"geocodingKey\":{\"name\":\"share-import-test-taken-rename\",\"apiKey\":\"new\"}},\"conflictResolutions\":{\"share-import-test-taken-rename\":{\"action\":\"rename\",\"newName\":\"share-import-test-renamed\"}}}"));
    try expectVaultSecret(&app, "share-import-test-taken-rename", "api-key", "old");
    try expectVaultSecret(&app, "share-import-test-renamed", "api-key", "new");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const entry = (try node_api.databases_config.findDatabase(arena.allocator(), std.testing.io, "Taken rename")).?;
    try std.testing.expectEqualStrings("share-import-test-renamed", entry.geocodingKey.?);
}

test "import-share-payload reports a payload of an unknown type as an error" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("import-share-payload", "{\"payload\":{\"type\":\"banana\"},\"conflictResolutions\":{}}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The shared payload is of a type that cannot be imported.", reply);
}

test "import-share-payload reports a secret payload with no name to save it under as an error" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("import-share-payload", "{\"payload\":{\"type\":\"secret\",\"name\":\"n\",\"secretType\":\"api-key\",\"value\":\"v\"},\"conflictResolutions\":{}}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The shared secret needs a name to be saved under.", reply);
}

test "import-share-payload reports a request with no payload as an error" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const reply = try app.requestError("import-share-payload", "{\"conflictResolutions\":{}}");
    defer std.testing.allocator.free(reply);
    try std.testing.expectEqualStrings("The request needs the payload that was shared.", reply);
}

test "import-share-payload with no conflictResolutions is an error reply when a secret's name is taken" {
    var app: TestApp = undefined;
    try app.start();
    defer app.stop();
    const allocator = std.testing.allocator;
    allocator.free(try app.requestOk("vault-set", "{\"name\":\"share-import-test-no-choices\",\"type\":\"api-key\",\"value\":\"old\"}"));
    const reply = try app.requestError("import-share-payload", "{\"payload\":{\"type\":\"database\",\"name\":\"No choices\",\"description\":\"\",\"path\":\"fs:/photos/no-choices\",\"geocodingKey\":{\"name\":\"share-import-test-no-choices\",\"apiKey\":\"new\"}}}");
    defer allocator.free(reply);
    try std.testing.expectEqualStrings("The request needs the choices made for the secrets whose names are already taken.", reply);
    try expectVaultSecret(&app, "share-import-test-no-choices", "api-key", "old");
}
