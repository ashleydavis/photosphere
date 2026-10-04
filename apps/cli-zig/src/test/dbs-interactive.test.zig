//
// The prompts of the dbs commands (apps/cli-zig/src/cmd/dbs.zig against apps/cli/src/cmd/dbs.ts), answered the way a
// person answers them: the keys of each prompt are typed once the prompt is showing. What the tests check is what the
// TypeScript commands leave behind (databases.toml and the vault) and the messages they print.
//

const std = @import("std");
const helpers = @import("test-helpers.zig");

//
// The key that moves a select prompt down one option, and the key that confirms a prompt.
//
const down = "\x1b[B";
const enter = "\r";

//
// The databases.toml the dbs prompt tests start with: one entry that has every field.
//
const seed_config =
    \\recent_database_names = [ "photos" ]
    \\
    \\[[databases]]
    \\name = "photos"
    \\description = "My photos"
    \\path = "/data/photos"
    \\s3_key = "s3a"
    \\encryption_key = "my-key"
    \\geocoding_key = "geo"
    \\
;

//
// The vault the dbs prompt tests start with: one secret of each type a database links to.
//
const seed_vault =
    \\{"s3a":{"name":"s3a","type":"s3-credentials","value":"{\"region\":\"us-east-1\",\"accessKeyId\":\"AK\",\"secretAccessKey\":\"SK\"}"},"my-key":{"name":"my-key","type":"encryption-key","value":"PEM"},"geo":{"name":"geo","type":"api-key","value":"geo-value"}}
;

test "dbs add links the secrets it is told to and creates the ones it is asked to create" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "dbs-add-prompts");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.setupConfigAndVault(allocator, root, seed_config, seed_vault);
    const keyPath = try std.fmt.allocPrint(allocator, "{s}/imported.key", .{root});
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = keyPath,
        .data = "IMPORTED-PEM",
    });

    // Every secret is picked from the ones in the vault.
    const linked = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "add" }, &.{
        .{ .waitFor = "Database name:", .keys = "linked" ++ enter },
        .{ .waitFor = "Description (optional):", .keys = "Linked db" ++ enter },
        .{ .waitFor = "Database path (filesystem or S3):", .keys = "/p/linked" ++ enter },
        .{ .waitFor = "S3 credentials:", .keys = down ++ enter },
        .{ .waitFor = "Encryption key:", .keys = down ++ enter },
        .{ .waitFor = "Geocoding API key:", .keys = down ++ enter },
    });
    try std.testing.expectEqualStrings("", linked.stderr);
    try std.testing.expectEqual(@as(u8, 0), linked.exitCode);
    try helpers.expectContains(linked.stdout, "Add Database");
    try helpers.expectContains(linked.stdout, "\u{2713} Database \"linked\" added.");

    // Every secret is created: S3 credentials with an endpoint, an encryption key read from a file and an API key.
    const created = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "add" }, &.{
        .{ .waitFor = "Database name:", .keys = "created" ++ enter },
        .{ .waitFor = "Description (optional):", .keys = enter },
        .{ .waitFor = "Database path (filesystem or S3):", .keys = "s3:b/created" ++ enter },
        .{ .waitFor = "S3 credentials:", .keys = down ++ down ++ enter },
        .{ .waitFor = "Endpoint URL (leave blank for AWS):", .keys = "http://host:9000" ++ enter },
        .{ .waitFor = "Region (e.g. us-east-1):", .keys = "eu-west-1" ++ enter },
        .{ .waitFor = "Access Key ID:", .keys = "AKID" ++ enter },
        .{ .waitFor = "Secret Access Key:", .keys = "SECRET" ++ enter },
        .{ .waitFor = "Encryption key:", .keys = down ++ down ++ enter },
        .{ .waitFor = "How would you like to provide the key?", .keys = down ++ enter },
        .{ .waitFor = "Path to private key (.key):", .keys = try std.mem.concat(allocator, u8, &.{ keyPath, enter }) },
        .{ .waitFor = "Geocoding API key:", .keys = down ++ down ++ enter },
        .{ .waitFor = "API key value:", .keys = "key123" ++ enter },
    });
    try std.testing.expectEqualStrings("", created.stderr);
    try std.testing.expectEqual(@as(u8, 0), created.exitCode);
    try helpers.expectContains(created.stdout, "  \u{2713} S3 credential \"created:s3\" created");
    try helpers.expectContains(created.stdout, "  \u{2713} Encryption key \"created:encryption\" created");
    try helpers.expectContains(created.stdout, "  \u{2713} API key \"created:geocoding\" created");
    try helpers.expectContains(created.stdout, "\u{2713} Database \"created\" added.");

    try std.testing.expectEqualStrings(
        \\recent_database_names = [ "photos" ]
        \\
        \\[[databases]]
        \\name = "photos"
        \\description = "My photos"
        \\path = "/data/photos"
        \\s3_key = "s3a"
        \\encryption_key = "my-key"
        \\geocoding_key = "geo"
        \\
        \\[[databases]]
        \\name = "linked"
        \\description = "Linked db"
        \\path = "/p/linked"
        \\s3_key = "s3a"
        \\encryption_key = "my-key"
        \\geocoding_key = "geo"
        \\
        \\[[databases]]
        \\name = "created"
        \\description = ""
        \\path = "s3:b/created"
        \\s3_key = "created:s3"
        \\encryption_key = "created:encryption"
        \\geocoding_key = "created:geocoding"
        \\
    , try helpers.readRootFile(allocator, root, "config/databases.toml"));
    const vault = try helpers.readRootFile(allocator, root, "vault/vault.json");
    try helpers.expectContains(vault, "\"value\": \"{\\\"region\\\":\\\"eu-west-1\\\",\\\"accessKeyId\\\":\\\"AKID\\\",\\\"secretAccessKey\\\":\\\"SECRET\\\",\\\"endpoint\\\":\\\"http://host:9000\\\"}\"");
    try helpers.expectContains(vault, "\"name\": \"created:encryption\",\n    \"type\": \"encryption-key\",\n    \"value\": \"IMPORTED-PEM\"");
    try helpers.expectContains(vault, "\"name\": \"created:geocoding\",\n    \"type\": \"api-key\",\n    \"value\": \"key123\"");
}

