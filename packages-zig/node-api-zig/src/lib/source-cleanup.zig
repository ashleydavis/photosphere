//
// Source cleanup moved into `packages/api` so the mobile frontend can reach it. See the comment in
// `media-source.ts` beside this file for why. It deletes through the IMediaSource it is handed, so
// nothing in it was Node-specific either.
// (Zig: `export *` is written out one declaration at a time.)
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
