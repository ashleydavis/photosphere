//
// Source cleanup lives in `packages/api` so the mobile frontend can reach it. It deletes through the
// IMediaSource it is handed, so nothing in it is Node-specific.
// Each declaration is re-exported one at a time.
//

const api = @import("api-zig");

//
// What a cleanup run did.
//
pub const ISourceCleanupResult = api.source_cleanup.ISourceCleanupResult;

//
// Deletes the named source items in batches.
//
pub const runSourceCleanup = api.source_cleanup.runSourceCleanup;
