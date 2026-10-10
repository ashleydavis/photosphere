const std = @import("std");
const utils = @import("utils-zig");
const task_queue_zig = @import("task-queue-zig");
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const create_database_worker = @import("create-database.worker.zig");
const config_worker = @import("config.worker.zig");
const databases_config_worker = @import("databases-config.worker.zig");
const errors = utils.errors;
const ITaskContext = task_queue_zig.types.ITaskContext;
const DEFAULT_DATABASE_DISPLAY_NAME = api.auto_import_mobile.DEFAULT_DATABASE_DISPLAY_NAME;
const autoImportSettingsToJson = api.auto_import_settings.autoImportSettingsToJson;
const checkDatabaseExists = media_file_database.checkDatabaseExists;
const createDatabaseHandler = create_database_worker.createDatabaseHandler;
const readConfigFromStorage = config_worker.readConfigFromStorage;
const writeConfigHandler = config_worker.writeConfigHandler;
const readDatabasesConfigHandler = databases_config_worker.readDatabasesConfigHandler;
const writeDatabasesConfigHandler = databases_config_worker.writeDatabasesConfigHandler;

//
// The task that creates the default private photo database and records it.
//
// This is what switching automatic import on does before it imports anything: the user has asked for
// somewhere to put their photos and has not chosen it, so the app makes it. It creates the database,
// writes its path into the automatic import section of config.yaml, and adds it to databases.toml,
// which is what makes it appear in the app's database list.
//
// All three in one task because they have to happen together: a database recorded as the default but
// missing from the list is one the user cannot open, and a database that exists but is recorded
// nowhere is created again on the next pass, on top of the one that is already there.
//
// Every platform runs this same task, so the default database comes to exist one way rather than one
// way per platform. On a phone the background import's pass queues it, and neither file it writes is
// reachable from the WebView or from native code; on the desktop the main process queues it on the
// worker pool.
//
// The two files are named by the caller, because they sit in different places: at the root of the
// app's storage sandbox on a phone, in the config directory on the desktop.
//
// create-database is left alone and still creates a database on its own: that is the one the user
// makes themselves, which is not the default and is recorded by the interface that asked for it.
//

//
// Input for the create-default-database task.
// (Zig: the `= ""` and `= false` defaults let std.json parse data that leaves keys out; the handler refuses the paths
// that are missing.)
//
pub const ICreateDefaultDatabaseData = struct {
    // The path to create the database at.
    databasePath: []const u8 = "",

    // The path of config.yaml, which is told which database automatic import writes to.
    configPath: []const u8 = "",

    // The path of databases.toml, which the database is added to so it appears in the list.
    databasesConfigPath: []const u8 = "",

    // Whether the app should open this database once it exists.
    //
    // Whoever asks for the database says here whether it is also being asked for on screen, so a
    // database made because the user switched automatic import on is the one the user ends up
    // looking at. The task says so by sending the message below; opening it is the interface's.
    open: bool = false,
};

//
// The message the task sends when it has made a database that was asked for on screen.
//
// A task message rather than anything platform-specific, because a task message is the one way a
// task reaches the interface that works the same everywhere: the desktop shell forwards it
// to the page, and the native plugin emits it to the WebView. So the interface has one thing to
// listen to and neither platform needs an opener of its own.
// (Zig: the `type` is the string "database-opened".)
//
pub const IDatabaseOpenedMessage = struct {
    // Names this message among all the messages tasks send ("database-opened").
    type: []const u8,

    // The database to open.
    databasePath: []const u8,
};

