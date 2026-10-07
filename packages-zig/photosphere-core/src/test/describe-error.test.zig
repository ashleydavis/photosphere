const std = @import("std");
const utils = @import("utils-zig");
const handlers = @import("../lib/handlers.zig");

test "describeError gives the message a thrown error recorded" {
    const thrown = utils.errors.throwError("The vault could not be opened: {s}", .{"locked"});
    const text = handlers.describeError(thrown).?;
    try std.testing.expectEqualStrings("The vault could not be opened: locked", text);
}

test "describeError gives the message a fatal error recorded" {
    const thrown = utils.errors.throwFatalError("Nothing can be done: {s}", .{"disk full"});
    const text = handlers.describeError(thrown).?;
    try std.testing.expectEqualStrings("Nothing can be done: disk full", text);
}

test "describeError gives a sentence for the errors the system returns" {
    try std.testing.expectEqualStrings("A file or folder the request needs was not found.", handlers.describeError(error.FileNotFound).?);
    try std.testing.expectEqualStrings("Photosphere is not allowed to read or write a file or folder the request needs.", handlers.describeError(error.AccessDenied).?);
    try std.testing.expectEqualStrings("Photosphere ran out of memory.", handlers.describeError(error.OutOfMemory).?);
    try std.testing.expectEqualStrings("There is no space left on the disk.", handlers.describeError(error.NoSpaceLeft).?);
}

test "describeError has nothing to say about an error it does not know, so the reply carries the name" {
    try std.testing.expect(handlers.describeError(error.SomethingNobodyExpected) == null);
}
