const std = @import("std");
const cli = @import("cli-zig");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const tools = @import("tools-zig");
const task_queue = @import("task-queue-zig");
const helpers = @import("test-helpers.zig");
const init_cmd = cli.init_cmd;
const McpServer = cli.mcp_protocol.McpServer;
const IMcpToolContext = cli.mcp_types.IMcpToolContext;
const io = std.testing.io;

//
// The tests of the tools of `psi mcp` (apps/cli/src/lib/mcp/tools), called through the server the command creates,
// against a copy of test/dbs/v6. The expected texts are the ones the TypeScript tools return for test/dbs/v6.
//

//
// The ID of the one asset of test/dbs/v6.
//
const v6_asset_id = "89171cd9-a652-4047-b869-1154bf2c95a1";

//
// The environment of a test: a copy of test/dbs/v6, a config and vault of its own, the command context of
// `psi mcp` (with its worker pool) and the server with every tool registered.
//
const IToolsTestEnvironment = struct {
    // Owns the test's memory.
    arena: std.heap.ArenaAllocator,

    // The environment variables of the test.
    environ_map: std.process.Environ.Map,

    // The test's directory: the database is in <root>/db and the config in <root>/config.
    root: []const u8,

    // What the tools write to stdout (nothing, unless something goes wrong).
    stdout_capture: std.Io.Writer.Allocating,

    // The log the test replaces (initContext configures a log of its own).
    previous_log: @TypeOf(utils.log.log),

    // The state of the tools.
    toolContext: *IMcpToolContext,

    // The server the tools are called through.
    server: *McpServer,

    //
    // Sets up the environment, the command context and the server.
    //
    fn init(self: *IToolsTestEnvironment, name: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const allocator = self.arena.allocator();
        const status = try tools.verifyTools(allocator, io);
        if (!status.allAvailable) {
            std.debug.print("This test needs ImageMagick and ffmpeg installed. Missing: {s}\n", .{try std.mem.join(allocator, ", ", status.missingTools)});
            return error.RequiredToolsMissing;
        }
        self.root = try helpers.makeTempDir(allocator, name);
        try helpers.copyDirectory(allocator, "../../test/dbs/v6", try std.fmt.allocPrint(allocator, "{s}/db", .{self.root}));
        const configDir = try std.fmt.allocPrint(allocator, "{s}/config", .{self.root});
        try std.Io.Dir.cwd().createDirPath(io, configDir);
        const tmpDir = try std.fmt.allocPrint(allocator, "{s}/tmp", .{self.root});
        try std.Io.Dir.cwd().createDirPath(io, tmpDir);

        self.environ_map = std.process.Environ.Map.init(allocator);
        // The tools (ImageMagick, ffmpeg) are found through the PATH of the process running the tests.
        const parent = try std.testing.environ.createMap(allocator);
        if (parent.get("PATH")) |searchPath| {
            try self.environ_map.put("PATH", searchPath);
        }
        try self.environ_map.put("PHOTOSPHERE_CONFIG_DIR", configDir);
        try self.environ_map.put("PHOTOSPHERE_CACHE_DIR", try std.fmt.allocPrint(allocator, "{s}/cache", .{self.root}));
        try self.environ_map.put("PHOTOSPHERE_VAULT_TYPE", "plaintext");
        try self.environ_map.put("PHOTOSPHERE_VAULT_DIR", try std.fmt.allocPrint(allocator, "{s}/vault", .{self.root}));
        // os.tmpdir() reads TMPDIR on POSIX and TEMP on Windows.
        try self.environ_map.put("TMPDIR", tmpDir);
        try self.environ_map.put("TEMP", tmpDir);
        node_utils.process_env.setEnvironMap(&self.environ_map);

        self.stdout_capture = std.Io.Writer.Allocating.init(allocator);
        utils.console.setCapture(&self.stdout_capture.writer, &self.stdout_capture.writer);
        self.previous_log = utils.log.log;

        const context = try init_cmd.initContext(allocator, io, .{ .yes = true, .workers = "2" });
        self.toolContext = try allocator.create(IMcpToolContext);
        self.toolContext.* = .{
            .uuidGenerator = context.uuidGenerator,
            .timestampProvider = context.timestampProvider,
            .sessionId = context.sessionId,
            .options = .{ .yes = true },
            .allocator = allocator,
        };
        self.server = try cli.mcp.createMcpServer(allocator, self.toolContext);
    }

    //
    // Shuts the worker pool down, restores the process state and deletes the test's directory.
    //
    fn deinit(self: *IToolsTestEnvironment) void {
        node_utils.termination.invokeTerminationCallbacks(io, 0) catch |err| {
            std.debug.print("The termination callbacks failed: {t}\n", .{err});
        };
        node_utils.termination.clearTerminationCallbacks();
        task_queue.queue_backend.setQueueBackend(null);
        utils.log.setLog(self.previous_log);
        utils.console.setCapture(null, null);
        node_utils.process_env.setEnvironMap(null);
        std.Io.Dir.cwd().deleteTree(io, self.root) catch {};
        self.arena.deinit();
    }

    //
    // Registers the test's database in databases.toml under a name.
    //
    fn registerDatabase(self: *IToolsTestEnvironment, name: []const u8, description: []const u8) !void {
        const allocator = self.arena.allocator();
        try std.Io.Dir.cwd().writeFile(io, .{
            .sub_path = try std.fmt.allocPrint(allocator, "{s}/config/databases.toml", .{self.root}),
            .data = try std.fmt.allocPrint(allocator, "[[databases]]\nname = '{s}'\ndescription = '{s}'\npath = '{s}/db'\n", .{ name, description, self.root }),
        });
    }

    //
    // The path of the test's database, as a tool reports it.
    //
    fn databasePath(self: *IToolsTestEnvironment) ![]const u8 {
        return std.fmt.allocPrint(self.arena.allocator(), "{s}/db", .{self.root});
    }

    //
    // Calls a tool with the JSON of its arguments and returns the text of its result.
    //
    fn call(self: *IToolsTestEnvironment, toolName: []const u8, argumentsJson: []const u8) !IToolText {
        const allocator = self.arena.allocator();
        const request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ toolName, argumentsJson });
        const answer = (try self.server.handleMessage(allocator, io, request)).?;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, answer, .{});
        const result = parsed.object.get("result").?.object;
        const content = result.get("content").?.array.items;
        try std.testing.expectEqual(@as(usize, 1), content.len);
        try std.testing.expectEqualStrings("text", content[0].object.get("type").?.string);
        return .{
            .text = content[0].object.get("text").?.string,
            .isError = if (result.get("isError")) |isError| isError.bool else false,
        };
    }

    //
    // Calls a tool and expects the text of a result that is not an error.
    //
    fn expectText(self: *IToolsTestEnvironment, toolName: []const u8, argumentsJson: []const u8, expected: []const u8) !void {
        const result = try self.call(toolName, argumentsJson);
        try std.testing.expectEqualStrings(expected, result.text);
        try std.testing.expect(!result.isError);
    }

    //
    // Opens the test's database with open_database.
    //
    fn openDatabase(self: *IToolsTestEnvironment) !void {
        const allocator = self.arena.allocator();
        const escapedPath = try std.mem.replaceOwned(u8, allocator, try self.databasePath(), "\\", "\\\\");
        try self.expectText("open_database", try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{escapedPath}), try std.fmt.allocPrint(allocator, "Opened database at {s}", .{try self.databasePath()}));
    }
};

