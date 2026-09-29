const std = @import("std");
const errors = @import("errors.zig");
const js_number = @import("js-number.zig");

//
// Options for transforming an image.
//
pub const IImageTransformation = struct {
    //
    // The orientation of the image.
    //
    rotate: ?f64 = null,

    //
    // True if the image should be flipped horizontally.
    //
    flipX: ?bool = null,

    //
    // Changes the orientation of the image.
    //
    changeOrientation: ?bool = null,
};

//
// The orientation read from the EXIF: a number, or the text of a value that is not one (TypeScript: whatever
// `exif.Orientation` or `exif.Orientation[0]` holds, compared with `===` against the numbered cases).
//
const IOrientation = union(enum) {
    // A number.
    number: f64,

    // Anything else, as `String(value)` renders it.
    other: []const u8,
};

//
// TODO: a Date renders as `date`, where String(date) writes the date.
//
// Reads a JavaScript value (serialization-zig's BsonValue, taken by duck typing because utils cannot depend on
// serialization) as an orientation.
//
fn toOrientation(allocator: std.mem.Allocator, value: anytype) std.mem.Allocator.Error!IOrientation {
    return switch (value) {
        .number => |number| .{ .number = number },
        .int32 => |number| .{ .number = @floatFromInt(number) },
        .double => |number| .{ .number = number },
        .string => |text| .{ .other = text },
        .undefined => .{ .other = "undefined" },
        .null => .{ .other = "null" },
        .boolean => |boolean| .{ .other = if (boolean) "true" else "false" },
        .array => |items| .{ .other = try arrayToString(allocator, items) },
        .document => .{ .other = "[object Object]" },
        else => .{ .other = try std.fmt.allocPrint(allocator, "{s}", .{@tagName(value)}) },
    };
}

//
// Renders an array like JavaScript's `String(array)`: its items rendered and joined with commas, with undefined and
// null items empty.
//
fn arrayToString(allocator: std.mem.Allocator, items: anytype) std.mem.Allocator.Error![]const u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    for (items, 0..) |item, index| {
        if (index > 0) {
            output.writer.writeByte(',') catch return error.OutOfMemory;
        }
        switch (item) {
            .undefined, .null => {},
            else => switch (try toOrientation(allocator, item)) {
                .number => |number| js_number.writeNumber(&output.writer, number) catch return error.OutOfMemory,
                .other => |text| output.writer.writeAll(text) catch return error.OutOfMemory,
            },
        }
    }
    return output.written();
}

//
// JavaScript truthiness of a JavaScript value (duck typed like toOrientation).
//
fn isTruthy(value: anytype) bool {
    return switch (value) {
        .number, .double => |number| number != 0 and !std.math.isNan(number),
        .int32 => |number| number != 0,
        .string => |text| text.len > 0,
        .undefined, .null => false,
        .boolean => |boolean| boolean,
        else => true,
    };
}

//
// Gets the transformation for an image. The EXIF tags are a JavaScript object (serialization-zig's BsonDocument, or
// null for undefined), taken by duck typing: `exif.get(name)` returns the value of a tag.
//
pub fn getImageTransformation(allocator: std.mem.Allocator, exif: anytype) !?IImageTransformation {

    const tags = exif orelse {
        return null; // No transformation needed.
    };

    var orientation: IOrientation = .{ .number = 1 };
    if (tags.get("Orientation")) |orientationValue| {
        if (isTruthy(orientationValue)) {
            switch (orientationValue) {
                .array => |items| {
                    orientation = if (items.len > 0) try toOrientation(allocator, items[0]) else .{ .other = "undefined" };
                },
                else => {
                    orientation = try toOrientation(allocator, orientationValue);
                },
            }
        }
    }

    const number = switch (orientation) {
        .number => |value| value,
        .other => |text| {
            return errors.throwError("Unsupported orientation: {s}", .{text});
        },
    };

    // Value 0 shouldn't be supported, but I've seen it in at least one photo.
    // So have others: https://stackoverflow.com/questions/39400351/android-exif-data-always-0-how-to-change-it
    if (number == 0) {
        return null;
    }
    else if (number == 1) {
        return null; // No transform needed.
    }
    else if (number == 2) {
        return .{
            .flipX = true,
        };
    }
    else if (number == 3) {
        return .{
            .rotate = 180, // Clockwise.
        };
    }
    else if (number == 4) {
        return .{
            .flipX = true,
            .rotate = 180, // Clockwise.
        };
    }
    else if (number == 5) {
        return .{
            .flipX = true,
            .rotate = 270, // Clockwise.
            .changeOrientation = true,
        };
    }
    else if (number == 6) {
        return .{
            .rotate = 90,
            .changeOrientation = true,
        };
    }
    else if (number == 7) {
        return .{
            .flipX = true,
            .rotate = 90, // Clockwise.
            .changeOrientation = true,
        };
    }
    else if (number == 8) {
        return .{
            .rotate = 270, // Clockwise.
            .changeOrientation = true,
        };
    }
    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    js_number.writeNumber(&writer, number) catch {};
    return errors.throwError("Unsupported orientation: {s}", .{writer.buffered()});
}

//
// TODO: streams that are not an array give no transformation, where `for...of` throws a TypeError.
//
// Gets the transformation for a video. The metadata is a JavaScript object (serialization-zig's BsonDocument, or
// null for undefined), taken by duck typing like getImageTransformation.
//
pub fn getVideoTransformation(allocator: std.mem.Allocator, metadata: anytype) !?IImageTransformation {

    const document = metadata orelse {
        return null; // No transformation needed for videos without rotation.
    };
    const streams = document.get("streams") orelse {
        return null; // No transformation needed for videos without rotation.
    };
    if (!isTruthy(streams)) {
        return null; // No transformation needed for videos without rotation.
    }

    var rotation: ?[]const u8 = null;

    // Not ported: iterating a `streams` value that is not an array (ffprobe's metadata has no `streams`).
    const streamList = switch (streams) {
        .array => |items| items,
        else => return null,
    };
    for (streamList) |stream| {
        const streamRotation = switch (stream) {
            .document => |streamDocument| streamDocument.get("rotation"),
            else => null,
        };
        if (streamRotation) |value| {
            if (isTruthy(value)) {
                rotation = switch (try toOrientation(allocator, value)) {
                    .number => |number| blk: {
                        var output: std.Io.Writer.Allocating = .init(allocator);
                        try js_number.writeNumber(&output.writer, number);
                        break :blk output.written();
                    },
                    .other => |text| text,
                };
                break;
            }
        }
    }

    const rotationText = rotation orelse {
        return null;
    };
    if (rotationText.len == 0) {
        return null;
    }

    const imageTransformation: IImageTransformation = .{
        .rotate = js_number.parseFloat(rotationText),
        .changeOrientation = std.mem.eql(u8, rotationText, "-90") or std.mem.eql(u8, rotationText, "90") or std.mem.eql(u8, rotationText, "270") or std.mem.eql(u8, rotationText, "-270"),
    };
    return imageTransformation;
}

