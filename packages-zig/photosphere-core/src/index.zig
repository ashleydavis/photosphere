//
// Photosphere's part of the Zig core: its channel handlers and task handlers. The app's own core package imports this module and
// hands what it exports to Ziggy's core.
//

pub const handlers = @import("lib/handlers.zig");
