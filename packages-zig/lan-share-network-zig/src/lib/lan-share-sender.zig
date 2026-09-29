const std = @import("std");
const utils = @import("utils-zig");
const node_utils = @import("node-utils-zig");
const lan_share_types = @import("lan-share-types.zig");
const socket = @import("socket.zig");
const https = @import("https.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const IReceiverEndpoint = lan_share_types.IReceiverEndpoint;
const errors = utils.errors;
const mathRandom = node_utils.fs.mathRandom;

//
// UDP port used for discovery broadcasts.
//
pub const DISCOVERY_PORT: u16 = 54321;

//
// Prefix string for receiver broadcast messages.
//
const BROADCAST_PREFIX = "PSIE_RECV:";

//
// How long each wait for a discovery broadcast lasts before the sender checks for a timeout or a cancel again (the
// event loop of the TypeScript sender runs the timer and cancel() between messages).
//
const POLL_INTERVAL_MS: i32 = 100;

//
// The hex SHA-256 hash of a text (`createHash("sha256").update(text).digest("hex")`).
//
pub fn sha256Hex(text: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

//
// Generates a random 4-digit pairing code (1000-9999).
//
fn generatePairingCode(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const code: u32 = @intFromFloat(@floor(1000 + mathRandom(io) * 9000));
    return std.fmt.allocPrint(allocator, "{d}", .{code});
}

//
// Reads the body of a GET /pairing-code-hash response and reports whether it holds the code hash
// (TypeScript: `(JSON.parse(hashResponse.body) as IPairingCodeHashResponse).codeHash === codeHash`).
//
pub fn pairingCodeHashMatches(allocator: std.mem.Allocator, body: []const u8, codeHash: []const u8) !bool {
    // JSON.parse keeps the last value of a repeated key.
    const hashBody = std.json.parseFromSliceLeaky(std.json.Value, allocator, body, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| {
        return errors.throwError("JSON Parse error: {s}", .{@errorName(err)});
    };
    const object = switch (hashBody) {
        .object => |object| object,
        .null => {
            errors.recordError("TypeError", "null is not an object (evaluating 'hashBody.codeHash')", .{});
            return error.Thrown;
        },

        // Any other value has no codeHash.
        else => return false,
    };
    const received = object.get("codeHash") orelse {
        return false;
    };
    return received == .string and std.mem.eql(u8, received.string, codeHash);
}

//
// Discovers a receiver on the LAN via UDP broadcast, then sends a payload
// over HTTPS with certificate pinning and mutual pairing code verification.
//
pub const LanShareSender = struct {
    // Allocates the sender's strings.
    allocator: std.mem.Allocator,

    // The opaque payload to send to the receiver.
    payload: std.json.Value,

    // The UDP socket used for listening to receiver broadcasts.
    udpSocket: ?socket.Handle,

    // Whether the sender has been cancelled.
    isCancelled: std.atomic.Value(bool),

    // Abandons the wait in waitForReceiver: set by cancel() while that wait is in progress, so the wait ends rather
    // than leave the caller sitting on it.
    abandonWaitForReceiver: std.atomic.Value(bool),

    // True while waitForReceiver is waiting (TypeScript: abandonWaitForReceiver is set only during the wait).
    isWaiting: std.atomic.Value(bool),

    // The 4-digit pairing code displayed to the user.
    pairingCode: []const u8,

    // Whether discovery heard a receiver announcing a different pairing code.
    //
    // Since discovery began filtering on the pairing code, a mistyped code and an absent receiver
    // both end as a plain timeout, and those are very different things to tell a person: one means
    // "check the number you typed", the other means "the other device is not sharing". This records
    // which of the two happened so the caller can say so.
    sawMismatchedReceiver: bool,

    //
    // Creates the sender (`new LanShareSender(payload, pairingCode?)`): a null pairing code generates one.
    //
    pub fn init(allocator: std.mem.Allocator, io: std.Io, payload: std.json.Value, pairingCode: ?[]const u8) !LanShareSender {
        return .{
            .allocator = allocator,
            .payload = payload,
            .pairingCode = pairingCode orelse try generatePairingCode(allocator, io),
            .udpSocket = null,
            .isCancelled = .init(false),
            .sawMismatchedReceiver = false,
            .abandonWaitForReceiver = .init(false),
            .isWaiting = .init(false),
        };
    }

    //
    // Listens for receiver UDP broadcasts on the LAN.
    // Returns the receiver endpoint when found, or null on timeout or cancellation.
    //
    pub fn waitForReceiver(self: *LanShareSender, io: std.Io, timeoutMs: i64) !?IReceiverEndpoint {
        // What this sender's own receiver will be announcing. Computed once, outside the message
        // handler, because every announcement on the subnet arrives here.
        const expectedCodeHash = sha256Hex(self.pairingCode);

        const udpSocket = try socket.createUdp(true, false);
        self.udpSocket = udpSocket;
        errdefer self.cleanupUdp();
        try socket.bind(udpSocket, .{ .address = .{ 0, 0, 0, 0 }, .port = DISCOVERY_PORT });

        const deadline = std.Io.Clock.awake.now(io).toMilliseconds() + timeoutMs;

        // Lets cancel() end this wait immediately, with the same "no receiver" result a timeout
        // gives. Closing the discovery socket is not enough on its own: the caller keeps waiting out
        // the full timeout, so Ctrl+C on `psi dbs send` looked like it did nothing for up to a minute.
        self.abandonWaitForReceiver.store(false, .release);
        self.isWaiting.store(true, .release);
        defer self.isWaiting.store(false, .release);

        var buffer: [2048]u8 = undefined;
        while (true) {
            if (self.abandonWaitForReceiver.load(.acquire)) {
                self.cleanupUdp();
                return null;
            }
            const remaining = deadline - std.Io.Clock.awake.now(io).toMilliseconds();
            if (remaining <= 0) {
                self.cleanupUdp();
                return null;
            }

            const readable = try socket.waitReadable(udpSocket, @intCast(@min(remaining, POLL_INTERVAL_MS)));
            if (!readable) {
                continue;
            }

            // Discovery is best-effort. Ignore transient UDP socket errors (for example an
            // ECONNREFUSED surfaced from an ICMP port-unreachable) so listening for the
            // receiver's broadcast is not aborted by a stray socket error (the TypeScript sender's
            // `error` handler).
            const datagram = socket.receiveFrom(udpSocket, &buffer) catch {
                continue;
            };

            if (self.isCancelled.load(.acquire)) {
                continue;
            }

            const text = datagram.data;
            if (!std.mem.startsWith(u8, text, BROADCAST_PREFIX)) {
                continue;
            }

            // Parse "PSIE_RECV:{port}:{codeHash}:{certFingerprint}"
            const fields = text[BROADCAST_PREFIX.len..];
            var parts = std.mem.splitScalar(u8, fields, ':');
            const portText = parts.next().?;
            const announcedCodeHash = parts.next() orelse {
                continue;
            };
            if (parts.index == null) {
                continue;
            }
            const certFingerprint = parts.rest(); // fingerprint might contain colons
            const port = parseIntLikeJavaScript(portText) orelse {
                continue;
            };
            if (certFingerprint.len == 0) {
                continue;
            }

            // Fixes the intermittent LAN-share failure where the receiver never reached its review step.
            //
            // Ignore any receiver that is not the one this share is paired with. The discovery
            // port is a single machine-wide resource and the announcement goes to the whole
            // subnet, so everything else sharing at that moment is heard here: another
            // worktree's smoke tests, the lan-share unit tests, another machine on the LAN.
            // Without this check the first announcement to arrive won, and because a pairing
            // code mismatch is fatal further down (no retry, no second look, the socket is
            // already closed), picking a stranger ended the share for good.
            if (!std.mem.eql(u8, announcedCodeHash, &expectedCodeHash)) {
                self.sawMismatchedReceiver = true;
                continue;
            }

            self.cleanupUdp();

            return .{
                .address = try datagram.from.format(self.allocator),
                .port = port,
                .certFingerprint = try self.allocator.dupe(u8, certFingerprint),
            };
        }
    }

    //
    // Makes a cert-pinned HTTPS request to the receiver and returns the parsed response body.
    //
    fn makeRequest(self: *LanShareSender, endpoint: IReceiverEndpoint, method: []const u8, path: []const u8, requestBody: ?[]const u8) !https.IResponse {
        const connection = try https.Connection.connect(self.allocator, try socket.parseAddress(endpoint.address, endpoint.port));
        defer connection.close();

        const certificate = try connection.peerCertificateDer(self.allocator);
        if (certificate.len > 0) {
            const actualFingerprint = sha256Hex(certificate);
            if (!std.mem.eql(u8, &actualFingerprint, endpoint.certFingerprint)) {
                return errors.throwError("Certificate fingerprint mismatch - possible MITM attack. Expected {s}, got {s}", .{ endpoint.certFingerprint, &actualFingerprint });
            }
        }

        const host = try std.fmt.allocPrint(self.allocator, "{s}:{d}", .{ endpoint.address, endpoint.port });
        return https.request(self.allocator, connection, host, method, path, requestBody);
    }

    //
    // Sends the payload to the discovered receiver over HTTPS.
    // First calls GET /pairing-code-hash to verify the receiver knows the same pairing code.
    // Then posts the payload with the code hash for a second layer of verification.
    // Returns true on success, false if the pairing code is rejected by either check.
    //
    pub fn send(self: *LanShareSender, endpoint: IReceiverEndpoint) !bool {
        const codeHash = sha256Hex(self.pairingCode);

        // Pre-send verification: confirm the receiver has the same pairing code.
        const hashResponse = try self.makeRequest(endpoint, "GET", "/pairing-code-hash", null);
        if (hashResponse.statusCode != 200) {
            return false;
        }

        if (!try pairingCodeHashMatches(self.allocator, hashResponse.body, &codeHash)) {
            return false;
        }

        // Send the payload with the code hash for the receiver's second-layer check.
        var body: std.json.ObjectMap = .empty;
        try body.put(self.allocator, "codeHash", .{ .string = &codeHash });
        try body.put(self.allocator, "payload", self.payload);
        const payloadBody = try std.json.Stringify.valueAlloc(self.allocator, std.json.Value{ .object = body }, .{});
        const sendResponse = try self.makeRequest(endpoint, "POST", "/share-payload", payloadBody);

        if (sendResponse.statusCode == 403) {
            return false;
        }

        if (sendResponse.statusCode == 200) {
            return true;
        }

        return errors.throwError("Unexpected status code: {d}", .{sendResponse.statusCode});
    }

    //
    // Cancels the sender, ending any wait in progress (the wait closes the discovery socket as it ends).
    // The receiver's cancel() finishes its pending wait the same way; without that here, Ctrl+C on a
    // waiting sender closed the socket but left the command sitting on its promise until the full
    // discovery timeout ran out.
    // Safe to call from a signal handler or another thread: it only sets flags.
    //
    pub fn cancel(self: *LanShareSender) void {
        self.isCancelled.store(true, .release);

        if (self.isWaiting.load(.acquire)) {
            self.abandonWaitForReceiver.store(true, .release);
        }
    }

    //
    // Closes the UDP socket if it is open.
    //
    fn cleanupUdp(self: *LanShareSender) void {
        if (self.udpSocket) |udpSocket| {
            socket.close(udpSocket);
            self.udpSocket = null;
        }
    }
};

//
// Reads the announced port with `parseInt(text, 10)`. Returns null for NaN, and for a number that is not a port (the
// TypeScript sender would use it and fail to connect).
//
pub fn parseIntLikeJavaScript(text: []const u8) ?u16 {
    const port = utils.js_number.parseInt(text, 10);
    if (std.math.isNan(port) or port < 0 or port > 65535) {
        return null;
    }
    return @intFromFloat(port);
}
