//
// Tests for databases-config.worker.zig.
//
// Tests for the mobile databases.toml handlers.
//
// These run against the real filesystem rather than a mock, because the point of the handlers is the
// bytes they put on disk: mobile and desktop have to agree on the file, so the assertions are about
// the TOML itself (snake_case keys, a `databases` array of tables, `recent_database_names`), not
// about which functions were called.
//
// The handlers reach storage through FileStorage, which resolves relative paths against the process
// working directory on a host and against the app's sandbox root on a device. The tests therefore
// run from a temporary directory, which is what the sandbox root stands in for.
//

const std = @import("std");
const test_timers = @import("test-timers.zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const node_api = @import("node-api-zig");
const temp_dirs = @import("temp-dirs.zig");
const test_task_context = @import("test-task-context.zig");
const errors = utils.errors;
const toml = node_utils.toml;
const databases_config_worker = node_api.databases_config_worker;
const readDatabasesConfigHandler = databases_config_worker.readDatabasesConfigHandler;
const writeDatabasesConfigHandler = databases_config_worker.writeDatabasesConfigHandler;
const registerDatabaseInConfig = databases_config_worker.registerDatabaseInConfig;
const buildDatabasesConfigToml = databases_config_worker.buildDatabasesConfigToml;
const IDatabaseEntry = node_api.databases_config_format.IDatabaseEntry;
const TestTaskContext = test_task_context.TestTaskContext;
const TestUuidGenerator = node_utils.test_uuid_generator.TestUuidGenerator;

//
// A temporary working directory standing in for the app's storage sandbox, the directory the test switches back to
// afterwards, and the task context the handlers take (they ignore it). Declare it, call init on it in place, and call
// deinit when the test is done.
//
const Sandbox = struct {
    // Allocates everything the test makes.
    arena: std.heap.ArenaAllocator,

    // The io the handlers use.
    io: std.Io,

    // The absolute path of the temporary directory.
    tempDir: []const u8,

    // The working directory before the test changed it.
    previousCwd: []const u8,

    // The uuids of the task context.
    uuidGenerator: TestUuidGenerator,

    // The task context the handlers take.
    taskContext: TestTaskContext,

    //
    // Makes the temporary directory and changes into it.
    //
    fn init(self: *Sandbox) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        self.io = std.testing.io;
        self.previousCwd = try std.process.currentPathAlloc(self.io, allocator);
        self.tempDir = try temp_dirs.makeTempDir(allocator, self.io, "databases-config-worker");
        try std.process.setCurrentPath(self.io, self.tempDir);
        self.uuidGenerator = try TestUuidGenerator.init(allocator);
        self.taskContext.init(self.uuidGenerator.uuidGenerator());
    }

    //
    // Changes back to the directory the test started in and removes the temporary one.
    //
    fn deinit(self: *Sandbox) void {
        std.process.setCurrentPath(self.io, self.previousCwd) catch {
            @panic("The working directory could not be put back after a test.");
        };
        temp_dirs.removeTempDir(self.io, self.tempDir);
        self.arena.deinit();
    }

    //
    // Gets the allocator of the test.
    //
    fn arenaAllocator(self: *Sandbox) std.mem.Allocator {
        return self.arena.allocator();
    }

    //
    // Parses JSON text into a value.
    //
    fn json(self: *Sandbox, text: []const u8) !std.json.Value {
        return std.json.parseFromSliceLeaky(std.json.Value, self.arenaAllocator(), text, .{});
    }

    //
    // Writes the given text as databases.toml.
    //
    fn writeTomlText(self: *Sandbox, text: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(self.io, .{
            .sub_path = "databases.toml",
            .data = text,
        });
    }

    //
    // Reads databases.toml back as text.
    //
    fn readTomlText(self: *Sandbox) ![]const u8 {
        return std.Io.Dir.cwd().readFileAlloc(self.io, "databases.toml", self.arenaAllocator(), .unlimited);
    }

    //
    // Reads databases.toml back as a parsed document.
    //
    fn readTomlDocument(self: *Sandbox) !std.json.Value {
        return toml.parse(self.arenaAllocator(), try self.readTomlText());
    }

    //
    // Runs the read-databases-config handler for the config path and returns its result.
    //
    fn read(self: *Sandbox, configPath: []const u8) !std.json.Value {
        var object: std.json.ObjectMap = .empty;
        try object.put(self.arenaAllocator(), "configPath", .{
            .string = configPath,
        });
        return readDatabasesConfigHandler(self.arenaAllocator(), self.io, test_timers.timers(), .{
            .object = object,
        }, self.taskContext.context.taskContext());
    }

    //
    // Runs the write-databases-config handler with the JSON text as its data.
    //
    fn write(self: *Sandbox, dataJson: []const u8) !void {
        const result = try writeDatabasesConfigHandler(self.arenaAllocator(), self.io, test_timers.timers(), try self.json(dataJson), self.taskContext.context.taskContext());
        try std.testing.expect(result == .null);
    }

    //
    // Registers a test database in the config text.
    //
    fn register(self: *Sandbox, existingToml: []const u8, databasePath: []const u8) ![]const u8 {
        return registerDatabaseInConfig(self.arenaAllocator(), existingToml, databasePath);
    }

    //
    // Parses the text a registration returned.
    //
    fn parseRegistered(self: *Sandbox, existingToml: []const u8, databasePath: []const u8) !std.json.Value {
        return toml.parse(self.arenaAllocator(), try self.register(existingToml, databasePath));
    }

    //
    // Renders a config as TOML text, with the entries given as JSON text.
    //
    fn build(self: *Sandbox, databasesJson: []const u8, recentDatabaseNames: []const []const u8, lastDatabase: ?[]const u8) ![]const u8 {
        const databases = try std.json.parseFromSliceLeaky([]const IDatabaseEntry, self.arenaAllocator(), databasesJson, .{});
        return buildDatabasesConfigToml(self.arenaAllocator(), databases, recentDatabaseNames, lastDatabase);
    }

    //
    // Expects the value to equal the value the JSON text holds, whatever the order of the keys of an object.
    //
    fn expectJson(self: *Sandbox, expectedJson: []const u8, actual: std.json.Value) !void {
        const expected = try self.json(expectedJson);
        if (!jsonEqual(expected, actual)) {
            const actualText = try std.json.Stringify.valueAlloc(self.arenaAllocator(), actual, .{});
            std.debug.print("Expected {s}\nFound    {s}\n", .{ expectedJson, actualText });
            return error.TestExpectedEqual;
        }
    }
};

