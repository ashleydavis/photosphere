//
// Photosphere's part of the Zig core: its message handlers, its task handlers and the state the main process keeps. The app's backend
// source file (apps/photosphere/core/src/app.zig) imports this module and registers what it exports with Ziggy's core, and the tests
// import it to reach each part.
//

pub const background_work = @import("lib/background-work.zig");
pub const config_and_state = @import("lib/config-and-state.zig");
pub const databases = @import("lib/databases.zig");
pub const describe_error = @import("lib/describe-error.zig");
pub const environment = @import("lib/environment.zig");
pub const events = @import("lib/events.zig");
pub const file_logger = @import("lib/file-logger.zig");
pub const logging = @import("lib/logging.zig");
pub const macos_host = @import("lib/macos-host.zig");
pub const main_process = @import("lib/main-process.zig");
pub const main_state = @import("lib/main-state.zig");
pub const mcp_server = @import("lib/mcp-server.zig");
pub const menu = @import("lib/menu.zig");
pub const mobile_planning = @import("lib/mobile-planning.zig");
pub const mobile_requests = @import("lib/mobile-requests.zig");
pub const page_query = @import("lib/page-query.zig");
pub const pickers = @import("lib/pickers.zig");
pub const recents = @import("lib/recents.zig");
pub const saving_assets = @import("lib/saving-assets.zig");
pub const share_import = @import("lib/share-import.zig");
pub const single_instance = @import("lib/single-instance.zig");
pub const tools = @import("lib/tools.zig");
pub const update_and_news = @import("lib/update-and-news.zig");
pub const vault = @import("lib/vault.zig");
pub const windows_host = @import("lib/windows-host.zig");
