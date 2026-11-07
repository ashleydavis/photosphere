const std = @import("std");
const utils = @import("utils-zig");
const describe_error = @import("photosphere-core").describe_error;

test "describeError gives the message a thrown error recorded" {
    const thrown = utils.errors.throwError("The vault could not be opened: {s}", .{"locked"});
    const text = describe_error.describeError(thrown).?;
    try std.testing.expectEqualStrings("The vault could not be opened: locked", text);
}

test "describeError gives the message a fatal error recorded" {
    const thrown = utils.errors.throwFatalError("Nothing can be done: {s}", .{"disk full"});
    const text = describe_error.describeError(thrown).?;
    try std.testing.expectEqualStrings("Nothing can be done: disk full", text);
}

test "describeError gives a sentence for the errors the system returns" {
    try std.testing.expectEqualStrings("A file or folder the request needs was not found.", describe_error.describeError(error.FileNotFound).?);
    try std.testing.expectEqualStrings("Photosphere is not allowed to read or write a file or folder the request needs.", describe_error.describeError(error.AccessDenied).?);
    try std.testing.expectEqualStrings("Photosphere ran out of memory.", describe_error.describeError(error.OutOfMemory).?);
    try std.testing.expectEqualStrings("There is no space left on the disk.", describe_error.describeError(error.NoSpaceLeft).?);
}

test "describeError has nothing to say about an error it does not know, so the reply carries the name" {
    try std.testing.expect(describe_error.describeError(error.SomethingNobodyExpected) == null);
}