test "dbs add refuses a name that is taken, asks for another name for a secret that is taken and can generate a key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "dbs-add-taken");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const takenVault =
        \\{"dbx:s3":{"name":"dbx:s3","type":"s3-credentials","value":"{}"}}
    ;
    const environment = try helpers.setupConfigAndVault(allocator, root, seed_config, takenVault);

    const nameTaken = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "add" }, &.{
        .{ .waitFor = "Database name:", .keys = "photos" ++ enter },
        .{ .waitFor = "Description (optional):", .keys = enter },
        .{ .waitFor = "Database path (filesystem or S3):", .keys = "/x" ++ enter },
    });
    try std.testing.expectEqual(@as(u8, 1), nameTaken.exitCode);
    try helpers.expectContains(nameTaken.stdout, "\u{2717} A database named \"photos\" already exists (/data/photos). Use a different name or remove the existing entry first.");
    try std.testing.expectEqualStrings(seed_config, try helpers.readRootFile(allocator, root, "config/databases.toml"));

    // The S3 credentials of dbx would be named dbx:s3, which the vault holds, so another name is asked for, and the
    // first one typed is taken too. The encryption key is generated.
    const created = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "add" }, &.{
        .{ .waitFor = "Database name:", .keys = "dbx" ++ enter },
        .{ .waitFor = "Description (optional):", .keys = enter },
        .{ .waitFor = "Database path (filesystem or S3):", .keys = "/x" ++ enter },
        .{ .waitFor = "S3 credentials:", .keys = down ++ down ++ enter },
        .{ .waitFor = "\u{25c6}  Name for this s3-credentials:", .keys = "dbx:s3" ++ enter },
        .{ .waitFor = "\u{25c6}  Name for this s3-credentials:", .keys = "dbx-credentials" ++ enter },
        .{ .waitFor = "Endpoint URL", .keys = enter },
        .{ .waitFor = "Region (e.g. us-east-1):", .keys = "r" ++ enter },
        .{ .waitFor = "Access Key ID:", .keys = "a" ++ enter },
        .{ .waitFor = "Secret Access Key:", .keys = "s" ++ enter },
        .{ .waitFor = "Encryption key:", .keys = down ++ enter },
        .{ .waitFor = "How would you like to provide the key?", .keys = enter },
        .{ .waitFor = "Geocoding API key:", .keys = enter },
    });
    try std.testing.expectEqual(@as(u8, 0), created.exitCode);
    try helpers.expectContains(created.stdout, "  \u{26a0} A secret named \"dbx:s3\" already exists. Choose a different name.");
    try helpers.expectContains(created.stderr, "\u{2717} A secret named \"dbx:s3\" already exists in the vault. Choose a different name.");
    try helpers.expectContains(created.stdout, "  \u{2713} S3 credential \"dbx-credentials\" created");
    try helpers.expectContains(created.stdout, "  \u{2713} Encryption key \"dbx:encryption\" created");
    try helpers.expectContains(try helpers.readRootFile(allocator, root, "vault/vault.json"), "-----BEGIN PRIVATE KEY-----");
}