//
// The text of a tool's result.
//
const IToolText = struct {
    // The text.
    text: []const u8,

    // True when the result is an error.
    isError: bool,
};

test "list_databases lists the databases of databases.toml, or says that there are none" {
    var environment: IToolsTestEnvironment = undefined;
    try environment.init("mcp-list-databases");
    defer environment.deinit();
    const allocator = environment.arena.allocator();

    try environment.expectText("list_databases", "{}", "No databases are configured. Use `psi dbs add <path>` to register one, or `psi init` to create a new one.");

    try environment.registerDatabase("photos", "My photos");
    try environment.expectText("list_databases", "{}", try std.fmt.allocPrint(allocator, "Configured databases:\n- photos ({s})\n  My photos", .{try environment.databasePath()}));

    // A database without a description is listed on one line.
    try environment.registerDatabase("photos", "");
    try environment.expectText("list_databases", "{}", try std.fmt.allocPrint(allocator, "Configured databases:\n- photos ({s})", .{try environment.databasePath()}));
}

test "open_database opens a database by path or by name, and close_database closes it" {
    var environment: IToolsTestEnvironment = undefined;
    try environment.init("mcp-open-database");
    defer environment.deinit();
    const allocator = environment.arena.allocator();

    try environment.expectText("close_database", "{}", "No database is currently open.");

    try environment.openDatabase();
    try std.testing.expectEqualStrings(try environment.databasePath(), environment.toolContext.getDatabase().?.databasePath);
    try environment.expectText("close_database", "{}", try std.fmt.allocPrint(allocator, "Closed database at {s}", .{try environment.databasePath()}));
    try std.testing.expect(environment.toolContext.getDatabase() == null);
    try environment.expectText("close_database", "{}", "No database is currently open.");

    try environment.registerDatabase("MyPhotos", "");
    try environment.expectText("open_database", "{\"path\":\"myphotos\"}", try std.fmt.allocPrint(allocator, "Opened database at {s}", .{try environment.databasePath()}));
    try std.testing.expectEqualStrings(try environment.databasePath(), environment.toolContext.getDatabase().?.databasePath);
    try std.testing.expect(environment.toolContext.getDatabase().?.encryptionKey == null);
}