//
// Returns true when the two values are the same, whatever the order of the keys of an object (toEqual).
//
fn jsonEqual(left: std.json.Value, right: std.json.Value) bool {
    switch (left) {
        .null => return right == .null,
        .bool => |value| return right == .bool and right.bool == value,
        .integer => |value| return right == .integer and right.integer == value,
        .float => |value| return right == .float and right.float == value,
        .number_string => |value| return right == .number_string and std.mem.eql(u8, right.number_string, value),
        .string => |value| return right == .string and std.mem.eql(u8, right.string, value),
        .array => |value| {
            if (right != .array or right.array.items.len != value.items.len) {
                return false;
            }
            for (value.items, 0..) |item, index| {
                if (!jsonEqual(item, right.array.items[index])) {
                    return false;
                }
            }
            return true;
        },
        .object => |value| {
            if (right != .object or right.object.count() != value.count()) {
                return false;
            }
            var iterator = value.iterator();
            while (iterator.next()) |entry| {
                const other = right.object.get(entry.key_ptr.*) orelse {
                    return false;
                };
                if (!jsonEqual(entry.value_ptr.*, other)) {
                    return false;
                }
            }
            return true;
        },
    }
}

//
// Gets the value at a key of an object, failing the test when it is absent.
//
fn field(value: std.json.Value, key: []const u8) !std.json.Value {
    return value.object.get(key) orelse {
        std.debug.print("Nothing at {s}\n", .{key});
        return error.TestExpectedEqual;
    };
}

//
// Expects the value at the key to be an array holding exactly these strings.
//
fn expectStrings(expected: []const []const u8, value: std.json.Value, key: []const u8) !void {
    const found = try field(value, key);
    try std.testing.expectEqual(expected.len, found.array.items.len);
    for (expected, 0..) |text, index| {
        try std.testing.expectEqualStrings(text, found.array.items[index].string);
    }
}