//
// The key that cancels a prompt.
//
const cancel = "\x03";

test "dbs add says it was cancelled, and stops, when any of its prompts is cancelled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "dbs-add-cancel");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.setupConfigAndVault(allocator, root, seed_config, seed_vault);

    const nameCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "add" }, &.{
        .{ .waitFor = "Database name:", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), nameCancelled.exitCode);
    try helpers.expectContains(nameCancelled.stdout, "Cancelled.");

    const descriptionCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "add" }, &.{
        .{ .waitFor = "Database name:", .keys = "one" ++ enter },
        .{ .waitFor = "Description (optional):", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), descriptionCancelled.exitCode);
    try helpers.expectContains(descriptionCancelled.stdout, "Cancelled.");

    const secretCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "add" }, &.{
        .{ .waitFor = "Database name:", .keys = "one" ++ enter },
        .{ .waitFor = "Description (optional):", .keys = enter },
        .{ .waitFor = "Database path (filesystem or S3):", .keys = "/one" ++ enter },
        .{ .waitFor = "S3 credentials:", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), secretCancelled.exitCode);
    try helpers.expectContains(secretCancelled.stdout, "Cancelled.");

    const keyChoiceCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "add" }, &.{
        .{ .waitFor = "Database name:", .keys = "one" ++ enter },
        .{ .waitFor = "Description (optional):", .keys = enter },
        .{ .waitFor = "Database path (filesystem or S3):", .keys = "/one" ++ enter },
        .{ .waitFor = "S3 credentials:", .keys = enter },
        .{ .waitFor = "Encryption key:", .keys = down ++ down ++ enter },
        .{ .waitFor = "How would you like to provide the key?", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), keyChoiceCancelled.exitCode);
    try helpers.expectContains(keyChoiceCancelled.stdout, "Cancelled.");

    const requiredCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "add" }, &.{
        .{ .waitFor = "Database name:", .keys = "one" ++ enter },
        .{ .waitFor = "Description (optional):", .keys = enter },
        .{ .waitFor = "Database path (filesystem or S3):", .keys = "/one" ++ enter },
        .{ .waitFor = "S3 credentials:", .keys = down ++ down ++ enter },
        .{ .waitFor = "Endpoint URL", .keys = enter },
        .{ .waitFor = "Region (e.g. us-east-1):", .keys = enter ++ cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), requiredCancelled.exitCode);
    try helpers.expectContains(requiredCancelled.stdout, "This field is required");
    try helpers.expectContains(requiredCancelled.stdout, "Cancelled.");

    const optionalCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "add" }, &.{
        .{ .waitFor = "Database name:", .keys = "one" ++ enter },
        .{ .waitFor = "Description (optional):", .keys = enter },
        .{ .waitFor = "Database path (filesystem or S3):", .keys = "/one" ++ enter },
        .{ .waitFor = "S3 credentials:", .keys = down ++ down ++ enter },
        .{ .waitFor = "Endpoint URL", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), optionalCancelled.exitCode);
    try helpers.expectContains(optionalCancelled.stdout, "Cancelled.");

    // None of those added a database.
    try std.testing.expectEqualStrings(seed_config, try helpers.readRootFile(allocator, root, "config/databases.toml"));
}

test "dbs edit changes a database picked from the list, with its secrets, and says when it is cancelled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "dbs-edit-prompts");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.setupConfigAndVault(allocator, root, seed_config, seed_vault);

    // Each prompt starts with the current value: typing adds to it. The S3 credentials and the geocoding key are
    // changed to None, and the encryption key is kept.
    const edited = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "edit" }, &.{
        .{ .waitFor = "Select a database to edit:", .keys = enter },
        .{ .waitFor = "Database name:", .keys = "2" ++ enter },
        .{ .waitFor = "Description:", .keys = " edited" ++ enter },
        .{ .waitFor = "Database path:", .keys = "/more" ++ enter },
        .{ .waitFor = "S3 credentials:", .keys = "\x1b[A" ++ enter },
        .{ .waitFor = "Encryption key:", .keys = enter },
        .{ .waitFor = "Geocoding API key:", .keys = "\x1b[A" ++ enter },
    });
    try std.testing.expectEqualStrings("", edited.stderr);
    try std.testing.expectEqual(@as(u8, 0), edited.exitCode);
    try helpers.expectContains(edited.stdout, "Edit Database: photos");
    try helpers.expectContains(edited.stdout, "\u{2713} Database \"photos2\" updated.");
    try std.testing.expectEqualStrings(
        \\recent_database_names = [ "photos2" ]
        \\
        \\[[databases]]
        \\name = "photos2"
        \\description = "My photos edited"
        \\path = "/data/photos/more"
        \\encryption_key = "my-key"
        \\
    , try helpers.readRootFile(allocator, root, "config/databases.toml"));

    const selectCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "edit" }, &.{
        .{ .waitFor = "Select a database to edit:", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), selectCancelled.exitCode);
    try helpers.expectContains(selectCancelled.stdout, "Cancelled.");

    const nameCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "edit", "--name", "photos2" }, &.{
        .{ .waitFor = "Database name:", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), nameCancelled.exitCode);
    try helpers.expectContains(nameCancelled.stdout, "Cancelled.");

    const descriptionCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "edit", "--name", "photos2" }, &.{
        .{ .waitFor = "Database name:", .keys = enter },
        .{ .waitFor = "Description:", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), descriptionCancelled.exitCode);
    try helpers.expectContains(descriptionCancelled.stdout, "Cancelled.");

    const pathCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "edit", "--name", "photos2" }, &.{
        .{ .waitFor = "Database name:", .keys = enter },
        .{ .waitFor = "Description:", .keys = enter },
        .{ .waitFor = "Database path:", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), pathCancelled.exitCode);
    try helpers.expectContains(pathCancelled.stdout, "Cancelled.");
}

