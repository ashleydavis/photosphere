//
// Port of the parts of the third-party `sisteransi` package used by the clack prompts
// (this file has no TypeScript counterpart in the repo).
//

const std = @import("std");

//
// Control sequence introducer.
//
const CSI = "\x1b[";

//
// Cursor sequences (sisteransi `cursor`).
//
pub const cursor = struct {
    // Moves the cursor to the first column (`cursor.left`).
    pub const left = CSI ++ "G";

    // Hides the cursor (`cursor.hide`).
    pub const hide = CSI ++ "?25l";

    // Shows the cursor (`cursor.show`).
    pub const show = CSI ++ "?25h";

    //
    // Moves the cursor up count lines (`cursor.up(count)`).
    //
    pub fn up(writer: *std.Io.Writer, count: usize) std.Io.Writer.Error!void {
        try writer.print(CSI ++ "{d}A", .{count});
    }

    //
    // Moves the cursor by a number of columns and lines (`cursor.move(x, y)`); writes nothing for 0.
    //
    pub fn move(writer: *std.Io.Writer, columns: i64, lines: i64) std.Io.Writer.Error!void {
        if (columns < 0) {
            try writer.print(CSI ++ "{d}D", .{-columns});
        }
        else if (columns > 0) {
            try writer.print(CSI ++ "{d}C", .{columns});
        }

        if (lines < 0) {
            try writer.print(CSI ++ "{d}A", .{-lines});
        }
        else if (lines > 0) {
            try writer.print(CSI ++ "{d}B", .{lines});
        }
    }
};

//
// Erase sequences (sisteransi `erase`).
//
pub const erase = struct {
    // Erases the whole line (`erase.line`).
    pub const line = CSI ++ "2K";

    //
    // Erases from the cursor down, count times (`erase.down(count)`).
    //
    pub fn down(writer: *std.Io.Writer, count: usize) std.Io.Writer.Error!void {
        var index: usize = 0;
        while (index < count) {
            try writer.writeAll(CSI ++ "J");
            index += 1;
        }
    }

    //
    // Erases count lines upwards from the cursor and moves to the first column (`erase.lines(count)`).
    //
    pub fn lines(writer: *std.Io.Writer, count: usize) std.Io.Writer.Error!void {
        var index: usize = 0;
        while (index < count) {
            try writer.writeAll(line);
            if (index < count - 1) {
                try cursor.up(writer, 1);
            }
            index += 1;
        }
        if (count > 0) {
            try writer.writeAll(cursor.left);
        }
    }
};