//
// Expects the names of the entries at the key to be exactly these.
//
fn expectNames(expected: []const []const u8, value: std.json.Value, key: []const u8) !void {
    const found = try field(value, key);
    try std.testing.expectEqual(expected.len, found.array.items.len);
    for (expected, 0..) |text, index| {
        try std.testing.expectEqualStrings(text, found.array.items[index].object.get("name").?.string);
    }
}

//
// Expects the handler to fail with this message.
//
fn expectThrown(expectedMessage: []const u8, result: anytype) !void {
    try std.testing.expectError(error.Thrown, result);
    try std.testing.expectEqualStrings(expectedMessage, errors.lastErrorMessage());
}

//
// A config holding two databases of the user's own and one left by an earlier fixture run.
//
const existingConfig =
    \\recent_database_names = ["My photos", "test-1-asset"]
    \\
    \\[[databases]]
    \\name = "My photos"
    \\description = "Everything"
    \\path = "/home/alice/photos"
    \\s3_key = "default:s3"
    \\
    \\[[databases]]
    \\name = "Holiday"
    \\description = ""
    \\path = "s3:bucket:/holiday"
    \\
    \\[[databases]]
    \\name = "test-1-asset"
    \\description = ""
    \\path = "1-asset"
    \\
;

// A fresh install has no file, and that must read as "no databases" rather than fail.
test "mobile databases.toml: reading a config that does not exist yields empty lists" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const result = try sandbox.read("databases.toml");

    try sandbox.expectJson("{\"databases\":[],\"recentDatabaseNames\":[]}", result);
}

test "mobile databases.toml: writing then reading round-trips the databases and recents" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.write(
        \\{"configPath":"databases.toml","databases":[{"name":"50-assets","description":"","path":"50-assets"},{"name":"Holiday","description":"Trip photos","path":"holiday"}],"recentDatabaseNames":["Holiday","50-assets"]}
    );

    const result = try sandbox.read("databases.toml");

    try sandbox.expectJson(
        \\[{"name":"50-assets","description":"","path":"50-assets"},{"name":"Holiday","description":"Trip photos","path":"holiday"}]
    , try field(result, "databases"));
    try expectStrings(&.{ "Holiday", "50-assets" }, result, "recentDatabaseNames");
}

test "mobile databases.toml: the file written uses the same snake_case TOML shape as desktop" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.write(
        \\{"configPath":"databases.toml","databases":[{"name":"Encrypted","description":"","path":"enc","origin":"s3:bucket:/x","s3Key":"default:s3","encryptionKey":"default:key","geocodingKey":"default:geo"}],"recentDatabaseNames":["Encrypted"]}
    );

    // Parsed as plain TOML, so this asserts the on-disk keys rather than trusting the reader to
    // agree with the writer. These are the keys databases-config.zig writes on desktop.
    const document = try sandbox.readTomlDocument();
    try expectStrings(&.{"Encrypted"}, document, "recent_database_names");
    try std.testing.expectEqual(@as(usize, 1), (try field(document, "databases")).array.items.len);
    try sandbox.expectJson(
        \\{"name":"Encrypted","description":"","path":"enc","origin":"s3:bucket:/x","s3_key":"default:s3","encryption_key":"default:key","geocoding_key":"default:geo"}
    , (try field(document, "databases")).array.items[0]);
}

// Written by hand in the layout desktop produces, to prove mobile reads desktop's file rather
// than only its own output.
test "mobile databases.toml: a config written by desktop is read back with the optional fields mapped" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeTomlText(
        \\recent_database_names = ["Photos"]
        \\
        \\[[databases]]
        \\name = "Photos"
        \\description = "From the desktop"
        \\path = "photos"
        \\s3_key = "default:s3"
        \\encryption_key = "default:key"
        \\geocoding_key = "default:geo"
        \\origin = "s3:bucket:/photos"
        \\
    );

    const result = try sandbox.read("databases.toml");

    try expectStrings(&.{"Photos"}, result, "recentDatabaseNames");
    try sandbox.expectJson(
        \\{"name":"Photos","description":"From the desktop","path":"photos","origin":"s3:bucket:/photos","s3Key":"default:s3","encryptionKey":"default:key","geocodingKey":"default:geo"}
    , (try field(result, "databases")).array.items[0]);
}