test "dbs view, edit and remove with no databases say there are none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "dbs-none");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.setupConfigAndVault(allocator, root, null, "{}");

    for ([_][]const u8{ "view", "edit", "remove" }) |subcommand| {
        const result = try helpers.runPsi(allocator, environment, &.{ "dbs", subcommand });
        try std.testing.expectEqualStrings("No databases configured.\n", result.stdout);
        try std.testing.expectEqualStrings("", result.stderr);
        try std.testing.expectEqual(@as(u8, 0), result.exitCode);
    }
}

test "dbs view and remove say they were cancelled when the list they pick from is cancelled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "dbs-pick-cancel");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.setupConfigAndVault(allocator, root, seed_config, seed_vault);

    const viewCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "view" }, &.{
        .{ .waitFor = "Select a database to view:", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), viewCancelled.exitCode);
    try helpers.expectContains(viewCancelled.stdout, "Cancelled.");

    const removeCancelled = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "remove" }, &.{
        .{ .waitFor = "Select a database to remove:", .keys = cancel },
    });
    try std.testing.expectEqual(@as(u8, 0), removeCancelled.exitCode);
    try helpers.expectContains(removeCancelled.stdout, "Cancelled.");

    // Answering no to the confirmation keeps the database.
    const removeDeclined = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "remove", "--name", "photos" }, &.{
        .{ .waitFor = "This does not delete the database files.", .keys = "n" },
    });
    try std.testing.expectEqual(@as(u8, 0), removeDeclined.exitCode);
    try helpers.expectContains(removeDeclined.stdout, "Cancelled.");
    try std.testing.expectEqualStrings(seed_config, try helpers.readRootFile(allocator, root, "config/databases.toml"));
}

test "dbs clear lists the databases and asks twice before it removes them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const root = try helpers.makeTempDir(allocator, "dbs-clear-prompts");
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, root) catch {};
    const environment = try helpers.setupConfigAndVault(allocator, root, seed_config, seed_vault);

    const firstDeclined = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "clear" }, &.{
        .{ .waitFor = "Remove all 1 database(s) from the list?", .keys = "n" },
    });
    try std.testing.expectEqual(@as(u8, 0), firstDeclined.exitCode);
    try helpers.expectContains(firstDeclined.stdout, "Databases to be removed:\n  photos (/data/photos)\n");
    try helpers.expectContains(firstDeclined.stdout, "Cancelled.");

    const secondDeclined = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "clear" }, &.{
        .{ .waitFor = "Remove all 1 database(s) from the list?", .keys = "y" },
        .{ .waitFor = "Are you sure? All database entries will be permanently removed from the list.", .keys = "n" },
    });
    try std.testing.expectEqual(@as(u8, 0), secondDeclined.exitCode);
    try helpers.expectContains(secondDeclined.stdout, "Cancelled.");
    try std.testing.expectEqualStrings(seed_config, try helpers.readRootFile(allocator, root, "config/databases.toml"));

    const cleared = try helpers.runPsiWithPrompts(allocator, environment, &.{ "dbs", "clear" }, &.{
        .{ .waitFor = "Remove all 1 database(s) from the list?", .keys = "y" },
        .{ .waitFor = "Are you sure? All database entries will be permanently removed from the list.", .keys = "y" },
    });
    try std.testing.expectEqual(@as(u8, 0), cleared.exitCode);
    try helpers.expectContains(cleared.stdout, "\u{2713} Removed 1 database(s) from the list.");
}
