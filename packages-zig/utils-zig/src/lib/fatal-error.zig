const errors = @import("errors.zig");

//
// A fatal error that should be reported to the user without stack traces or technical details.
// This is for user-facing errors that are expected and should be displayed cleanly.
// In Zig `throw new FatalError(message)` is written `return FatalError.throw("{s}", .{message})`,
// which returns `error.FatalError` and records the message (see errors.zig).
//
pub const FatalError = struct {
    //
    // Equivalent of `throw new FatalError(message)`.
    //
    pub fn throw(comptime format: []const u8, args: anytype) errors.FatalErrorSet {
        return errors.throwFatalError(format, args);
    }

    //
    // Equivalent of `error instanceof FatalError`.
    //
    pub fn isInstance(err: anyerror) bool {
        return err == error.FatalError;
    }
};
