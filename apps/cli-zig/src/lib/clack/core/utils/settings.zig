const std = @import("std");

//
// The default actions a key can be an alias for.
//
pub const Action = enum {
    // Move up.
    up,

    // Move down.
    down,

    // Move left.
    left,

    // Move right.
    right,

    // Space.
    space,

    // Enter.
    enter,

    // Cancel the prompt.
    cancel,
};

//
// An alias: a key name or character that triggers an action.
//
pub const Alias = struct {
    // The key name or character.
    key: []const u8,

    // The action it triggers.
    action: Action,
};

//
// Global settings for Clack programs, stored in memory
//
pub const InternalClackSettings = struct {
    // The aliases for the default actions.
    aliases: []const Alias,

    // Custom messages (only used by the spinner, which is not ported).
    messages: struct {
        // Message shown when a spinner is cancelled.
        cancel: []const u8,

        // Message shown when a spinner fails.
        @"error": []const u8,
    },
};

//
// The settings (TypeScript: `settings`).
//
pub const settings: InternalClackSettings = .{
    .aliases = &.{
        // vim support
        .{ .key = "k", .action = .up },
        .{ .key = "j", .action = .down },
        .{ .key = "h", .action = .left },
        .{ .key = "l", .action = .right },
        .{ .key = "\x03", .action = .cancel },
        // opinionated defaults!
        .{ .key = "escape", .action = .cancel },
    },
    .messages = .{
        .cancel = "Canceled",
        .@"error" = "Something went wrong",
    },
};

//
// Gets the action a key name is an alias for (`settings.aliases.get(key)`).
//
pub fn aliasAction(key: []const u8) ?Action {
    for (settings.aliases) |alias| {
        if (std.mem.eql(u8, alias.key, key)) {
            return alias.action;
        }
    }
    return null;
}

//
// Gets the action with the given name (`settings.actions.has(name)`).
//
pub fn actionNamed(name: []const u8) ?Action {
    return std.meta.stringToEnum(Action, name);
}

// Not ported: updateSettings (not used by the CLI).

//
// Check if a key is an alias for a default action
// (the TypeScript function takes a string or an array of possibly undefined strings).
//
pub fn isActionKey(keys: []const ?[]const u8, action: Action) bool {
    for (keys) |value| {
        const key = value orelse continue;
        if (aliasAction(key) == action) {
            return true;
        }
    }
    return false;
}
