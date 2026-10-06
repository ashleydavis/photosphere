//
// The files the user last dropped on the window, as the shell reported them. A page cannot learn the path of a dropped file: a web
// view gives it no File with a path (WebKitGTK gives no File at all), so the page asks the core for the paths of the last drop, which is
// what Electron's webUtils.getPathForFile gives an app that has the real path.
//

const std = @import("std");

//
// One dropped file.
//
const DroppedFile = struct {
    // The file's name, without its folder.
    name: []u8,
    // The file's full path.
    path: []u8,
    // The file's size in bytes when it was dropped.
    size: u64,
};

//
// The last drop. A new drop replaces the one before it.
//
pub const DroppedFiles = struct {
    // Allocates the entries.
    allocator: std.mem.Allocator,
    // Guards the files.
    mutex: std.Io.Mutex,
    // The files of the last drop.
    files: std.ArrayList(DroppedFile),

    pub fn init(allocator: std.mem.Allocator) DroppedFiles {
        return .{
            .allocator = allocator,
            .mutex = .init,
            .files = .empty,
        };
    }

    pub fn deinit(self: *DroppedFiles) void {
        self.clear();
        self.files.deinit(self.allocator);
    }

    fn clear(self: *DroppedFiles) void {
        for (self.files.items) |file| {
            self.allocator.free(file.name);
            self.allocator.free(file.path);
        }
        self.files.clearRetainingCapacity();
    }

    //
    // Records a drop, replacing the last one. The paths are the JSON text of an array of strings. A path that is not a file that can
    // be read is an error and leaves the last drop as it was.
    //
    pub fn replace(self: *DroppedFiles, io: std.Io, paths_json: []const u8) !void {
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena_state.allocator(), paths_json, .{});
        if (parsed != .array) {
            return error.NotAnArrayOfPaths;
        }
        var recorded: std.ArrayList(DroppedFile) = .empty;
        errdefer {
            for (recorded.items) |file| {
                self.allocator.free(file.name);
                self.allocator.free(file.path);
            }
            recorded.deinit(self.allocator);
        }
        for (parsed.array.items) |item| {
            if (item != .string) {
                return error.NotAnArrayOfPaths;
            }
            const stat = try std.Io.Dir.cwd().statFile(io, item.string, .{});
            const path = try self.allocator.dupe(u8, item.string);
            errdefer self.allocator.free(path);
            const name = try self.allocator.dupe(u8, std.fs.path.basename(item.string));
            errdefer self.allocator.free(name);
            try recorded.append(self.allocator, .{
                .name = name,
                .path = path,
                .size = stat.size,
            });
        }
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.clear();
        self.files.deinit(self.allocator);
        self.files = recorded;
    }

    //
    // The paths of the last drop as the JSON text of an array of strings, allocated with the allocator, [] when nothing was dropped.
    //
    pub fn pathsJson(self: *DroppedFiles, io: std.Io, allocator: std.mem.Allocator) ![]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        var paths: std.ArrayList([]const u8) = .empty;
        defer paths.deinit(allocator);
        for (self.files.items) |file| {
            try paths.append(allocator, file.path);
        }
        return try std.json.Stringify.valueAlloc(allocator, paths.items, .{});
    }
};
