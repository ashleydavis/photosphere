//
// The meeting point of the MCP server and the page.
//
// A tool call arrives on a thread of the MCP server's HTTP server, and the page is the one that knows how to do it. The server asks
// the page by sending it an `mcp-tool-request` event, and waits here until the page answers on the `mcp-tool-response` message. Each
// request is told apart from the others by the id the server gave it, so any number can be waiting at once.
//

const std = @import("std");

//
// A request that has been sent to the page and has no answer yet.
//
const IPending = struct {
    // Whether the page has answered.
    answered: bool,

    // Whether the answer is a failure, in which case the text is the reason.
    failed: bool,

    // The answer, owned by the bridge until it is handed to the waiter.
    text: []u8,
};

//
// What the page answered.
//
pub const IAnswer = struct {
    // Whether the page failed to do what the tool asked.
    failed: bool,

    // The text of the result, or the reason for the failure.
    text: []const u8,
};

//
// The requests waiting for the page, by request id.
//
pub const McpBridge = struct {
    // Allocates the entries of the table and the answers held in them.
    allocator: std.mem.Allocator,

    // The Io the mutex and the waits use.
    io: std.Io,

    // Guards the table.
    mutex: std.Io.Mutex,

    // The requests waiting for the page. The keys are owned by the bridge.
    pending: std.StringHashMapUnmanaged(*IPending),

    // The port the MCP server is listening on, or 0 when it is not.
    port: std.atomic.Value(u16),

    //
    // Makes a bridge with nothing waiting.
    //
    pub fn init(allocator: std.mem.Allocator, io: std.Io) McpBridge {
        return .{
            .allocator = allocator,
            .io = io,
            .mutex = .init,
            .pending = .empty,
            .port = .init(0),
        };
    }

    //
    // Frees what the bridge holds. A request still waiting has no one left to answer it.
    //
    pub fn deinit(self: *McpBridge) void {
        var iterator = self.pending.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.*.text);
            self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.pending.deinit(self.allocator);
    }

    //
    // Records that a request has been sent to the page and is waiting for its answer. Call it before the request is sent, so an answer
    // can never arrive for a request the bridge does not know.
    //
    pub fn begin(self: *McpBridge, request_id: []const u8) !void {
        const key = try self.allocator.dupe(u8, request_id);
        errdefer self.allocator.free(key);
        const entry = try self.allocator.create(IPending);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .answered = false,
            .failed = false,
            .text = &.{},
        };
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.pending.put(self.allocator, key, entry);
    }

    //
    // Records the page's answer to a request. An answer to a request that is not waiting (it was answered already, or it is not one of
    // this server's) is ignored.
    //
    pub fn respond(self: *McpBridge, request_id: []const u8, failed: bool, text: []const u8) !void {
        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.pending.get(request_id) orelse {
            self.allocator.free(owned);
            return;
        };
        if (entry.answered) {
            self.allocator.free(owned);
            return;
        }
        entry.answered = true;
        entry.failed = failed;
        entry.text = owned;
    }

    //
    // Waits for the answer to a request recorded with begin, and forgets the request. The answer is allocated with the allocator.
    // Returns error.Cancelled when `cancelled` is set before the page answers.
    //
    pub fn wait(self: *McpBridge, allocator: std.mem.Allocator, request_id: []const u8, cancelled: *const std.atomic.Value(bool)) !IAnswer {
        defer self.cancel(request_id);
        while (true) {
            if (try self.take(allocator, request_id)) |answer| {
                return answer;
            }
            if (cancelled.load(.acquire)) {
                return error.Cancelled;
            }
            try self.io.sleep(.fromMilliseconds(10), .awake);
        }
    }

    //
    // Takes the answer to a request when the page has given it.
    //
    fn take(self: *McpBridge, allocator: std.mem.Allocator, request_id: []const u8) !?IAnswer {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const entry = self.pending.get(request_id) orelse {
            return null;
        };
        if (!entry.answered) {
            return null;
        }
        return .{
            .failed = entry.failed,
            .text = try allocator.dupe(u8, entry.text),
        };
    }

    //
    // Forgets a request, freeing what it held. Used when the request could not be sent to the page, and by wait when it is done. A request
    // that is not in the table is ignored.
    //
    pub fn cancel(self: *McpBridge, request_id: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const removed = self.pending.fetchRemove(request_id) orelse {
            return;
        };
        self.allocator.free(removed.value.text);
        self.allocator.destroy(removed.value);
        self.allocator.free(removed.key);
    }
};