test "mobile databases.toml: optional fields absent from an entry stay absent" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.write(
        \\{"configPath":"databases.toml","databases":[{"name":"Plain","description":"","path":"plain"}],"recentDatabaseNames":[]}
    );

    const raw = try sandbox.readTomlText();
    try std.testing.expect(std.mem.indexOf(u8, raw, "s3_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "encryption_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "geocoding_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, raw, "origin") == null);

    const result = try sandbox.read("databases.toml");
    try sandbox.expectJson(
        \\{"name":"Plain","description":"","path":"plain"}
    , (try field(result, "databases")).array.items[0]);
}

test "mobile databases.toml: writing replaces the previous contents rather than appending" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.write(
        \\{"configPath":"databases.toml","databases":[{"name":"First","description":"","path":"first"}],"recentDatabaseNames":["First"]}
    );
    try sandbox.write(
        \\{"configPath":"databases.toml","databases":[{"name":"Second","description":"","path":"second"}],"recentDatabaseNames":[]}
    );

    const result = try sandbox.read("databases.toml");

    try expectNames(&.{"Second"}, result, "databases");
    try expectStrings(&.{}, result, "recentDatabaseNames");
}

test "mobile databases.toml: a missing configPath is rejected" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try expectThrown("configPath is required", sandbox.read(""));
    try expectThrown("configPath is required", writeDatabasesConfigHandler(sandbox.arenaAllocator(), sandbox.io, test_timers.timers(), try sandbox.json(
        \\{"configPath":"","databases":[],"recentDatabaseNames":[]}
    ), sandbox.taskContext.context.taskContext()));
}

test "registering a test database in a config: the fixture is registered under a name marking it as a test database" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const result = try sandbox.parseRegistered("", "50-assets");

    try sandbox.expectJson(
        \\[{"name":"test-50-assets","description":"","path":"50-assets"}]
    , try field(result, "databases"));
}

test "registering a test database in a config: the user's own databases are left exactly as they were" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const result = try sandbox.parseRegistered(existingConfig, "50-assets");

    var own: std.json.Array = .init(sandbox.arenaAllocator());
    for ((try field(result, "databases")).array.items) |entry| {
        if (!std.mem.startsWith(u8, entry.object.get("name").?.string, "test-")) {
            try own.append(entry);
        }
    }
    try sandbox.expectJson(
        \\[{"name":"My photos","description":"Everything","path":"/home/alice/photos","s3_key":"default:s3"},{"name":"Holiday","description":"","path":"s3:bucket:/holiday"}]
    , .{
        .array = own,
    });
}

test "registering a test database in a config: the fixture becomes the most recent, the user's own recents follow it, and stale test recents are dropped" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const result = try sandbox.parseRegistered(existingConfig, "50-assets");

    try expectStrings(&.{ "test-50-assets", "My photos" }, result, "recent_database_names");
}

// The point of the deploy script: the app lands in the database it just seeded rather than
// on the welcome screen.
test "registering a test database in a config: the fixture becomes the database reopened on launch" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const result = try sandbox.parseRegistered(existingConfig, "50-assets");

    try std.testing.expectEqualStrings("50-assets", (try field(result, "last_database")).string);
}

test "registering a test database in a config: registering a second fixture replaces the one reopened on launch" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const first = try sandbox.register(existingConfig, "50-assets");

    const result = try sandbox.parseRegistered(first, "1-asset");

    try std.testing.expectEqualStrings("1-asset", (try field(result, "last_database")).string);
    try expectStrings(&.{ "test-1-asset", "My photos" }, result, "recent_database_names");
}

test "registering a test database in a config: an earlier fixture is replaced rather than accumulating" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const result = try sandbox.parseRegistered(existingConfig, "50-assets");

    var tests: std.json.Array = .init(sandbox.arenaAllocator());
    for ((try field(result, "databases")).array.items) |entry| {
        if (std.mem.startsWith(u8, entry.object.get("name").?.string, "test-")) {
            try tests.append(entry);
        }
    }
    try sandbox.expectJson(
        \\[{"name":"test-50-assets","description":"","path":"50-assets"}]
    , .{
        .array = tests,
    });
}

test "registering a test database in a config: registering repeatedly never accumulates entries" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    var config = try sandbox.register(existingConfig, "50-assets");
    config = try sandbox.register(config, "1-asset");
    config = try sandbox.register(config, "no-assets");

    const result = try toml.parse(sandbox.arenaAllocator(), config);

    try expectNames(&.{ "My photos", "Holiday", "test-no-assets" }, result, "databases");
}

