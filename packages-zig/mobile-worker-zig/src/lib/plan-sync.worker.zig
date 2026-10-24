const std = @import("std");
const Timers = @import("ziggy").timers.Timers;
const task_queue_zig = @import("ziggy").task_queue;
const api = @import("api-zig");
const node_api = @import("node-api-zig");
const network_status = @import("../shims/network-status.zig");
const ITaskContext = task_queue_zig.types.ITaskContext;
const IJobTag = task_queue_zig.types.IJobTag;
const ISyncSettings = api.sync_settings.ISyncSettings;
const computeSyncAllowed = api.sync_gate.computeSyncAllowed;
const loadDatabaseConfig = api.database_config.loadDatabaseConfig;
const readConfigFromStorage = node_api.config_worker.readConfigFromStorage;
const openStorage = node_api.open_storage.openStorage;
const INetworkStatusHost = network_status.INetworkStatusHost;
const readNetworkConnectionType = network_status.readNetworkConnectionType;

//
// The task that decides whether a background sync pass should run, and against which database.
//
// The native background sync (the Android foreground service's loop, and the iOS driver) has to know
// whether syncing is switched on, whether this connection is one it may use, and which database has
// a remote to push to. It asks this task rather than reading the settings file itself, so the file
// format is defined and parsed in exactly one place rather than once per platform in a native
// language.
//
// It hands back the task a pass has to run, ready to queue, rather than the pieces a caller would
// assemble it from. Native code then forwards it unchanged and never builds a task payload of its
// own, so what a pass does is decided and tested here, and the two platforms cannot drift apart by
// assembling it differently. The same division as plan-auto-import.
//
// The deciding is computeSyncAllowed, which the app's own interface uses, so the background loop and
// the interface cannot disagree about whether an automatic sync is permitted. A second copy of that
// rule would be a second thing to keep in step, and the failure when they drift is somebody's mobile
// data bill.
//
// (Zig: the task data and output are JSON values holding the data and result described below. The connection type comes
// from the host the caller passes in; see network-status.zig.)
//

//
// What the native prefetch loop's last pass said about the replica, as it arrives here.
//
// The native side reports the fact and this task decides what it means, which is the same division as
// the connection type: the platform says "wifi" or "cellular" and computeSyncAllowed decides. Only
// "working" holds a sync back, because the question is whether the prefetch is making progress rather
// than whether it has finished: a sync that waited for a prefetch that cannot finish would be a phone
// that has silently stopped backing up, which is worse than the contention it was avoiding.
// (Zig: an enum, whose tag names are the strings.)
//
pub const PrefetchState = enum {
    // Nothing has reported a pass.
    unknown,

    // The prefetch is making progress.
    working,

    // The prefetch is stuck.
    stalled,

    // The prefetch has finished.
    complete,
};

//
// The inputs of the plan-sync task.
// (Zig: the data is read from the JSON value by the handler, because a value this build does not recognise has to be read
// as "unknown" rather than refused as bad data, so this type describes it and is not parsed into.)
//
pub const IPlanSyncData = struct {
    // What the prefetch loop's last pass said about the replica. Absent, or a value this build does
    // not recognise, is read as "unknown" and allows syncing: nothing about a value nobody understood
    // should be able to stop a phone syncing.
    prefetchState: ?PrefetchState = null,
};

//
// One task a pass runs, in the order it is given.
//
pub const ISyncPassStep = struct {
    // The task type to queue.
    @"type": []const u8,

    // The input data to queue it with.
    data: std.json.Value,
};

//
// The outputs of the plan-sync task: what a pass should do right now.
//
pub const IPlanSyncResult = struct {
    // Whether a sync should run at all. False means this pass does nothing; the loop waits and asks
    // again, because every reason to refuse can go away without the app being touched.
    shouldRun: bool,

    // The sandbox-relative path of the database a pass syncs, empty when there is not one.
    databasePath: []const u8,

    // Why a sync is not running, for the log. Empty when one is.
    reason: []const u8,

    // The settings the decision was made with.
    settings: ISyncSettings,

    // How long to wait after a pass finishes before starting the next one, in milliseconds (a number value).
    pauseBetweenRunsMs: std.json.Value,

    // The tasks the pass runs, in order. Empty when shouldRun is false.
    steps: []const ISyncPassStep,
};

//
// The data of the sync-database step.
//
const ISyncStepData = struct {
    // The sandbox-relative path of the database to sync.
    databasePath: []const u8,

    // The job the sync is shown as.
    job: IJobTag,
};