test "the tools that work on a database say that none is open" {
    var environment: IToolsTestEnvironment = undefined;
    try environment.init("mcp-no-database");
    defer environment.deinit();

    const noDatabase = "No database is currently open. Use list_databases / open_database first.";
    try environment.expectText("get_database_summary", "{}", noDatabase);
    try environment.expectText("list_media_files", "{}", noDatabase);
    try environment.expectText("get_media_file_info", "{\"assetId\":\"" ++ v6_asset_id ++ "\"}", noDatabase);
    try environment.expectText("search_media_files", "{}", noDatabase);
    try environment.expectText("save_media_file", "{\"assetId\":\"" ++ v6_asset_id ++ "\",\"outputPath\":\"x\"}", noDatabase);
    try environment.expectText("import_media_files", "{\"paths\":[]}", noDatabase);
    try environment.expectText("verify_database", "{}", noDatabase);
}

test "get_database_summary returns the summary of the open database" {
    var environment: IToolsTestEnvironment = undefined;
    try environment.init("mcp-summary");
    defer environment.deinit();

    try environment.openDatabase();
    try environment.expectText("get_database_summary", "{}",
        \\{
        \\  "mode": "full",
        \\  "totalImports": 1,
        \\  "totalFiles": 4,
        \\  "totalSize": 2877318,
        \\  "totalNodes": 7,
        \\  "fullHash": "c18854777b06e1b0d499230db43f74b32bf937cd892c974b673621b979f40590",
        \\  "filesHash": "a9b73642fdb4367f37ad07a11351aabbc5ef7e9dfe334f0c554171fe84feb9bc",
        \\  "databaseHash": "291f9fdb6581bae7e0414c85bc280de52de1a0d0bc2dbc2e72f8f31df293e224",
        \\  "databaseVersion": 6
        \\}
    );
}

test "list_media_files returns a page of summaries of the media files, newest first" {
    var environment: IToolsTestEnvironment = undefined;
    try environment.init("mcp-list-media-files");
    defer environment.deinit();

    try environment.openDatabase();
    try environment.expectText("list_media_files", "{}",
        \\{
        \\  "mediaFiles": [
        \\    {
        \\      "_id": "89171cd9-a652-4047-b869-1154bf2c95a1",
        \\      "origFileName": "test.jpg",
        \\      "contentType": "image/jpeg",
        \\      "photoDate": "2025-05-27T09:54:16.000Z",
        \\      "width": 2560,
        \\      "height": 1920,
        \\      "coordinates": {
        \\        "lat": -29.019044444444443,
        \\        "lng": 152.18946666666668
        \\      }
        \\    }
        \\  ]
        \\}
    );

    // A page that does not exist is empty.
    try environment.expectText("list_media_files", "{\"limit\":1,\"pageId\":\"no-such-page\"}",
        \\{
        \\  "mediaFiles": []
        \\}
    );
}

