const std = @import("std");
const utils = @import("utils-zig");
const errors = utils.errors;
const FatalError = utils.fatal_error.FatalError;

test "FatalError.throw returns error.FatalError with the message" {
    const result: errors.FatalErrorSet!void = FatalError.throw("Database {s} not found", .{"photos"});
    try std.testing.expectError(error.FatalError, result);
    try std.testing.expectEqualStrings("Database photos not found", errors.lastErrorMessage());
    try std.testing.expectEqualStrings("FatalError", errors.lastErrorName());
}

test "FatalError.isInstance only matches fatal errors" {
    try std.testing.expect(FatalError.isInstance(error.FatalError));
    try std.testing.expect(!FatalError.isInstance(error.Thrown));
    try std.testing.expect(!FatalError.isInstance(error.FileNotFound));
}