//
// Handler for the create-default-database task.
// (Zig: the task data is a JSON value holding ICreateDefaultDatabaseData, and the task returns no value, so the handler
// returns JSON null. The handlers it calls take and give JSON values, so the data for each is built as one.)
//
pub fn createDefaultDatabaseHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    // (Zig: reading the task data into the typed struct fails when a key holds the wrong type.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(ICreateDefaultDatabaseData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The create-default-database task data is not valid: databasePath, configPath and databasesConfigPath must be strings and open must be a boolean", .{});
    };
    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }
    if (data.configPath.len == 0) {
        return errors.throwError("configPath is required", .{});
    }
    if (data.databasesConfigPath.len == 0) {
        return errors.throwError("databasesConfigPath is required", .{});
    }

    // Only made when it is not there. A pass that was killed between making the database and
    // recording it leaves one behind, and create-database refuses a directory that already holds a
    // database, so without this the next pass would fail on it and every pass after that.
    if (!try checkDatabaseExists(allocator, io, data.databasePath, context.hostRequester)) {
        var createData: std.json.ObjectMap = .empty;
        try createData.put(allocator, "databasePath", .{
            .string = data.databasePath,
        });
        _ = try createDatabaseHandler(allocator, io, .{
            .object = createData,
        }, context);
    }

    const configRead = try readConfigFromStorage(allocator, io, data.configPath);
    const autoImportFile = configRead.config.autoImport;
    // Only the automatic import section is sent, so the syncing settings in the same file are left
    // exactly as they were.
    var autoImportData: std.json.ObjectMap = .empty;
    try autoImportData.put(allocator, "settings", try autoImportSettingsToJson(allocator, autoImportFile.settings));
    try autoImportData.put(allocator, "defaultDatabasePath", .{
        .string = data.databasePath,
    });
    try autoImportData.put(allocator, "pauseBetweenRunsMs", autoImportFile.pauseBetweenRunsMs);
    var writeConfigData: std.json.ObjectMap = .empty;
    try writeConfigData.put(allocator, "configPath", .{
        .string = data.configPath,
    });
    try writeConfigData.put(allocator, "autoImport", .{
        .object = autoImportData,
    });
    _ = try writeConfigHandler(allocator, io, .{
        .object = writeConfigData,
    }, context);

    var readDatabasesData: std.json.ObjectMap = .empty;
    try readDatabasesData.put(allocator, "configPath", .{
        .string = data.databasesConfigPath,
    });
    const databasesConfig = (try readDatabasesConfigHandler(allocator, io, .{
        .object = readDatabasesData,
    }, context)).object;
    const existingDatabases = databasesConfig.get("databases").?.array.items;
    var alreadyListed = false;
    for (existingDatabases) |entry| {
        if (std.mem.eql(u8, entry.object.get("path").?.string, data.databasePath)) {
            alreadyListed = true;
            break;
        }
    }
    if (!alreadyListed) {
        var databases: std.json.Array = .init(allocator);
        try databases.appendSlice(existingDatabases);
        var newEntry: std.json.ObjectMap = .empty;
        try newEntry.put(allocator, "name", .{
            .string = DEFAULT_DATABASE_DISPLAY_NAME,
        });
        try newEntry.put(allocator, "description", .{
            .string = "",
        });
        try newEntry.put(allocator, "path", .{
            .string = data.databasePath,
        });
        try databases.append(.{
            .object = newEntry,
        });

        var writeDatabasesData: std.json.ObjectMap = .empty;
        try writeDatabasesData.put(allocator, "configPath", .{
            .string = data.databasesConfigPath,
        });
        try writeDatabasesData.put(allocator, "databases", .{
            .array = databases,
        });
        try writeDatabasesData.put(allocator, "recentDatabaseNames", databasesConfig.get("recentDatabaseNames").?);

        // Carried through rather than dropped: this rewrites the whole file to add one entry, and
        // writing undefined here would close the database the user had open.
        if (databasesConfig.get("lastDatabase")) |lastDatabase| {
            try writeDatabasesData.put(allocator, "lastDatabase", lastDatabase);
        }
        _ = try writeDatabasesConfigHandler(allocator, io, .{
            .object = writeDatabasesData,
        }, context);
    }

    // Said last, so the interface is told to open a database that is made, recorded and listed.
    if (data.open) {
        const openedMessage: IDatabaseOpenedMessage = .{
            .type = "database-opened",
            .databasePath = data.databasePath,
        };
        const text = try std.json.Stringify.valueAlloc(allocator, openedMessage, .{});
        context.sendMessage(try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}));
    }
    return .null;
}