// Overwriting is at its most destructive exactly when the file cannot be read, so this must
// never silently start from an empty config.
test "registering a test database in a config: malformed TOML throws rather than replacing the config" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    try std.testing.expectError(error.Thrown, sandbox.register("this is not [ valid toml", "50-assets"));
}

test "registering a test database in a config: the result is readable by the handler that reads it on device" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeTomlText(try sandbox.register(existingConfig, "50-assets"));

    const read = try sandbox.read("databases.toml");

    try expectNames(&.{ "My photos", "Holiday", "test-50-assets" }, read, "databases");
    try expectStrings(&.{ "test-50-assets", "My photos" }, read, "recentDatabaseNames");
    try std.testing.expectEqualStrings("50-assets", (try field(read, "lastDatabase")).string);
}

test "buildDatabasesConfigToml: renders the entries and recents in the on-disk snake_case shape" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const rendered = try sandbox.build(
        \\[{"name":"Alpha","description":"","path":"alpha","encryptionKey":"alpha-key"}]
    , &.{"Alpha"}, null);
    const parsed = try toml.parse(sandbox.arenaAllocator(), rendered);

    try sandbox.expectJson(
        \\[{"name":"Alpha","description":"","path":"alpha","encryption_key":"alpha-key"}]
    , try field(parsed, "databases"));
    try expectStrings(&.{"Alpha"}, parsed, "recent_database_names");
}

test "buildDatabasesConfigToml: renders empty lists for a config with nothing in it" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const parsed = try toml.parse(sandbox.arenaAllocator(), try sandbox.build("[]", &.{}, null));

    try std.testing.expectEqual(@as(usize, 0), (try field(parsed, "databases")).array.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try field(parsed, "recent_database_names")).array.items.len);
}

test "buildDatabasesConfigToml: the result is readable by the handler that reads it on device" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeTomlText(try sandbox.build(
        \\[{"name":"Alpha","description":"","path":"alpha"}]
    , &.{"Alpha"}, null));

    const read = try sandbox.read("databases.toml");

    try sandbox.expectJson(
        \\[{"name":"Alpha","description":"","path":"alpha"}]
    , try field(read, "databases"));
    try expectStrings(&.{"Alpha"}, read, "recentDatabaseNames");
}

test "the last opened database: is absent from a file that names none" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.writeTomlText(try sandbox.build(
        \\[{"name":"Alpha","description":"","path":"alpha"}]
    , &.{"Alpha"}, null));

    const read = try sandbox.read("databases.toml");

    try std.testing.expect(read.object.get("lastDatabase") == null);
}

test "the last opened database: is written and read back as the path it was given" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    try sandbox.write(
        \\{"configPath":"databases.toml","databases":[{"name":"Alpha","description":"","path":"alpha"}],"recentDatabaseNames":["Alpha"],"lastDatabase":"alpha"}
    );

    const read = try sandbox.read("databases.toml");

    try std.testing.expectEqualStrings("alpha", (try field(read, "lastDatabase")).string);
}

// The deploy script has just been told to put this fixture in front of the user, so it
// replaces whatever the file named, rather than leaving the app to open something else.
test "the last opened database: is taken over by a test fixture registered beside it" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();
    const existing = try sandbox.build(
        \\[{"name":"Alpha","description":"","path":"alpha"}]
    , &.{"Alpha"}, "alpha");

    const rewritten = try sandbox.register(existing, "50-assets");

    try sandbox.writeTomlText(rewritten);
    const read = try sandbox.read("databases.toml");
    try std.testing.expectEqualStrings("50-assets", (try field(read, "lastDatabase")).string);
    // The user's own database and their place in the recents list are still there.
    try expectNames(&.{ "Alpha", "test-50-assets" }, read, "databases");
    try expectStrings(&.{ "test-50-assets", "Alpha" }, read, "recentDatabaseNames");
}

test "the last opened database: is left out of the file entirely when there is none" {
    var sandbox: Sandbox = undefined;
    try sandbox.init();
    defer sandbox.deinit();

    const rendered = try sandbox.build(
        \\[{"name":"Alpha","description":"","path":"alpha"}]
    , &.{"Alpha"}, null);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "last_database") == null);
}
