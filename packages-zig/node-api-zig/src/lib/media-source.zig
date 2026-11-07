//
// The media source abstraction moved into `packages/api` so the mobile frontend can reach it.
//
// Automatic import on a phone is driven from the WebView rather than from a worker (the embedded
// engine pool has three slots, and a long-running orchestrator task in one of them starves the
// tasks it queues), and the WebView cannot import a Node package. Nothing in the abstraction was
// ever Node-specific: it is types and one error class.
//
// Re-exported from here because on this side of the codebase it is a node-api concept, and every
// caller and the node-api barrel already name it that way.
// (Zig: `export *` is written out one declaration at a time.)
//

const api = @import("api-zig");

//
// One photo or video a source can offer.
//
pub const IMediaItem = api.media_source.IMediaItem;

//
// One page of a source listing.
//
pub const IMediaSourceListPage = api.media_source.IMediaSourceListPage;

//
// Somewhere media arrives.
//
pub const IMediaSource = api.media_source.IMediaSource;

//
// Raised when a source could not delete some of the items it was asked to.
//
pub const MediaSourceDeleteError = api.media_source.MediaSourceDeleteError;