//
// Reads what the native side said about the prefetch from the task data (`data?.prefetchState`).
// A value that is not one of the states is read as none.
//
fn readPrefetchState(data: std.json.Value) ?PrefetchState {
    if (data != .object) {
        return null;
    }
    const reported = data.object.get("prefetchState") orelse {
        return null;
    };
    if (reported != .string) {
        return null;
    }
    return std.meta.stringToEnum(PrefetchState, reported.string);
}

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
fn refuse(reason: []const u8, settings: ISyncSettings, pauseBetweenRunsMs: std.json.Value) IPlanSyncResult {
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
// Handler for the plan-sync task.
// (Zig: the context's host requester goes to openStorage. The host is how the platform is asked for the connection type.)
//
pub fn planSyncHandler(
    allocator: std.mem.Allocator,
    io: std.Io,
    _: Timers,
    data: std.json.Value,
    context: ITaskContext,
    host: INetworkStatusHost,
) anyerror!std.json.Value {
    // One read for both sections. They used to be two files, so resolving which database to push
    // meant opening sync.toml and then auto-import.toml; the merged file costs one read per pass.
    const read = try readConfigFromStorage(allocator, io, try node_api.config_file.getConfigPath(allocator));
    const config = read.config;
    const syncConfig = config.sync;
    const settings = syncConfig.settings;
    const pauseBetweenRunsMs = syncConfig.pauseBetweenRunsMs;

    // The master switch first, and on its own. It is what a user reaches for when they want syncing
    // to stop, so nothing below can get past it and it is not mixed in with anything else.
    if (!settings.enabled) {
        return toJsonValue(allocator, refuse("syncing is switched off", settings, pauseBetweenRunsMs));
    }

    const connectionType = try readNetworkConnectionType(io, allocator, host);

    // The same rule the interface applies, from the same function. "connected" is derived from the
    // connection type rather than asked for separately: the platform reports one thing here, and a
    // type of "none" is what having no connection looks like.
    const allowed = computeSyncAllowed(.{
        .syncEnabled = settings.enabled,
        .syncOnlyOnWifi = settings.onlyOnWifi,
        .connected = connectionType != .none,
        .connectionType = connectionType,
    });

    if (!allowed) {
        return toJsonValue(allocator, refuse(try std.fmt.allocPrint(allocator, "the connection is \"{s}\" and syncing is not allowed on it", .{@tagName(connectionType)}), settings, pauseBetweenRunsMs));
    }

    // After the master switch and the connection, and before the database is resolved, because the
    // reason a user is most likely to care about should win: a phone on cellular is refused for being
    // on cellular rather than for waiting on a prefetch.
    //
    // Only "working" waits. A prefetch that is stuck, one that has finished, and a state nobody has
    // reported yet all let the sync run, because the alternative is a sync that never happens again:
    // measured on a Pixel 6, a prefetch failed and was never retried, and a sync that had waited for
    // it would have waited for the life of the app. Reaching the origin's merkle tree during a pass
    // that overlapped a working prefetch took 81.5 seconds against 97 milliseconds when the phone was
    // idle, and the record merge in that pass took 15 minutes pulling down the same metadata shards
    // the prefetch was fetching, which is what waiting one gap avoids.
    if (readPrefetchState(data) == .working) {
        return toJsonValue(allocator, refuse("a prefetch is still filling this database in", settings, pauseBetweenRunsMs));
    }

    // The database the app last opened, and failing that the one automatic import writes to.
    //
    // The opened one comes first because it is what the user is using, and because syncing
    // must not need automatic import switched on to have anything to push: the two are switched on
    // separately. The import's database is the fallback for a phone that has imported in the
    // background without anybody opening it.
    const autoImportConfig = config.autoImport;
    const recordedPath = syncConfig.databasePath;
    const databasePath = if (recordedPath != null and recordedPath.?.len > 0)
        recordedPath
    else
        autoImportConfig.defaultDatabasePath;
    if (databasePath == null or databasePath.?.len == 0) {
        return toJsonValue(allocator, refuse("no database has been opened to sync", settings, pauseBetweenRunsMs));
    }

    // A database with no origin has nowhere to sync to. The sync task itself would skip it, having
    // paid for an engine slot and a database open to find that out, and it would say so every pass
    // for as long as the phone was switched on.
    const opened = try openStorage(allocator, io, databasePath.?, null, null, context.nativeCaller);
    const databaseConfig = try loadDatabaseConfig(allocator, io, opened.rawStorage);
    if (configOrigin(databaseConfig) == null) {
        return toJsonValue(allocator, refuse(try std.fmt.allocPrint(allocator, "\"{s}\" has no origin to sync to", .{databasePath.?}), settings, pauseBetweenRunsMs));
    }

    return toJsonValue(allocator, IPlanSyncResult{
        .shouldRun = true,
        .databasePath = databasePath.?,
        .reason = "",
        .settings = settings,
        .pauseBetweenRunsMs = pauseBetweenRunsMs,
        .steps = &[_]ISyncPassStep{
            .{
                // One sync task per pass, the same task the app queues when the user asks for a sync
                // and the same one the desktop's timer queues. It works out what to move for itself,
                // and early-outs when both sides already hold the same content.
                .@"type" = "sync-database",
                .data = try toJsonValue(allocator, ISyncStepData{
                    .databasePath = databasePath.?,
                    // Named here rather than natively, so a phone's sync row reads the same as a
                    // desktop's. No cancel source: the pass is queued by the native driver under a
                    // source of its own that the WebView never learns, and syncing is switched off
                    // from Settings rather than stopped from the job list.
                    .job = .{
                        .id = try std.fmt.allocPrint(allocator, "sync:{s}", .{databasePath.?}),
                        .name = "Syncing database",
                    },
                }),
            },
        },
    });
}
