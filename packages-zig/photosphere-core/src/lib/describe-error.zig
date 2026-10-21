//
// The text of the error reply the page gets when one of Photosphere's handlers fails: the app's `describe_error`, which it gives
// Ziggy's core in app.zig.
//

const utils = @import("utils-zig");

//
// Gives the text of the error reply for an error a handler returned, in words the user can act on. A thrown error gives the message
// the code that failed recorded. An error the
// operating system or the allocator returned gives a sentence for the common ones. Any other error is not described, so the reply carries its name.
//
pub fn describeError(err: anyerror) ?[]const u8 {
    if (err == error.Thrown or err == error.FatalError) {
        return utils.errors.errorMessage(err);
    }
    return switch (err) {
        error.FileNotFound => "A file or folder the request needs was not found.",
        error.AccessDenied => "Photosphere is not allowed to read or write a file or folder the request needs.",
        error.PermissionDenied => "Photosphere is not allowed to read or write a file or folder the request needs.",
        error.OutOfMemory => "Photosphere ran out of memory.",
        error.NoSpaceLeft => "There is no space left on the disk.",
        error.DiskQuota => "There is no space left on the disk.",
        error.ConnectionRefused => "The server refused the connection.",
        error.ConnectionTimedOut => "The connection to the server timed out.",
        error.NetworkUnreachable => "The network cannot be reached.",
        error.Cancelled => "The request was cancelled.",
        else => null,
    };
}
