const task_queue_zig = @import("task-queue-zig");
const IJobTag = task_queue_zig.types.IJobTag;

//
// Input data for the replicate-database background task.
// (Task data travels as JSON (std.json.Value); the `= null` defaults let std.json parse data that
// leaves optional keys out, as JSON.stringify does for undefined values.)
//
pub const IReplicateDatabaseData = struct {
    //
    // The source database path. When the path is registered in databases.json its S3 and encryption
    // credentials are resolved from there; otherwise sourceEncryptionKey supplies the key.
    //
    sourcePath: []const u8,

    //
    // Destination database path (filesystem or s3: path).
    //
    destPath: []const u8,

    //
    // Source encryption key: either a file path to a PEM file or the name of a vault secret.
    // Used when the source database is not registered in databases.json (e.g. CLI invocations).
    // Null for unencrypted sources or when credentials come from databases.json.
    //
    sourceEncryptionKey: ?[]const u8 = null,

    //
    // Destination encryption key: either a file path to a PEM file or the name of a vault secret.
    // Null for an unencrypted destination.
    //
    destEncryptionKey: ?[]const u8 = null,

    //
    // Vault secret name of S3 credentials to use when destPath starts with "s3:".
    //
    destS3Key: ?[]const u8 = null,

    //
    // True for partial replication (metadata only), false for full replication (copies every original/display/thumb file).
    //
    partial: bool,

    //
    // True to allow replication when the destination already exists with a different database id.
    //
    force: bool,

    //
    // Optional path filter: only replicate files matching this path (file or directory).
    //
    pathFilter: ?[]const u8 = null,

    //
    // Names the job this task belongs to, so the replication shows up in the interface's job list
    // and can be watched and cancelled after its dialog has been closed.
    //
    job: ?IJobTag = null,
};

//
// Task message sent during replication to forward progress strings to the UI.
//
pub const IReplicateProgressMessage = struct {
    //
    // Message type discriminator (always "replicate-progress").
    //
    type: []const u8,

    //
    // The source database path. Used by the UI to discard messages from a closed or different replication.
    //
    databasePath: []const u8,

    //
    // The human-readable progress string emitted by replicate().
    //
    progress: []const u8,
};