test "get_media_file_info returns the record of a media file, or says that it is not found" {
    var environment: IToolsTestEnvironment = undefined;
    try environment.init("mcp-media-file-info");
    defer environment.deinit();
    const allocator = environment.arena.allocator();

    try environment.openDatabase();
    const result = try environment.call("get_media_file_info", "{\"assetId\":\"" ++ v6_asset_id ++ "\"}");
    try std.testing.expect(!result.isError);

    // The whole record, as JSON.stringify(asset, null, 2) writes it: the same as the TypeScript CLI's answer in the
    // session of mcp-session-expected.jsonl (id 9).
    const expected = try std.Io.Dir.cwd().readFileAlloc(io, "src/test/fixtures/mcp-session-expected.jsonl", allocator, .unlimited);
    var lines = std.mem.splitScalar(u8, expected, '\n');
    var expectedText: ?[]const u8 = null;
    while (lines.next()) |line| {
        if (std.mem.endsWith(u8, line, "\"id\":9}")) {
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, line, .{});
            expectedText = parsed.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
        }
    }
    try std.testing.expectEqualStrings(expectedText.?, result.text);
    try std.testing.expect(std.mem.startsWith(u8, result.text, "{\n  \"_id\": \"" ++ v6_asset_id ++ "\",\n  \"width\": 2560,"));

    try environment.expectText("get_media_file_info", "{\"assetId\":\"00000000-0000-4000-8000-000000000000\"}", "Media file 00000000-0000-4000-8000-000000000000 not found.");
}

test "search_media_files filters the media files by name, content type and date" {
    var environment: IToolsTestEnvironment = undefined;
    try environment.init("mcp-search-media-files");
    defer environment.deinit();

    try environment.openDatabase();
    const found =
        \\[
        \\  {
        \\    "_id": "89171cd9-a652-4047-b869-1154bf2c95a1",
        \\    "origFileName": "test.jpg",
        \\    "contentType": "image/jpeg",
        \\    "photoDate": "2025-05-27T09:54:16.000Z",
        \\    "width": 2560,
        \\    "height": 1920,
        \\    "coordinates": {
        \\      "lat": -29.019044444444443,
        \\      "lng": 152.18946666666668
        \\    }
        \\  }
        \\]
    ;
    try environment.expectText("search_media_files", "{}", found);
    try environment.expectText("search_media_files", "{\"query\":\"TEST\",\"contentType\":\"IMAGE/\",\"dateFrom\":\"2025-05-27\",\"dateTo\":\"2025-05-28\"}", found);
    try environment.expectText("search_media_files", "{\"query\":\"nothing-matches\"}", "[]");
    try environment.expectText("search_media_files", "{\"contentType\":\"video/\"}", "[]");
    try environment.expectText("search_media_files", "{\"dateFrom\":\"2025-05-28\"}", "[]");
}

