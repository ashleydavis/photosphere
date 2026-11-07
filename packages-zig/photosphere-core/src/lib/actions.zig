//
// Photosphere's Ziggy actions: named pieces of its functionality that take no arguments, whose handlers are in the page. A menu item,
// a shortcut, the page or the core runs one by its name, and each of them runs the same handler. Photosphere's menu items move here
// one at a time.
//

const ziggy = @import("ziggy");

//
// The actions the Photosphere App passes to ziggy.core.App as `.actions`. Open Database is the File menu's item of that name, and the
// sidebar's Open Database item runs it too.
//
pub const actions: []const ziggy.action.Action = &.{
    .{
        .name = "open-database",
        .label = "Open Database...",
        .shortcut = "CmdOrCtrl+O",
    },
};
