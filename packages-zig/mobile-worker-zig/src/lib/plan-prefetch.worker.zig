const std = @import("std");
const task_queue_zig = @import("ziggy").task_queue;
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const network_status = @import("../shims/network-status.zig");
const ITaskContext = task_queue_zig.types.ITaskContext;
const ISyncSettings = api.sync_settings.ISyncSettings;
const computeSyncAllowed = api.sync_gate.computeSyncAllowed;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const IPrefetchDatabaseData = node_api.prefetch_database_worker.IPrefetchDatabaseData;
const readConfigFromStorage = node_api.config_worker.readConfigFromStorage;
const openStorage = node_api.open_storage.openStorage;
const isDatabasePartial = node_api.media_file_database.isDatabasePartial;
const INetworkStatusHost = network_status.INetworkStatusHost;
const readNetworkConnectionType = network_status.readNetworkConnectionType;

//
// The task that decides whether a background prefetch pass should run, and against which database.
//
// A prefetch fills in a partial replica: it walks the origin's thumbnails and database index files
// and copies down whatever the replica is missing. Until now the only thing that ever queued one was
// the end of a load-assets run, so a prefetch that failed part way was never tried again and the
// replica it was filling in stayed unfinished. A sync cannot repair that, because a sync copies what
// the difference between two merkle trees shows and a partial replica's tree is already identical to
// its origin's: a missing file is invisible to it.
//
// This is the same division of labour as plan-sync and plan-auto-import. The native loop asks what to
// do and forwards the tasks it is handed, so the settings format is parsed in one place and the two
// platforms cannot drift apart by assembling a payload differently.
//
// It obeys the sync settings rather than getting its own. This is network traffic to the origin on
// the user's connection, and a user who switches syncing off means stop using my data for this
// database. Reusing them also means no new configuration key, no wiki change, and one rule to keep in
// step instead of two. The prefetch that load-assets queues is deliberately not made to obey them,
// because that one is the user opening the database in front of them.
//
// (Zig: the task data and output are JSON values holding the data and result described below. The connection type comes
// from the host the caller passes in; see network-status.zig.)
//

//
// One task a pass runs, in the order it is given.
//
pub const IPrefetchPassStep = struct {
    // The task type to queue.
    @"type": []const u8,

    // The input data to queue it with.
    data: std.json.Value,
};

//
// The outputs of the plan-prefetch task: what a pass should do right now.
//
pub const IPrefetchPlanResult = struct {
    // Whether a prefetch should run at all. False means this pass does nothing; the loop waits and
    // asks again, because every reason to refuse can go away without the app being touched.
    shouldRun: bool,

    // The sandbox-relative path of the database a pass fills in, empty when there is not one.
    databasePath: []const u8,

    // Why a prefetch is not running, for the log. Empty when one is.
    reason: []const u8,

    // The settings the decision was made with.
    settings: ISyncSettings,

    // How long to wait after a pass finishes before starting the next one, in milliseconds (a number value).
    pauseBetweenRunsMs: std.json.Value,

    // The tasks the pass runs, in order. Empty when shouldRun is false.
    steps: []const IPrefetchPassStep,
};

