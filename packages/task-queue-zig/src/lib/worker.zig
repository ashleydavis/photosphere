//
// Worker infrastructure for task execution
// This module provides the core worker functionality that can be imported
// by application-specific worker files
//

const std = @import("std");
const utils = @import("utils-zig");
const types = @import("types.zig");
const TaskHandler = types.TaskHandler;
const ITaskContext = types.ITaskContext;
const errors = utils.errors;

//
// Allocator for the handler registry, which lives for the rest of the process.
//
const registry_allocator = std.heap.smp_allocator;

//
// The registered handlers by task type, in registration order (like a JavaScript Map).
// Handlers are registered at startup (initTaskHandlers) before any task runs, so the registry is
// not locked; registering while tasks are running on other threads is not supported.
//
var handlers: std.StringArrayHashMapUnmanaged(TaskHandler) = .empty;

//
// Registers the handler for a task type (replacing any previous handler for the type).
//
pub fn registerHandler(@"type": []const u8, handler: TaskHandler) !void {
    if (handlers.getPtr(@"type")) |existing| {
        existing.* = handler;
        return;
    }
    try handlers.put(registry_allocator, try registry_allocator.dupe(u8, @"type"), handler);
}

//
// Gets the handler for a task type, or null when none is registered.
//
pub fn getHandler(@"type": []const u8) ?TaskHandler {
    return handlers.get(@"type");
}

//
// Gets the registered task types, in registration order.
//
pub fn getRegisteredHandlerTypes() []const []const u8 {
    return handlers.keys();
}

//
// Shared function to execute a task handler
// Returns the handler outputs, or throws an error if the handler is not found or execution fails
//
pub fn executeTaskHandler(allocator: std.mem.Allocator, io: std.Io, taskType: []const u8, data: std.json.Value, context: ITaskContext) !std.json.Value {
    const registeredTypes = getRegisteredHandlerTypes();
    const handler = getHandler(taskType) orelse {
        const joined = try std.mem.join(allocator, ", ", registeredTypes);
        return errors.throwError("No handler registered for task type: {s}. Available handlers: {s}", .{ taskType, joined });
    };

    return handler(allocator, io, data, context);
}
