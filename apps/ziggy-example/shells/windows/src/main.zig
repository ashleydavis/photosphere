//
// The Ziggy example's Windows shell: what is the example's own (its name, its window and its page) on top of Ziggy's shell.
// The page is embedded in the executable by build.zig.
//

const std = @import("std");
const shell = @import("ziggy-shell-windows");
const ui = @import("ui-files");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return try shell.run(.{
        .app_id = "dev.ziggy.example",
        .title = "Ziggy example",
        .default_width = 900,
        .default_height = 800,
        .ui_files = &ui.files,
    }, args);
}
