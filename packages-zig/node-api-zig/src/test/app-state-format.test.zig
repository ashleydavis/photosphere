const std = @import("std");
const utils = @import("utils-zig");
const node_api = @import("node-api-zig");
const app_state_format = node_api.app_state_format;
const IAppState = app_state_format.IAppState;

//
// Parses JSON text into the value a YAML document holds.
//
fn parse(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, text, .{});
}

//
// A value as compact JSON.
//
fn toText(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{
        .emit_null_optional_fields = false,
    });
}

//
// The pure conversions between the on-disk document and the in-memory flat state.
//

//
// An absent key stays absent so the interface can apply its own default to it, and a document that is not an object
// reads as nothing stored at all.
//

//
// A hand-edited file can hold the wrong type for a field. That field reads as absent, the rest of its section is read,
// and a list of searches keeps only its strings.
//

//
// A section that is a list, a string or null reads as an empty section.
//

//
// The state a document was read from writes back as the same state.
//

//
// Every declared field is written under its snake_case name in its own section.
//

//
// A file never carries an empty section.
//

//
// A document that is not an object is replaced rather than merged into.
//

//
// A cleared field is removed from its section, and a section left empty goes with it.
//

//
// The news state is in the same document and appears nowhere in the flat view, so a write that rebuilt the document from
// the flat view alone would delete what the user had already been shown.
//

//
// A field of a section the flat view does not know is kept, because the merge starts from the section as it is.
//

//
// A declared key is read from and written to its own field, and not placed in the ui section.
//

//
// Every declared key takes a value of its own kind and reads back what was written.
//

//
// A key the document does not declare is read from and written to the ui section.
//

//
// A key nothing has been stored under reads as undefined.
//

//
// Writing nothing removes a key rather than leaving it as it was.
//

//
// Clearing a ui key that was never set changes nothing, and in particular does not create the ui section.
//

//
// Setting a ui key again replaces its value rather than adding a second one.
//

//
// Every key that has a value is listed together under its own name.
//

//
// A key with no value is left out rather than listed as undefined.
//

//
// The value arrives as JSON, so a declared key given a value of the wrong kind is refused with an error that names the
// key, and the state is left as it was.
//

//
// A key kept in the ui section holds what the interface can hold, so an object or a null is refused and nothing is
// written.
//



//
// Writing nothing removes each of the other declared keys too, not only the two above.
//

//
// The gallery row height is a number, and a value that is not one is refused rather than handed to the interface.
//
