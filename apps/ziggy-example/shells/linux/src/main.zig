//
// The Ziggy example's Linux shell: what is the example's own (its name, its window and its page) on top of Ziggy's shell.
//

const std = @import("std");
const shell = @import("ziggy-shell-linux");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return try shell.run(.{
        .app_id = "dev.ziggy.example",
        .title = "Ziggy example",
        .default_width = 900,
        .default_height = 800,
        .inject_script = @embedFile("ziggy-inject"),
        .ui_directory_name = "ui",
    }, args);
}
