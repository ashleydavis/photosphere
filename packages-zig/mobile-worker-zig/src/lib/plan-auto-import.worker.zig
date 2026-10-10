const std = @import("std");
const task_queue_zig = @import("task-queue-zig");
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const ITaskContext = task_queue_zig.types.ITaskContext;
const IJobTag = task_queue_zig.types.IJobTag;
const planMobileAutoImport = api.auto_import_mobile.planMobileAutoImport;
const autoImportSettingsToJson = api.auto_import_settings.autoImportSettingsToJson;
const readConfigFromStorage = node_api.config_worker.readConfigFromStorage;

//
// The task that decides what a background automatic import pass should do.
//
// The native background import (the Android foreground service, and the iOS driver) has to know
// whether automatic import is switched on, which database it writes to, and what it watches. It asks
// this task rather than reading the settings file itself, so the file format is defined and parsed in
// exactly one place rather than once per platform in a native language.
//
// It hands back the tasks a pass has to run, ready to queue, rather than the pieces a caller would
// assemble them from. Native code then forwards each one unchanged and never builds a task payload
// of its own, so what a pass does is decided and tested here, and the two platforms cannot drift
// apart by assembling it differently.
//
// The deciding is planMobileAutoImport, which the app itself uses, so the service and the interface
// cannot disagree about whether automatic import is running.
//
// (Zig: the task data and output are JSON values holding the data and result described below, and the settings and the
// data of a step are std.json.Value, because the settings hold their sources as a tagged union and a step's data is any
// object.)
//

//
// One task a pass runs, in the order it is given.
//
pub const IAutoImportPassStep = struct {
    // The task type to queue.
    @"type": []const u8,

    // The input data to queue it with.
    data: std.json.Value,
};

//
// The outputs of the plan-auto-import task: what a pass should do right now.
//
pub const IPlanAutoImportResult = struct {
    // Whether a pass should run at all. False stops the background import.
    shouldRun: bool,

    // The sandbox-relative path of the database a pass imports into.
    databasePath: []const u8,

    // True when no default database has been chosen yet, so the path above is where a new one goes
    // and the steps below start by creating it.
    isNewDefault: bool,

    // The settings a pass runs with.
    settings: std.json.Value,

    // How long to wait after a pass finishes before starting the next one, in milliseconds (a number value).
    pauseBetweenRunsMs: std.json.Value,

    // The tasks the pass runs, in order. Empty when shouldRun is false.
    steps: []const IAutoImportPassStep,
};

//
// The data of the create-default-database step.
//
const ICreateDefaultDatabaseStepData = struct {
    // The sandbox-relative path of the database to create.
    databasePath: []const u8,

    // The sandbox-relative path of config.yaml.
    configPath: []const u8,

    // The sandbox-relative path of databases.toml.
    databasesConfigPath: []const u8,

    // Whether the database is also opened on screen.
    open: bool,
};

//
// Where the import step imports into.
//
const IImportStepStorageDescriptor = struct {
    // The sandbox-relative path of the database.
    databasePath: []const u8,
};

//
// The data of the import-assets step.
// (The options are a std.json.Value because they spread the settings.)
//
const IImportAssetsStepData = struct {
    // The paths to import, none because the sources are scanned.
    paths: []const []const u8,

    // Where the import goes.
    storageDescriptor: IImportStepStorageDescriptor,

    // The id of the import session.
    sessionId: []const u8,

    // Whether the import only reports what it would do.
    dryRun: bool,

    // The options of the import: that it is automatic, and the settings.
    options: std.json.Value,

    // The job the import is shown as.
    job: IJobTag,
};

//
// Turns a value std.json can write into the std.json.Value it is written as.
//
fn toJsonValue(allocator: std.mem.Allocator, value: anytype) !std.json.Value {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{
        .emit_null_optional_fields = false,
    });
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// Handler for the plan-auto-import task.
// (Zig: the input data may name the app's data directory, in appDataPath. The config file and the databases file are named by
// their absolute paths in the app's config directory, because the working directory of the program is not the app's data
// directory.)
//
pub fn planAutoImportHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    data: std.json.Value,
    context: ITaskContext,
) anyerror!std.json.Value {
    const read = try readConfigFromStorage(allocator, io, try node_api.config_file.getConfigPath(allocator));
    const contents = read.config.autoImport;
    var plan = try planMobileAutoImport(allocator, try autoImportSettingsToJson(allocator, contents.settings), contents.defaultDatabasePath);
    // Where the default database is made is a folder of the app's data directory when the caller names one. A caller whose working
    // directory is not the app's data directory has to, because a relative path would be made wherever that is.
    if (plan.isNewDefault) {
        if (data == .object) {
            if (data.object.get("appDataPath")) |appDataPath| {
                if (appDataPath == .string) {
                    plan.databasePath = try node_api.auto_import_desktop.getDefaultDatabasePath(allocator, appDataPath.string);
                }
            }
        }
    }

    var steps: std.ArrayList(IAutoImportPassStep) = .empty;

    if (plan.shouldRun) {
        if (plan.isNewDefault) {
            // Made and recorded before the import rather than after, because an import that fails
            // must not leave the next pass creating the database a second time on top of the one
            // that is already there. The same task the desktop app runs to make this database.
            try steps.append(allocator, .{
                .@"type" = "create-default-database",
                .data = try toJsonValue(allocator, ICreateDefaultDatabaseStepData{
                    .databasePath = plan.databasePath,
                    .configPath = try node_api.config_file.getConfigPath(allocator),
                    .databasesConfigPath = try node_api.databases_config.getDatabasesConfigPath(allocator),

                    // The user switched automatic import on and photos are about to start arriving
                    // in this database, so it is the one they should be looking at.
                    .open = true,
                }),
            });
        }

        // The options of the import: that it is automatic, then the settings (`{ auto: true, ...plan.settings }`).
        var options: std.json.ObjectMap = .empty;
        try options.put(allocator, "auto", .{
            .bool = true,
        });
        var settingsIterator = (try autoImportSettingsToJson(allocator, plan.settings)).object.iterator();
        while (settingsIterator.next()) |entry| {
            try options.put(allocator, entry.key_ptr.*, entry.value_ptr.*);
        }

        // One import task per pass, the same kind of task a manual import runs. It reads its sources
        // to the end and finishes, which is what makes a pass a pass: the loop above it decides when
        // the next one starts.
        try steps.append(allocator, .{
            .@"type" = "import-assets",
            .data = try toJsonValue(allocator, IImportAssetsStepData{
                .paths = &.{},
                .storageDescriptor = .{
                    .databasePath = plan.databasePath,
                },
                .sessionId = try context.uuidGenerator.generate(allocator, io),
                .dryRun = false,
                .options = .{
                    .object = options,
                },
                // Named here rather than in native code, so a phone's row reads the same as a
                // desktop's. No cancel source: the pass is queued by the native driver under a
                // source of its own that the WebView never learns, and automatic import is switched
                // off from Settings.
                .job = .{
                    .id = try std.fmt.allocPrint(allocator, "auto-import:{s}", .{plan.databasePath}),
                    .name = "Automatic import",
                },
            }),
        });
    }

    return toJsonValue(allocator, IPlanAutoImportResult{
        .shouldRun = plan.shouldRun,
        .databasePath = plan.databasePath,
        .isNewDefault = plan.isNewDefault,
        .settings = try autoImportSettingsToJson(allocator, plan.settings),
        .pauseBetweenRunsMs = contents.pauseBetweenRunsMs,
        .steps = steps.items,
    });
}
