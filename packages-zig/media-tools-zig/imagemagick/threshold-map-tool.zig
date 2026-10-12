const std = @import("std");
const threshold_map = @import("threshold-map");

//
// A program the build runs on the machine doing the building: `threshold-map-tool <thresholds.xml> <threshold-map.h>` reads
// ImageMagick's config/thresholds.xml and writes the header MagickCore/threshold.c includes (see threshold-map.zig).
//
pub fn main(init: std.process.Init) !void {
    const arguments = try init.minimal.args.toSlice(init.arena.allocator());
    if (arguments.len != 3) {
        return error.WrongNumberOfArguments;
    }
    const allocator = init.arena.allocator();
    const thresholds_xml = try std.Io.Dir.cwd().readFileAlloc(init.io, arguments[1], allocator, .limited(1024 * 1024));
    const header = try threshold_map.buildThresholdMap(allocator, thresholds_xml);
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = arguments[2],
        .data = header,
    });
}
