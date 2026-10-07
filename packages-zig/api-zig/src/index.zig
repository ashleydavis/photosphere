pub const constants = @import("lib/constants.zig");
pub const database_config = @import("lib/database-config.zig");
pub const database_descriptor = @import("lib/database-descriptor.zig");
pub const database_state = @import("lib/database-state.zig");
pub const replicate_database_types = @import("lib/replicate-database.types.zig");
pub const write_lock = @import("lib/write-lock.zig");
pub const auto_import_settings = @import("lib/auto-import-settings.zig");
pub const media_source = @import("lib/media-source.zig");
pub const auto_import_queue = @import("lib/auto-import-queue.zig");
pub const source_cleanup = @import("lib/source-cleanup.zig");
pub const import_record = @import("lib/import-record.zig");
pub const import_assets_types = @import("lib/import-assets.types.zig");
pub const sync_database_types = @import("lib/sync-database.types.zig");
pub const lan_share = @import("lib/lan-share/index.zig");
pub const lan_share_resolve = @import("lib/lan-share/lan-share-resolve.zig");
pub const lan_share_receive = @import("lib/lan-share/lan-share-receive.zig");
pub const asset_query = @import("lib/asset-query.zig");
pub const sync_settings = @import("lib/sync-settings.zig");
pub const auto_import_mobile = @import("lib/auto-import-mobile.zig");

// Not ported: database-update, load-assets, save-assets.types, asset, op, database-op,
// database-op-record, retention-policy, sync-gate (not reached by the CLI). auto-import-mobile is ported only as far
// as the config file needs (IAutoImportFile and the pacing); its planner is not.
// IAsset (asset.ts) is only used as a type parameter of IBsonCollection<IAsset>; Zig records are BSON documents.