//
// Gets `config?.origin` when it is a non-empty string (null otherwise).
//
fn configOrigin(config: ?std.json.Value) ?[]const u8 {
    const value = config orelse {
        return null;
    };
    const object = switch (value) {
        .object => |object| object,
        else => {
            return null;
        },
    };
    const origin = object.get("origin") orelse {
        return null;
    };
    return switch (origin) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

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
// Builds the answer for a pass that is not going to run.
//
// Every refusal comes back with the pacing filled in, because the loop waits that long before asking
// again. A refusal with no gap would have it ask as fast as the engine could answer.
//
fn refuse(reason: []const u8, settings: ISyncSettings, pauseBetweenRunsMs: std.json.Value) IPrefetchPlanResult {
    return .{
        .shouldRun = false,
        .databasePath = "",
        .reason = reason,
        .settings = settings,
        .pauseBetweenRunsMs = pauseBetweenRunsMs,
        .steps = &.{},
    };
}

//
// Handler for the plan-prefetch task.
// (Zig: the input data is ignored, and the context's host requester goes to openStorage. The host is how the platform is
// asked for the connection type.)
//
pub fn planPrefetchHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    data: std.json.Value,
    context: ITaskContext,
    host: INetworkStatusHost,
) anyerror!std.json.Value {
    _ = data;
    const read = try readConfigFromStorage(allocator, io, try node_api.config_file.getConfigPath(allocator));
    const config = read.config;
    const syncConfig = config.sync;
    const settings = syncConfig.settings;
    const pauseBetweenRunsMs = syncConfig.pauseBetweenRunsMs;

    // The master switch first, and on its own, exactly as plan-sync applies it. It is what a user
    // reaches for when they want the app to stop using their connection for this database.
    if (!settings.enabled) {
        return toJsonValue(allocator, refuse("syncing is switched off", settings, pauseBetweenRunsMs));
    }

    const connectionType = try readNetworkConnectionType(allocator, host);

    // The same rule the interface applies, from the same function.
    const allowed = computeSyncAllowed(.{
        .syncEnabled = settings.enabled,
        .syncOnlyOnWifi = settings.onlyOnWifi,
        .connected = connectionType != .none,
        .connectionType = connectionType,
    });

    if (!allowed) {
        return toJsonValue(allocator, refuse(try std.fmt.allocPrint(allocator, "the connection is \"{s}\" and syncing is not allowed on it", .{@tagName(connectionType)}), settings, pauseBetweenRunsMs));
    }

    // The database the app last opened, and failing that the one automatic import writes to. The
    // same resolution plan-sync makes, for the same reasons.
    const autoImportConfig = config.autoImport;
    const recordedPath = syncConfig.databasePath;
    const databasePath = if (recordedPath != null and recordedPath.?.len > 0)
        recordedPath
    else
        autoImportConfig.defaultDatabasePath;
    if (databasePath == null or databasePath.?.len == 0) {
        return toJsonValue(allocator, refuse("no database has been opened to fill in", settings, pauseBetweenRunsMs));
    }

    // A database with no origin has nothing to fetch from.
    const opened = try openStorage(allocator, io, databasePath.?, null, null, context.hostRequester);
    const databaseConfig = try loadDatabaseConfig(allocator, io, opened.rawStorage);
    if (configOrigin(databaseConfig) == null) {
        return toJsonValue(allocator, refuse(try std.fmt.allocPrint(allocator, "\"{s}\" has no origin to fill in from", .{databasePath.?}), settings, pauseBetweenRunsMs));
    }

    // And a full database has nothing missing. The prefetch task itself checks this and returns, but
    // it would pay for an engine slot and a merkle tree load to find out, every pass, for as long as
    // the phone was switched on.
    //
    // The credentials openStorage already resolved go with the question, because reading the merkle
    // tree needs them: without them an encrypted database's .db/files.dat is read as the raw
    // ciphertext it is on disk and the read fails on the serialized checksum, so every pass of the
    // loop threw and the prefetch never ran at all. Measured on a Pixel 6 against an encrypted S3
    // origin, every pass reported "Checksum mismatch: expected <the last 32 bytes of the encrypted
    // file> got <a hash of the rest of it>". `load-assets` passes them at the same call.
    if (!try isDatabasePartial(allocator, io, databasePath.?, opened.s3Config, opened.storageOptions)) {
        return toJsonValue(allocator, refuse(try std.fmt.allocPrint(allocator, "\"{s}\" is not a partial replica, so there is nothing to fill in", .{databasePath.?}), settings, pauseBetweenRunsMs));
    }

    return toJsonValue(allocator, IPrefetchPlanResult{
        .shouldRun = true,
        .databasePath = databasePath.?,
        .reason = "",
        .settings = settings,
        .pauseBetweenRunsMs = pauseBetweenRunsMs,
        .steps = &[_]IPrefetchPassStep{
            .{
                // One prefetch task per pass, the same task load-assets queues when a database is
                // opened. It works out what is missing for itself.
                .@"type" = "prefetch-database",
                .data = try toJsonValue(allocator, IPrefetchDatabaseData{
                    .databasePath = databasePath.?,
                    // Named here rather than natively, so a phone's job row reads the same whatever
                    // queued it. No cancel source: the pass is queued by the native driver under a
                    // source the WebView never learns, and it is switched off from Settings rather
                    // than stopped from the job list.
                    .job = .{
                        .id = try std.fmt.allocPrint(allocator, "prefetch:{s}", .{databasePath.?}),
                        .name = "Filling in this database",
                    },
                }),
            },
        },
    });
}
