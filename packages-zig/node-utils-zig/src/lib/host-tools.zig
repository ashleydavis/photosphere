//
// ImageMagick, ffmpeg and ffprobe on a phone. Android has no such programs to start, so the app runs them inside its own process
// and the Zig code asks for them through a host requester: `runMagick`, `runFfmpeg` and `runFfprobe`, each with the tool's
// arguments (not its name) as {"args": [...]}, answered {"exitCode": number, "output": text} where the output is what the tool
// printed. The code that starts a task builds the runner from the task's host requester and passes it down to the code that runs
// the tools, which gives it to exec.
//

const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");
const in_process_tools = @import("in-process-tools.zig");

const IHostRequester = utils.host_requester.IHostRequester;

//
// What the runner asks the host through.
//
pub const HostToolRunner = struct {
    // The host that runs the tools.
    host: IHostRequester,

    //
    // The runner exec calls, backed by the host. The runner points at this, so this must not move while the runner is used.
    //
    pub fn runner(self: *HostToolRunner) in_process_tools.InProcessRunner {
        return .{
            .context = self,
            .run = run,
        };
    }

    //
    // The method that runs a tool, or null for a tool the host does not run.
    //
    fn methodFor(tool: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, tool, "magick")) {
            return "runMagick";
        }
        if (std.mem.eql(u8, tool, "ffmpeg")) {
            return "runFfmpeg";
        }
        if (std.mem.eql(u8, tool, "ffprobe")) {
            return "runFfprobe";
        }
        return null;
    }

    //
    // Asks the host to run the tool with the arguments and returns its exit code and output. Fails with the host's reason when the
    // host could not run it at all.
    //
    fn run(context: ?*anyopaque, allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) anyerror!in_process_tools.ToolOutput {
        const self: *HostToolRunner = @ptrCast(@alignCast(context.?));
        const method = methodFor(tool) orelse {
            return utils.errors.throwError("There is no way to run {s} in the app's process.", .{tool});
        };
        const request_text = try std.json.Stringify.valueAlloc(allocator, .{
            .args = arguments,
        }, .{});
        const reply_text = try self.host.call(allocator, method, request_text);
        return try readReply(allocator, method, reply_text);
    }
};

//
// Reads a host's answer, {"exitCode": number, "output": text}.
//
pub fn readReply(allocator: std.mem.Allocator, method: []const u8, reply_text: []const u8) !in_process_tools.ToolOutput {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, reply_text, .{}) catch {
        return utils.errors.throwError("The answer to {s} could not be read: {s}", .{ method, reply_text });
    };
    if (parsed != .object) {
        return utils.errors.throwError("The answer to {s} is not an object: {s}", .{ method, reply_text });
    }
    const exit_code_value = parsed.object.get("exitCode") orelse {
        return utils.errors.throwError("The answer to {s} has no exitCode: {s}", .{ method, reply_text });
    };
    if (exit_code_value != .integer) {
        return utils.errors.throwError("The answer to {s} has an exitCode that is not an integer: {s}", .{ method, reply_text });
    }
    const output_value = parsed.object.get("output") orelse {
        return utils.errors.throwError("The answer to {s} has no output: {s}", .{ method, reply_text });
    };
    if (output_value != .string) {
        return utils.errors.throwError("The answer to {s} has an output that is not text: {s}", .{ method, reply_text });
    }
    return .{
        .exit_code = std.math.cast(i32, exit_code_value.integer) orelse {
            return utils.errors.throwError("The answer to {s} has an exitCode that is out of range: {s}", .{ method, reply_text });
        },
        .output = output_value.string,
    };
}

//
// The runner that asks the host to run the tools, built in the storage the caller owns (which must outlive the runner and not move).
// It is the runner on Android, where the host runs the tools. Other platforms start the programs, so it is null there. Fails on
// Android when there is no host to ask, because ImageMagick and ffmpeg cannot be run without one.
//
pub fn toolRunnerFor(host: ?IHostRequester, storage: *HostToolRunner) !?in_process_tools.InProcessRunner {
    if (!builtin.abi.isAndroid()) {
        return null;
    }
    const host_requester = host orelse {
        return utils.errors.throwError("The Android shell gave the core no host request callback, so ImageMagick and ffmpeg cannot be run.", .{});
    };
    return hostToolRunner(host_requester, storage);
}

//
// The runner that asks the host to run the tools, built in the storage the caller owns.
//
pub fn hostToolRunner(host: IHostRequester, storage: *HostToolRunner) in_process_tools.InProcessRunner {
    storage.* = .{
        .host = host,
    };
    return storage.runner();
}
