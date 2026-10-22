//
// Photosphere's Windows native app: what is Photosphere's own (its name, its window and its page) on top of Ziggy's
// native app. The page is embedded in the executable by build.zig.
//

const std = @import("std");
const shell = @import("ziggy-native-windows");

//
// Runs the native app with Photosphere's name, window size and embedded page, and returns the exit code.
//
pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    return try shell.run(.{
        .app_id = "au.com.codecapers.photosphere",
        .title = "Photosphere",
        .default_width = 1200,
        .default_height = 800,
        .icon_resource = 2,
    }, args);
}
