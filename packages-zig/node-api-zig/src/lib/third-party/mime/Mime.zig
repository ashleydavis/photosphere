//
// Port of mime 4.1.0 src/Mime.ts: a map of MIME types to file extensions and back.
//
// mime (c) 2023 Robert Kieffer, MIT license.
//
// Only what Photosphere uses is ported: the constructor's define() calls and getType(). Not ported: getExtension,
// getAllExtensions, _freeze and _getTestState.
//

const std = @import("std");
const utils_zig = @import("utils-zig");
const errors = utils_zig.errors;

//
// One entry of a TypeMap (TypeScript: `[type, extensions]` of `Object.entries(typeMap)`).
//
pub const TypeMapEntry = struct {
    // The MIME type.
    type: []const u8,

    // Its extensions; one starting with "*" is known but not mapped back to this type.
    extensions: []const []const u8,
};

//
// A map of MIME types to extensions and extensions to MIME types.
//
pub const Mime = struct {
    // Allocates the maps.
    allocator: std.mem.Allocator,

    // The MIME type of each extension (TypeScript: #extensionToType).
    extensionToType: std.StringHashMapUnmanaged([]const u8) = .empty,

    // Not ported: #typeToExtension and #typeToExtensions (only read by getExtension and getAllExtensions).

    //
    // Creates a map from the type maps, defined in order (TypeScript: `new Mime(...args)`).
    //
    pub fn init(allocator: std.mem.Allocator, typeMaps: []const []const TypeMapEntry) !Mime {
        var self: Mime = .{
            .allocator = allocator,
        };
        for (typeMaps) |typeMap| {
            try self.define(typeMap, false);
        }
        return self;
    }

    //
    // Define mimetype -> extension mappings. Each key is a mime-type that maps to an array of extensions
    // associated with the type. The first extension is used as the default extension for the type.
    //
    // A leading '*' on an extension says it is known but not to be mapped back to the type.
    //
    pub fn define(self: *Mime, typeMap: []const TypeMapEntry, force: bool) !void {
        for (typeMap) |entry| {
            const mimeType = try std.ascii.allocLowerString(self.allocator, entry.type);
            for (entry.extensions) |rawExtension| {
                const lowerExtension = try std.ascii.allocLowerString(self.allocator, rawExtension);
                const starred = std.mem.startsWith(u8, lowerExtension, "*");
                const extension = if (starred) lowerExtension[1..] else lowerExtension;

                if (starred) {
                    continue;
                }

                const currentType = self.extensionToType.get(extension);
                if (currentType != null and !std.mem.eql(u8, currentType.?, mimeType) and !force) {
                    return errors.throwError("\"{s} -> {s}\" conflicts with \"{s} -> {s}\". Pass `force=true` to override this definition.", .{ mimeType, extension, currentType.?, extension });
                }
                try self.extensionToType.put(self.allocator, extension, mimeType);
            }
        }
    }

    //
    // Lookup a mime type based on extension.
    //
    pub fn getType(self: *const Mime, allocator: std.mem.Allocator, path: []const u8) !?[]const u8 {
        // `path.replace(/^.*[/\\]/s, '')`: everything up to the last slash or backslash goes.
        const lastSeparator = std.mem.lastIndexOfAny(u8, path, "/\\");
        const last = try std.ascii.allocLowerString(allocator, if (lastSeparator) |index| path[index + 1 ..] else path);

        // `last.replace(/^.*\./s, '')`: everything up to the last dot goes.
        const lastDot = std.mem.lastIndexOfScalar(u8, last, '.');
        const ext = if (lastDot) |index| last[index + 1 ..] else last;

        const hasPath = last.len < path.len;
        const hasDot = ext.len + 1 < last.len;

        if (!hasDot and hasPath) {
            return null;
        }

        return self.extensionToType.get(ext);
    }
};
