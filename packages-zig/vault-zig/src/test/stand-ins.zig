const std = @import("std");
const node_utils = @import("node-utils-zig");
const process_env = node_utils.process_env;

//
// Sets up, for one test, the state of the stand-in tools (src/test/stand-in/stand-in.zig) that build.zig puts first on
// the PATH of the test programs in place of `which`, `secret-tool` and `powershell`. The state lives in files in a
// temporary directory of the test's own, which the stand-ins find through the PHOTOSPHERE_STAND_IN_STATE variable of
// the environment the vault passes to them (`process.env`, set here with process_env.setEnvironMap).
//
pub const IStandIns = struct {
    // Allocates the state read back from the stand-ins.
    allocator: std.mem.Allocator,

    // The I/O implementation.
    io: std.Io,

    // The temporary directory holding the state of the stand-ins.
    tmpDir: std.testing.TmpDir,

    // The environment the vault passes to the stand-ins.
    environMap: *std.process.Environ.Map,

    //
    // Creates the state directory of a test and points the stand-ins at it. Call tearDown when the test is done.
    //
    pub fn setUp(allocator: std.mem.Allocator, io: std.Io) !IStandIns {
        var tmpDir = std.testing.tmpDir(.{});
        const currentPath = try std.process.currentPathAlloc(io, allocator);
        const statePath = try std.fs.path.join(allocator, &.{ currentPath, ".zig-cache", "tmp", &tmpDir.sub_path });
        const environMap = try allocator.create(std.process.Environ.Map);
        environMap.* = std.process.Environ.Map.init(allocator);
        try environMap.put("PHOTOSPHERE_STAND_IN_STATE", statePath);
        process_env.setEnvironMap(environMap);
        return .{
            .allocator = allocator,
            .io = io,
            .tmpDir = tmpDir,
            .environMap = environMap,
        };
    }

    //
    // Stops pointing the vault's child processes at the state directory and deletes it, file by file.
    //
    pub fn tearDown(self: *IStandIns) void {
        process_env.setEnvironMap(null);
        const stateFiles = [_][]const u8{ "store.json", "mode", "last-store-args", "last-store-stdin", "last-get-args" };
        for (stateFiles) |stateFile| {
            self.tmpDir.dir.deleteFile(self.io, stateFile) catch |err| {
                if (err != error.FileNotFound) {
                    std.debug.panic("Could not delete the stand-in state file {s}: {s}", .{ stateFile, @errorName(err) });
                }
            };
        }
        self.tmpDir.dir.close(self.io);
        self.tmpDir.parent_dir.deleteDir(self.io, &self.tmpDir.sub_path) catch |err| {
            std.debug.panic("Could not delete the stand-in state directory: {s}", .{@errorName(err)});
        };
        self.tmpDir.parent_dir.close(self.io);
    }

    //
    // Makes the stand-ins misbehave in the named way (see stand-in.zig), or behave again when the mode is "".
    //
    pub fn setMode(self: *const IStandIns, mode: []const u8) !void {
        try self.tmpDir.dir.writeFile(self.io, .{
            .sub_path = "mode",
            .data = mode,
        });
    }

    //
    // Reads a state file the stand-ins wrote, or returns null when they have not written it.
    //
    pub fn readStateFile(self: *const IStandIns, name: []const u8) !?[]const u8 {
        return self.tmpDir.dir.readFileAlloc(self.io, name, self.allocator, .unlimited) catch |err| {
            if (err == error.FileNotFound) {
                return null;
            }
            return err;
        };
    }

    //
    // Reads the keychain entries the stand-ins hold (an empty object when there are none).
    //
    pub fn readStore(self: *const IStandIns) !std.json.ObjectMap {
        const text = try self.readStateFile("store.json") orelse return .empty;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, self.allocator, text, .{});
        return parsed.object;
    }

    //
    // Replaces the keychain entries the stand-ins hold.
    //
    pub fn writeStore(self: *const IStandIns, store: std.json.ObjectMap) !void {
        const text = try std.json.Stringify.valueAlloc(self.allocator, std.json.Value{
            .object = store,
        }, .{});
        try self.tmpDir.dir.writeFile(self.io, .{
            .sub_path = "store.json",
            .data = text,
        });
    }

    //
    // Reads arguments a stand-in recorded as a JSON array, or returns null when it has not recorded any.
    //
    pub fn readRecordedArgs(self: *const IStandIns, name: []const u8) !?[]const []const u8 {
        const text = try self.readStateFile(name) orelse return null;
        return try std.json.parseFromSliceLeaky([]const []const u8, self.allocator, text, .{});
    }
};
