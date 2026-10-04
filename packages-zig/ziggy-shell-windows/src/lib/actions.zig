//
// The menu actions the shell performs itself, and the message the others become.
//

const std = @import("std");

//
// The actions the shell knows. Any other action name belongs to the app.
//
pub const Action = enum {
    quit,
    reload,
    toggle_devtools,
    toggle_fullscreen,
    zoom_in,
    zoom_out,
    zoom_reset,
    undo,
    redo,
    cut,
    copy,
    paste,
    select_all,
};

//
// Returns the shell's action for an action name from the menu, or null when the name is the app's.
//
pub fn fromName(name: []const u8) ?Action {
    // An action's name is the member's name with a hyphen where the member has an underscore.
    inline for (@typeInfo(Action).@"enum".fields) |field| {
        var hyphenated: [field.name.len]u8 = undefined;
        for (field.name, 0..) |byte, index| {
            hyphenated[index] = if (byte == '_') '-' else byte;
        }
        if (std.mem.eql(u8, &hyphenated, name)) {
            return @enumFromInt(field.value);
        }
    }
    return null;
}

//
// Returns the document.execCommand command that does an editing action, or null when the action is not one.
//
pub fn editCommand(action: Action) ?[]const u8 {
    return switch (action) {
        .undo => "undo",
        .redo => "redo",
        .cut => "cut",
        .copy => "copy",
        .paste => "paste",
        .select_all => "selectAll",
        else => null,
    };
}

//
// The smallest page zoom factor.
//
pub const zoom_minimum: f64 = 0.25;

//
// The largest page zoom factor.
//
pub const zoom_maximum: f64 = 5.0;

//
// Returns the zoom factor after zoom in (a positive direction), zoom out (a negative one) or reset (zero): a step of 0.1
// rounded to a tenth so repeated steps do not drift, kept between the minimum and the maximum.
//
pub fn nextZoom(current: f64, direction: i32) f64 {
    if (direction == 0) {
        return 1.0;
    }
    const stepped = @round((current + 0.1 * @as(f64, @floatFromInt(direction))) * 10.0) / 10.0;
    return std.math.clamp(stepped, zoom_minimum, zoom_maximum);
}

//
// The message a menu action the app owns becomes: the JSON text the core takes from a page.
//
const MenuActionMessage = struct {
    // The channel the core routes it by.
    channel: []const u8,
    // The message's content.
    data: MenuActionData,
};

//
// The content of the message of a menu action.
//
const MenuActionData = struct {
    // The action's name.
    action: []const u8,
};

//
// Returns the JSON text of the message for an action, such as {"channel":"menu-action","data":{"action":"about"}}. The caller
// owns it.
//
pub fn menuActionMessage(allocator: std.mem.Allocator, action: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, MenuActionMessage{
        .channel = "menu-action",
        .data = .{
            .action = action,
        },
    }, .{});
}

//
// The script that returns the text the user has selected in the page: the selected part of the focused text field or text
// area, or else the page's own selection.
//
pub const selection_script =
    "(function () { var element = document.activeElement; if (element && (element.tagName === 'TEXTAREA' || element.tagName === 'INPUT') && typeof element.selectionStart === 'number') { return element.value.substring(element.selectionStart, element.selectionEnd); } return String(window.getSelection()); })();";

//
// Returns the script that types text into the focused field as if the user had pasted it. document.execCommand('paste') is
// refused to a script, so the shell reads the clipboard itself and inserts the text with the editing command that is
// allowed, which can still be undone. The caller owns the result.
//
pub fn pasteScript(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const literal = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(literal);
    return std.fmt.allocPrint(allocator, "document.execCommand('insertText', false, {s});", .{literal});
}

//
// Returns the text in the JSON string that running selection_script gives back, such as "abc" (with its quotes). The caller
// owns the result.
//
pub fn selectionText(allocator: std.mem.Allocator, script_result: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice([]const u8, allocator, script_result, .{});
    defer parsed.deinit();
    return allocator.dupe(u8, parsed.value);
}
