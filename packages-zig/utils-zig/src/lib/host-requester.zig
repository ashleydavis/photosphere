const std = @import("std");

//
// Asks the program that hosts the app (the phone's shell) to do something only it can, by the method's name, and gives back its
// answer as JSON text. Whoever owns the connection to the host makes one and hands it down to the code that needs it, so no code
// reaches for it through a global. A platform with no host to ask has none to hand down, and the code that needs one fails loudly.
//
pub const IHostRequester = struct {
    // Pointer to the implementation.
    ptr: *anyopaque,

    // Asks the host to do what the method names. The request and the answer are JSON text, and the answer is allocated with the
    // allocator. An error is the host's reason, or why the host could not be asked.
    request: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) anyerror![]const u8,

    //
    // Asks the host to do what the method names and returns its answer.
    //
    pub fn call(self: IHostRequester, allocator: std.mem.Allocator, method: []const u8, request_json: []const u8) anyerror![]const u8 {
        return self.request(self.ptr, allocator, method, request_json);
    }
};
