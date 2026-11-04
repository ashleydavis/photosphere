const std = @import("std");
const Timers = @import("ziggy").timers.Timers;
const utils = @import("utils-zig");
const task_queue_zig = @import("ziggy").task_queue;
const api = @import("api-zig");
const media_file_database = @import("media-file-database.zig");
const database_base_dir = @import("database-base-dir.zig");
const create_database_worker = @import("create-database.worker.zig");
const config_worker = @import("config.worker.zig");
const databases_config = @import("databases-config.zig");
const errors = utils.errors;
const ITaskContext = task_queue_zig.types.ITaskContext;
const DEFAULT_DATABASE_DISPLAY_NAME = api.auto_import_mobile.DEFAULT_DATABASE_DISPLAY_NAME;
const autoImportSettingsToJson = api.auto_import_settings.autoImportSettingsToJson;
const checkDatabaseExists = media_file_database.checkDatabaseExists;
const createDatabaseHandler = create_database_worker.createDatabaseHandler;
const readConfigFromStorage = config_worker.readConfigFromStorage;
const writeConfigHandler = config_worker.writeConfigHandler;
const IDatabasesConfig = databases_config.IDatabasesConfig;

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
// The task data gives the path of config.yaml. databases.toml is found in the Photosphere data
// directory on every platform and is changed under the same lock as every other edit of it.
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
pub const IDatabaseOpenedEvent = struct {
    // Names this message among all the messages tasks send ("database-opened").
    type: []const u8,

    // The database to open.
    databasePath: []const u8,
};

//
// The databases.toml mutator of the create-default-database task: lists the default database unless
// an entry already has its exact path.
//
// The check and the append happen together under the file's lock, so two passes recording the same
// database at once list it once. A different database already named DEFAULT_DATABASE_DISPLAY_NAME
// is refused with an error naming it, as addDatabaseEntry refuses it, because the name is how a
// database is looked up and two entries sharing it would make one of them unreachable.
//
const ListDefaultDatabaseMutator = struct {
    // The path of the default database.
    databasePath: []const u8,

    //
    // Appends the default database's entry when no entry has its path.
    //
    pub fn run(self: *const ListDefaultDatabaseMutator, allocator: std.mem.Allocator, config: IDatabasesConfig) !IDatabasesConfig {
        for (config.databases) |entry| {
            if (std.mem.eql(u8, entry.path, self.databasePath)) {
                return config;
            }
        }
        for (config.databases) |entry| {
            if (databases_config.namesMatch(entry.name, DEFAULT_DATABASE_DISPLAY_NAME)) {
                return errors.throwError("A database named \"{s}\" already exists at {s}, so the default database at {s} cannot be listed under that name.", .{
                    DEFAULT_DATABASE_DISPLAY_NAME,
                    entry.path,
                    self.databasePath,
                });
            }
        }
        var databases: std.ArrayList(databases_config.IDatabaseEntry) = .empty;
        try databases.appendSlice(allocator, config.databases);
        try databases.append(allocator, .{
            .name = DEFAULT_DATABASE_DISPLAY_NAME,
            .description = "",
            .path = self.databasePath,
        });
        var updated = config;
        updated.databases = databases.items;
        return updated;
    }
};

//
// Handler for the create-default-database task.
// (Zig: the task data is a JSON value holding ICreateDefaultDatabaseData, and the task returns no value, so the handler
// returns JSON null. The handlers it calls take and give JSON values, so the data for each is built as one.)
//
pub fn createDefaultDatabaseHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    timers: Timers,
    log: utils.log.ILog,
    taskData: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    // (Zig: reading the task data into the typed struct fails when a key holds the wrong type.
    // The failure is reported as a sentence, not a bare parser error name.)
    const data = std.json.parseFromValueLeaky(ICreateDefaultDatabaseData, allocator, taskData, .{
        .ignore_unknown_fields = true,
    }) catch {
        return errors.throwError("The create-default-database task data is not valid: databasePath and configPath must be strings and open must be a boolean", .{});
    };
    if (data.databasePath.len == 0) {
        return errors.throwError("databasePath is required", .{});
    }
    if (data.configPath.len == 0) {
        return errors.throwError("configPath is required", .{});
    }

    // Only made when it is not there. A pass that was killed between making the database and
    // recording it leaves one behind, and create-database refuses a directory that already holds a
    // database, so without this the next pass would fail on it and every pass after that.
    if (!try checkDatabaseExists(allocator, io, log, try database_base_dir.taskDatabaseBaseDir(allocator, taskData), data.databasePath, context.nativeCaller)) {
        var createData: std.json.ObjectMap = .empty;
        try createData.put(allocator, "databasePath", .{
            .string = data.databasePath,
        });
        _ = try createDatabaseHandler(allocator, io, timers, log, .{
            .object = createData,
        }, context);
    }

    const configRead = try readConfigFromStorage(allocator, io, log, data.configPath);
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
    _ = try writeConfigHandler(allocator, io, timers, log, .{
        .object = writeConfigData,
    }, context);

    const listMutator: ListDefaultDatabaseMutator = .{
        .databasePath = data.databasePath,
    };
    try databases_config.updateDatabasesConfig(allocator, io, &listMutator);

    // Said last, so the interface is told to open a database that is made, recorded and listed.
    if (data.open) {
        const openedMessage: IDatabaseOpenedEvent = .{
            .type = "database-opened",
            .databasePath = data.databasePath,
        };
        const text = try std.json.Stringify.valueAlloc(allocator, openedMessage, .{});
        context.sendEvent(io, allocator, log, try std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{}));
    }
    return .null;
}
