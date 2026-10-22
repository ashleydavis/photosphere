const std = @import("std");
const node_utils = @import("node-utils-zig");

const in_process_tools = node_utils.in_process_tools;

//
// A tool the fake runner answers for, and what it prints.
//
pub const IFakeTool = struct {
    // The tool's name: `magick`, `ffmpeg` or `ffprobe`.
    name: []const u8,

    // What the tool prints, whatever it is asked.
    output: []const u8,
};

//
// A runner that stands in for the tools built into the program, for the tests that need a tool to print a given text or to
// fail. It handles every tool exec hands a runner, so no command is ever started as a program: a tool it was given prints its
// output and ends with exit code 0, and any other tool ends with exit code 1 and prints nothing, as a tool that does not run
// does. It records the arguments of the last call to each tool.
//
pub const FakeToolRunner = struct {
    // Owns the recorded arguments. Must outlive the runner.
    allocator: std.mem.Allocator,

    // The tools that run, and what each prints.
    tools: []const IFakeTool,

    // The arguments of the last call to each tool, joined with a space, by the tool's name.
    lastArguments: std.StringArrayHashMapUnmanaged([]const u8),

    //
    // Makes a runner for the tools. A tool not in the list fails.
    //
    pub fn init(allocator: std.mem.Allocator, tools: []const IFakeTool) FakeToolRunner {
        return .{
            .allocator = allocator,
            .tools = tools,
            .lastArguments = .empty,
        };
    }

    //
    // The runner exec calls. It points at this, so this must not move while the runner is used.
    //
    pub fn runner(self: *FakeToolRunner) in_process_tools.InProcessRunner {
        return .{
            .context = self,
            .handles = handles,
            .run = run,
        };
    }

    //
    // The arguments of the last call to the tool, joined with a space. Fails the test when the tool was never called.
    //
    pub fn argumentsOf(self: *FakeToolRunner, tool: []const u8) ![]const u8 {
        return self.lastArguments.get(tool) orelse {
            std.debug.print("The fake {s} was never called.\n", .{tool});
            return error.TestUnexpectedResult;
        };
    }

    //
    // Takes every tool, so that none is started as a program.
    //
    fn handles(context: ?*anyopaque, tool: []const u8) bool {
        _ = context;
        _ = tool;
        return true;
    }

    //
    // Records the arguments and prints the tool's output, or fails for a tool the runner was not given.
    //
    fn run(context: ?*anyopaque, allocator: std.mem.Allocator, tool: []const u8, arguments: []const []const u8) anyerror!in_process_tools.ToolOutput {
        _ = allocator;
        const self: *FakeToolRunner = @ptrCast(@alignCast(context.?));
        try self.lastArguments.put(self.allocator, try self.allocator.dupe(u8, tool), try std.mem.join(self.allocator, " ", arguments));
        for (self.tools) |fakeTool| {
            if (std.mem.eql(u8, fakeTool.name, tool)) {
                return .{
                    .exit_code = 0,
                    .output = fakeTool.output,
                };
            }
        }
        return .{
            .exit_code = 1,
            .output = "",
        };
    }
};