test "save_media_file writes the original, display or thumbnail file of a media file" {
    var environment: IToolsTestEnvironment = undefined;
    try environment.init("mcp-save-media-file");
    defer environment.deinit();
    const allocator = environment.arena.allocator();

    try environment.openDatabase();
    const escapedRoot = try std.mem.replaceOwned(u8, allocator, environment.root, "\\", "\\\\");
    const kinds = [_][]const u8{ "original", "display", "thumb" };
    const storagePrefixes = [_][]const u8{ "asset", "display", "thumb" };
    const sizes = [_]usize{ 2049800, 696014, 130591 };
    for (kinds, storagePrefixes, sizes) |kind, storagePrefix, size| {
        const outputPath = try std.fmt.allocPrint(allocator, "{s}/out/{s}/file.bin", .{ environment.root, kind });
        try environment.expectText(
            "save_media_file",
            try std.fmt.allocPrint(allocator, "{{\"assetId\":\"{s}\",\"outputPath\":\"{s}/out/{s}/file.bin\",\"type\":\"{s}\"}}", .{ v6_asset_id, escapedRoot, kind, kind }),
            try std.fmt.allocPrint(allocator, "Wrote {d} bytes to {s}", .{ size, outputPath }),
        );
        const written = try std.Io.Dir.cwd().readFileAlloc(io, outputPath, allocator, .unlimited);
        const stored = try std.Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(allocator, "{s}/db/{s}/{s}", .{ environment.root, storagePrefix, v6_asset_id }), allocator, .unlimited);
        try std.testing.expectEqualSlices(u8, stored, written);
    }

    // The type defaults to the original.
    try environment.expectText(
        "save_media_file",
        try std.fmt.allocPrint(allocator, "{{\"assetId\":\"{s}\",\"outputPath\":\"{s}/default.bin\"}}", .{ v6_asset_id, escapedRoot }),
        try std.fmt.allocPrint(allocator, "Wrote 2049800 bytes to {s}/default.bin", .{environment.root}),
    );

    // A media file that is not stored fails the tool.
    const missing = try environment.call("save_media_file", try std.fmt.allocPrint(allocator, "{{\"assetId\":\"missing\",\"outputPath\":\"{s}/missing.bin\"}}", .{escapedRoot}));
    try std.testing.expect(missing.isError);
}

test "verify_database verifies the files of the open database" {
    var environment: IToolsTestEnvironment = undefined;
    try environment.init("mcp-verify-database");
    defer environment.deinit();

    try environment.openDatabase();
    try environment.expectText("verify_database", "{}",
        \\{
        \\  "databaseFiles": {
        \\    "totalFiles": 8,
        \\    "totalSize": 363161,
        \\    "validFiles": 8,
        \\    "invalidFiles": [],
        \\    "errors": []
        \\  },
        \\  "assets": {
        \\    "totalImports": 1,
        \\    "totalFiles": 4,
        \\    "totalSize": 2877318,
        \\    "numUnmodified": 4,
        \\    "numFailures": 0,
        \\    "modified": [],
        \\    "new": [],
        \\    "removed": [],
        \\    "filesProcessed": 4,
        \\    "nodesProcessed": 7,
        \\    "recordMismatches": []
        \\  }
        \\}
    );
}

test "import_media_files imports files into the open database, or previews the import" {
    var environment: IToolsTestEnvironment = undefined;
    try environment.init("mcp-import-media-files");
    defer environment.deinit();

    try environment.openDatabase();
    const added =
        \\{
        \\  "filesAdded": 1,
        \\  "filesAlreadyAdded": 0,
        \\  "filesIgnored": 0,
        \\  "filesFailed": 0,
        \\  "filesProcessed": 1,
        \\  "totalSize": 0,
        \\  "averageSize": 0
        \\}
    ;
    try environment.expectText("import_media_files", "{\"paths\":[\"../../test/test.png\"],\"dryRun\":true}", added);
    try std.testing.expectEqual(@as(usize, 1), try countMediaFiles(&environment));

    try environment.expectText("import_media_files", "{\"paths\":[\"../../test/test.png\"]}", added);

    // The import is written by the worker pool, so the database is opened again to read what it wrote.
    try environment.openDatabase();
    try std.testing.expectEqual(@as(usize, 2), try countMediaFiles(&environment));

    try environment.expectText("import_media_files", "{\"paths\":[\"../../test/test.png\"]}",
        \\{
        \\  "filesAdded": 0,
        \\  "filesAlreadyAdded": 1,
        \\  "filesIgnored": 0,
        \\  "filesFailed": 0,
        \\  "filesProcessed": 1,
        \\  "totalSize": 0,
        \\  "averageSize": 0
        \\}
    );
}

//
// The number of media files list_media_files lists.
//
fn countMediaFiles(environment: *IToolsTestEnvironment) !usize {
    const allocator = environment.arena.allocator();
    const result = try environment.call("list_media_files", "{\"limit\":200}");
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, allocator, result.text, .{});
    return parsed.object.get("mediaFiles").?.array.items.len;
}
