//
// Parsing of the -geometry command line option.
//

const std = @import("std");

//
// What the -geometry option asked for.
//
pub const Geometry = struct {
    // The window's client width in pixels.
    width: c_int,
    // The window's client height in pixels.
    height: c_int,
    // The window's left edge on the virtual screen, or null when the option gave no position.
    x: ?c_int,
    // The window's top edge on the virtual screen, or null when the option gave no position.
    y: ?c_int,
};

//
// Parses the WxH or WxH+X+Y text of the -geometry option (the text after the equals sign). X and Y are signed and are
// used as they are, so a negative number is a position left of or above the primary monitor, not an offset from the
// right or bottom edge as it is in X11. Returns null for any other text.
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
    if (height_end == rest.len) {
        return .{
            .width = width,
            .height = height,
            .x = null,
            .y = null,
        };
    }
    const position = rest[height_end..];
    const y_start = std.mem.indexOfAnyPos(u8, position, 1, "+-") orelse {
        return null;
    };
    const x = std.fmt.parseInt(c_int, position[0..y_start], 10) catch {
        return null;
    };
    const y = std.fmt.parseInt(c_int, position[y_start..], 10) catch {
        return null;
    };
    return .{
        .width = width,
        .height = height,
        .x = x,
        .y = y,
    };
}
