//
// Parsing of the -geometry command line option.
//

const std = @import("std");

//
// What the -geometry option asked for.
//
pub const Geometry = struct {
    // The window width in pixels.
    width: c_int,
    // The window height in pixels.
    height: c_int,
};

//
// Parses the WxH or WxH+X+Y text of the -geometry option (the text after the equals sign). GTK gives a program no say over where
// its window goes, so the position is checked and ignored. Returns null for any other text.
//
pub fn parseGeometry(text: []const u8) ?Geometry {
    const separator = std.mem.indexOfScalar(u8, text, 'x') orelse {
        return null;
    };
    const width = std.fmt.parseInt(c_int, text[0..separator], 10) catch {
        return null;
    };
    const rest = text[separator + 1 ..];
    const height_end = std.mem.indexOfAny(u8, rest, "+-") orelse rest.len;
    const height = std.fmt.parseInt(c_int, rest[0..height_end], 10) catch {
        return null;
    };
    if (height_end < rest.len) {
        const position = rest[height_end..];
        const y_start = std.mem.indexOfAnyPos(u8, position, 1, "+-") orelse {
            return null;
        };
        _ = std.fmt.parseInt(c_int, position[0..y_start], 10) catch {
            return null;
        };
        _ = std.fmt.parseInt(c_int, position[y_start..], 10) catch {
            return null;
        };
    }
    return .{
        .width = width,
        .height = height,
    };
}
