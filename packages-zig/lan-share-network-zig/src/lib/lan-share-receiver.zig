const std = @import("std");
const utils = @import("utils-zig");
const encryption = @import("encryption-zig");
const lan_share_types = @import("lan-share-types.zig");
const lan_share_sender = @import("lan-share-sender.zig");
const socket = @import("socket.zig");
const https = @import("https.zig");

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const IPairingCodeHashResponse = lan_share_types.IPairingCodeHashResponse;
const generateKeyPairSync = encryption.node_crypto.generateKeyPairSync;
const createSign = encryption.node_crypto.createSign;
const sha256Hex = lan_share_sender.sha256Hex;
const errors = utils.errors;

//
// Maximum number of incoming requests before the receiver aborts (covers both endpoints).
// A legitimate share requires exactly one GET /pairing-code-hash and one POST /share-payload.
//
const MAX_REQUESTS = 5;

//
// Interval in milliseconds between UDP broadcast announcements.
//
const BROADCAST_INTERVAL_MS = 1000;

//
// UDP port used for discovery broadcasts.
//
const DISCOVERY_PORT: u16 = 54321;

//
// How long the receiver's threads wait at a time before checking whether the receive has finished (the event loop
// of the TypeScript receiver runs its timers and handlers between events).
//
const POLL_INTERVAL_MS: i32 = 100;

//
// How long a connection may sit idle between requests before it is closed (Node's http server's default
// keepAliveTimeout).
//
const KEEP_ALIVE_TIMEOUT_MS: i64 = 5000;

//
// Generates a self-signed TLS certificate and private key at runtime.
// Returns the PEM-encoded certificate, private key, and SHA-256 fingerprint.
//
pub const ISelfSignedCert = struct {
    // PEM-encoded certificate.
    cert: []const u8,

    // PEM-encoded private key.
    key: []const u8,

    // SHA-256 fingerprint of the certificate in hex.
    fingerprint: []const u8,
};

//
// Creates a self-signed TLS certificate for the HTTPS server.
//
pub fn generateSelfSignedCert(allocator: std.mem.Allocator, io: std.Io) !ISelfSignedCert {
    const keyPair = try generateKeyPairSync(allocator, io, 2048);

    // Node has no built-in certificate generator, so the certificate is built with a small inline ASN.1 builder.
    const cert = try buildSelfSignedCert(allocator, io, keyPair.publicKey, keyPair.privateKey);

    const fingerprint = sha256Hex(try extractDerFromPem(allocator, cert));

    return .{
        .cert = cert,
        .key = keyPair.privateKey,
        .fingerprint = try allocator.dupe(u8, &fingerprint),
    };
}

//
// Extracts the raw DER bytes from a PEM-encoded string.
//
pub fn extractDerFromPem(allocator: std.mem.Allocator, pem: []const u8) ![]u8 {
    var base64: std.ArrayList(u8) = .empty;
    var lines = std.mem.splitScalar(u8, pem, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "-----BEGIN ") or std.mem.startsWith(u8, line, "-----END ")) {
            continue;
        }
        for (line) |character| {
            if (!std.ascii.isWhitespace(character)) {
                try base64.append(allocator, character);
            }
        }
    }
    const decoder = std.base64.standard.Decoder;
    const der = try allocator.alloc(u8, try decoder.calcSizeForSlice(base64.items));
    try decoder.decode(der, base64.items);
    return der;
}

//
// Builds a minimal self-signed X.509 v3 certificate.
// This avoids any external dependency for certificate generation.
//
pub fn buildSelfSignedCert(allocator: std.mem.Allocator, io: std.Io, publicKeyPem: []const u8, privateKeyPem: []const u8) ![]const u8 {
    const publicKeyDer = try extractDerFromPem(allocator, publicKeyPem);
    const nowSeconds = @divFloor(std.Io.Clock.real.now(io).toMilliseconds(), 1000);
    const notBefore = nowSeconds;
    const notAfter = nowSeconds + 24 * 60 * 60; // 1 day validity

    // Build TBSCertificate
    const serialNumber = try encodeAsn1Integer(allocator, &.{1});
    const signatureAlgorithm = try encodeAsn1Sequence(allocator, &.{
        try encodeAsn1Oid(allocator, &.{ 1, 2, 840, 113549, 1, 1, 11 }), // sha256WithRSAEncryption
        encodeAsn1Null(),
    });
    const issuer = try encodeAsn1Sequence(allocator, &.{
        try encodeAsn1Set(allocator, &.{
            try encodeAsn1Sequence(allocator, &.{
                try encodeAsn1Oid(allocator, &.{ 2, 5, 4, 3 }), // commonName
                try encodeAsn1Utf8String(allocator, "Photosphere LAN Share"),
            }),
        }),
    });
    const validity = try encodeAsn1Sequence(allocator, &.{
        try encodeAsn1UtcTime(allocator, notBefore),
        try encodeAsn1UtcTime(allocator, notAfter),
    });
    const subject = issuer; // self-signed: subject = issuer

    // version [0] EXPLICIT INTEGER 2 (v3)
    const version = try encodeAsn1Explicit(allocator, 0, try encodeAsn1Integer(allocator, &.{2}));

    const tbsCertificate = try encodeAsn1Sequence(allocator, &.{
        version,
        serialNumber,
        signatureAlgorithm,
        issuer,
        validity,
        subject,
        publicKeyDer, // SubjectPublicKeyInfo (already a SEQUENCE)
    });

    // Sign the TBSCertificate
    var signer = try createSign(allocator, "SHA256");
    try signer.update(tbsCertificate);
    const signature = try signer.sign(allocator, privateKeyPem);

    // Build the full Certificate
    const certificate = try encodeAsn1Sequence(allocator, &.{
        tbsCertificate,
        signatureAlgorithm,
        try encodeAsn1BitString(allocator, signature),
    });

    // PEM-encode
    const encoder = std.base64.standard.Encoder;
    const base64Cert = try allocator.alloc(u8, encoder.calcSize(certificate.len));
    _ = encoder.encode(base64Cert, certificate);
    var lines: std.ArrayList([]const u8) = .empty;
    var offset: usize = 0;
    while (offset < base64Cert.len) {
        try lines.append(allocator, base64Cert[offset..@min(offset + 64, base64Cert.len)]);
        offset += 64;
    }
    return std.fmt.allocPrint(allocator, "-----BEGIN CERTIFICATE-----\n{s}\n-----END CERTIFICATE-----\n", .{try std.mem.join(allocator, "\n", lines.items)});
}

//
// ASN.1 DER encoding helpers.
//

//
// Encodes a DER length.
//
pub fn encodeAsn1Length(allocator: std.mem.Allocator, length: usize) ![]u8 {
    if (length < 0x80) {
        return allocator.dupe(u8, &.{@intCast(length)});
    }
    var bytes: std.ArrayList(u8) = .empty;
    var remaining = length;
    while (remaining > 0) {
        try bytes.insert(allocator, 0, @intCast(remaining & 0xff));
        remaining >>= 8;
    }
    try bytes.insert(allocator, 0, @intCast(0x80 | bytes.items.len));
    return bytes.items;
}

//
// Encodes a tag, its length and its content.
//
pub fn encodeAsn1Tag(allocator: std.mem.Allocator, tag: u8, content: []const u8) ![]u8 {
    return std.mem.concat(allocator, u8, &.{ &.{tag}, try encodeAsn1Length(allocator, content.len), content });
}

//
// Encodes a SEQUENCE of already encoded items.
//
pub fn encodeAsn1Sequence(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    return encodeAsn1Tag(allocator, 0x30, try std.mem.concat(allocator, u8, items));
}

//
// Encodes a SET of already encoded items.
//
pub fn encodeAsn1Set(allocator: std.mem.Allocator, items: []const []const u8) ![]u8 {
    return encodeAsn1Tag(allocator, 0x31, try std.mem.concat(allocator, u8, items));
}

//
// Encodes an INTEGER from its big-endian bytes.
//
pub fn encodeAsn1Integer(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    // Ensure leading zero if high bit is set
    if (value[0] & 0x80 != 0) {
        return encodeAsn1Tag(allocator, 0x02, try std.mem.concat(allocator, u8, &.{ &.{0}, value }));
    }
    return encodeAsn1Tag(allocator, 0x02, value);
}

//
// Encodes a BIT STRING.
//
pub fn encodeAsn1BitString(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    // Prepend unused-bits byte (0)
    const content = try std.mem.concat(allocator, u8, &.{ &.{0}, data });
    return encodeAsn1Tag(allocator, 0x03, content);
}

//
// Encodes NULL.
//
pub fn encodeAsn1Null() []const u8 {
    return &.{ 0x05, 0x00 };
}

//
// Encodes an OBJECT IDENTIFIER from its components.
//
pub fn encodeAsn1Oid(allocator: std.mem.Allocator, components: []const u32) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    // First two components are encoded as 40 * c0 + c1
    try bytes.append(allocator, @intCast(40 * components[0] + components[1]));
    for (components[2..]) |component| {
        if (component < 128) {
            try bytes.append(allocator, @intCast(component));
        }
        else {
            var encodedBytes: std.ArrayList(u8) = .empty;
            var remaining = component;
            try encodedBytes.insert(allocator, 0, @intCast(remaining & 0x7f));
            remaining >>= 7;
            while (remaining > 0) {
                try encodedBytes.insert(allocator, 0, @intCast((remaining & 0x7f) | 0x80));
                remaining >>= 7;
            }
            try bytes.appendSlice(allocator, encodedBytes.items);
        }
    }
    return encodeAsn1Tag(allocator, 0x06, bytes.items);
}

//
// Encodes a UTF8String.
//
pub fn encodeAsn1Utf8String(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    return encodeAsn1Tag(allocator, 0x0c, value);
}

//
// Encodes a UTCTime (YYMMDDHHMMSSZ) from seconds since the Unix epoch.
//
pub fn encodeAsn1UtcTime(allocator: std.mem.Allocator, epochSeconds: i64) ![]u8 {
    const seconds: std.time.epoch.EpochSeconds = .{ .secs = @intCast(epochSeconds) };
    const yearAndDay = seconds.getEpochDay().calculateYearDay();
    const monthAndDay = yearAndDay.calculateMonthDay();
    const daySeconds = seconds.getDaySeconds();
    const timeStr = try std.fmt.allocPrint(allocator, "{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}{d:0>2}Z", .{
        yearAndDay.year % 100,
        monthAndDay.month.numeric(),
        monthAndDay.day_index + 1,
        daySeconds.getHoursIntoDay(),
        daySeconds.getMinutesIntoHour(),
        daySeconds.getSecondsIntoMinute(),
    });
    return encodeAsn1Tag(allocator, 0x17, timeStr);
}

//
// Encodes a context-specific EXPLICIT tag around already encoded content.
//
pub fn encodeAsn1Explicit(allocator: std.mem.Allocator, tagNumber: u8, content: []const u8) ![]u8 {
    const tag = 0xa0 | tagNumber;
    return encodeAsn1Tag(allocator, tag, content);
}

//
// Hosts an HTTPS server on the LAN and broadcasts availability via UDP.
// Accepts a single payload delivery from a sender after pairing code verification.
//
// The server accepts connections on a thread of its own, serves each connection on a thread of its own, and
// broadcasts on another, where the TypeScript receiver has them all on Node's event loop. What they share is kept in
// atomics. Call deinit once finished with the receiver.
//
pub const LanShareReceiver = struct {
    // Allocates what the receiver keeps between calls and what its threads allocate (thread-safe).
    arena: std.heap.ArenaAllocator,

    // Guards the arena, which the threads share.
    arenaMutex: std.Io.Mutex,

    // The Io the threads sleep and wait with.
    io: std.Io,

    // Timeout in milliseconds before the receiver gives up waiting.
    timeoutMs: i64,

    // The pairing code (null until start).
    code: ?[]const u8,

    // SHA-256 hash of the pairing code, for comparison.
    codeHash: [64]u8,

    // The TLS settings of the HTTPS server (null until start).
    serverContext: ?https.ServerContext,

    // The HTTPS server's listening socket (null until start).
    httpsServer: ?socket.Handle,

    // The port the HTTPS server listens on (`httpsServer.address().port`).
    httpsPort: u16,

    // The UDP socket for broadcasting availability.
    udpSocket: ?socket.Handle,

    // The thread that accepts connections.
    serverThread: ?std.Thread,

    // The thread that broadcasts availability every BROADCAST_INTERVAL_MS.
    broadcastTimer: ?std.Thread,

    // The threads serving connections, joined when the receiver shuts down.
    connectionThreads: std.ArrayList(std.Thread),

    // Total number of incoming requests so far (across all endpoints).
    requestCount: std.atomic.Value(u32),

    // The delivered payload, set before isDone.
    payload: ?std.json.Value,

    // Whether the receiver has been cancelled or completed.
    isDone: std.atomic.Value(bool),

    // Set by the first call of complete, which is the one that counts.
    isCompleting: std.atomic.Value(bool),

    // Whether the threads and sockets have been shut down.
    isShutDown: bool,

    //
    // Creates the receiver (`new LanShareReceiver(timeoutMs)`).
    //
    pub fn init(io: std.Io, timeoutMs: i64) LanShareReceiver {
        return .{
            .arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator),
            .arenaMutex = .init,
            .io = io,
            .timeoutMs = timeoutMs,
            .code = null,
            .codeHash = undefined,
            .serverContext = null,
            .httpsServer = null,
            .httpsPort = 0,
            .udpSocket = null,
            .serverThread = null,
            .broadcastTimer = null,
            .connectionThreads = .empty,
            .requestCount = .init(0),
            .payload = null,
            .isDone = .init(false),
            .isCompleting = .init(false),
            .isShutDown = false,
        };
    }

    //
    // Shuts the receiver down (if receive has not already) and frees what it allocated, including the payload.
    //
    pub fn deinit(self: *LanShareReceiver) void {
        self.complete(null);
        self.shutdown();
        self.arena.deinit();
    }

    //
    // Allocates from the arena, which the threads share.
    //
    fn allocator(self: *LanShareReceiver) std.mem.Allocator {
        return self.arena.allocator();
    }

    //
    // Starts the receiver: stores the caller-supplied pairing code, creates an HTTPS server,
    // and begins broadcasting availability via UDP.
    // The pairing code is provided by the caller (entered by the user after reading it off the sender).
    //
    pub fn start(self: *LanShareReceiver, code: []const u8) !void {
        const arenaAllocator = self.allocator();
        self.code = try arenaAllocator.dupe(u8, code);
        self.codeHash = sha256Hex(code);

        const selfSigned = try generateSelfSignedCert(arenaAllocator, self.io);

        // Create HTTPS server
        self.serverContext = try https.ServerContext.init(selfSigned.cert, selfSigned.key);

        // Listen on a random port. Note: this server intentionally binds all network interfaces
        // (0.0.0.0) because its purpose is to serve paired devices over the LAN. This is
        // the sole deliberate exception to the loopback-only rule (binding 127.0.0.1) that every
        // other HTTP/REST server in the codebase follows.
        const httpsServer = try socket.createTcp();
        self.httpsServer = httpsServer;
        try socket.bind(httpsServer, .{ .address = .{ 0, 0, 0, 0 }, .port = 0 });
        try socket.listen(httpsServer);
        self.httpsPort = try socket.localPort(httpsServer);
        self.serverThread = try std.Thread.spawn(.{}, serve, .{self});

        // Start UDP broadcast
        const udpSocket = try socket.createUdp(false, true);
        self.udpSocket = udpSocket;
        try socket.bind(udpSocket, .{ .address = .{ 0, 0, 0, 0 }, .port = 0 });

        // The pairing code's hash is part of the announcement so a sender can tell whose
        // receiver this is before committing to it. Without it the announcement carried no
        // session identity at all, a sender took the first receiver it heard on the whole
        // subnet, and a mismatched pairing code ended that share permanently. Two shares
        // running at once, in two worktrees or on two machines, would take each other's halves.
        //
        // The hash goes before the fingerprint because a fingerprint can contain colons, so
        // anything after it cannot be parsed back out.
        //
        // This publishes nothing that was not already public: it is the same unsalted
        // sha256(code) that any caller can fetch from this receiver at GET /pairing-code-hash,
        // on a receiver that is already broadcasting its port to the whole subnet.
        const message = try std.fmt.allocPrint(arenaAllocator, "PSIE_RECV:{d}:{s}:{s}", .{ self.httpsPort, &self.codeHash, selfSigned.fingerprint });
        // Send first broadcast immediately
        self.broadcast(message);
        self.broadcastTimer = try std.Thread.spawn(.{}, broadcastEvery, .{ self, message });
    }

    //
    // Sends the announcement to the broadcast address and to loopback.
    //
    fn broadcast(self: *LanShareReceiver, message: []const u8) void {
        const udpSocket = self.udpSocket.?;
        // Discovery is best-effort. A failed broadcast or loopback send (for example an
        // ECONNREFUSED surfaced from an ICMP port-unreachable when no sender is listening on
        // 127.0.0.1 yet) must not stop the receiver, which still serves the transfer over its
        // HTTPS server (the TypeScript receiver's `error` handler ignores them).
        socket.sendTo(udpSocket, message, .{ .address = .{ 255, 255, 255, 255 }, .port = DISCOVERY_PORT }) catch {};
        // Also send to loopback so same-machine discovery works on macOS, where
        // 255.255.255.255 broadcasts are not reliably looped back between processes.
        socket.sendTo(udpSocket, message, .{ .address = .{ 127, 0, 0, 1 }, .port = DISCOVERY_PORT }) catch {};
    }

    //
    // The broadcast timer: sends the announcement every BROADCAST_INTERVAL_MS until the receive is done.
    //
    fn broadcastEvery(self: *LanShareReceiver, message: []const u8) void {
        var sinceLastBroadcast: i64 = 0;
        while (!self.isDone.load(.acquire)) {
            self.io.sleep(.fromMilliseconds(POLL_INTERVAL_MS), .awake) catch {
                return;
            };
            sinceLastBroadcast += POLL_INTERVAL_MS;
            if (sinceLastBroadcast >= BROADCAST_INTERVAL_MS and !self.isDone.load(.acquire)) {
                self.broadcast(message);
                sinceLastBroadcast = 0;
            }
        }
    }

    //
    // The server thread: accepts connections until the receive is done, serving each on a thread of its own. Then
    // it closes the listening socket (`httpsServer.close()` in complete()), so that a connection made after that is
    // refused rather than left waiting to be accepted.
    //
    fn serve(self: *LanShareReceiver) void {
        const httpsServer = self.httpsServer.?;
        defer {
            socket.close(httpsServer);
            self.httpsServer = null;
        }
        while (!self.isDone.load(.acquire)) {
            const readable = socket.waitReadable(httpsServer, POLL_INTERVAL_MS) catch |err| {
                utils.log.log.exception("The LAN share receiver stopped accepting connections.", err);
                self.complete(null);
                return;
            };
            if (!readable or self.isDone.load(.acquire)) {
                continue;
            }
            const accepted = socket.accept(httpsServer) catch {
                continue;
            };
            const thread = std.Thread.spawn(.{}, serveConnection, .{ self, accepted }) catch |err| {
                utils.log.log.exception("The LAN share receiver could not serve a connection.", err);
                socket.close(accepted);
                continue;
            };
            self.arenaMutex.lockUncancelable(self.io);
            defer self.arenaMutex.unlock(self.io);
            self.connectionThreads.append(self.allocator(), thread) catch |err| {
                std.debug.panic("Recording a LAN share connection thread failed: {s}", .{@errorName(err)});
            };
        }
    }

    //
    // Waits until a request arrives on an idle connection. Returns false when the receive finished or the
    // connection sat idle for KEEP_ALIVE_TIMEOUT_MS.
    //
    fn waitForRequest(self: *LanShareReceiver, connection: *https.Connection) bool {
        if (connection.hasBufferedInput()) {
            return true;
        }
        var idle: i64 = 0;
        while (!self.isDone.load(.acquire) and idle < KEEP_ALIVE_TIMEOUT_MS) {
            const readable = socket.waitReadable(connection.handle, POLL_INTERVAL_MS) catch {
                return false;
            };
            if (readable) {
                return !self.isDone.load(.acquire);
            }
            idle += POLL_INTERVAL_MS;
        }
        return false;
    }

    //
    // A connection thread: performs the TLS handshake and handles requests until the connection closes or the
    // receive is done.
    //
    fn serveConnection(self: *LanShareReceiver, handle: socket.Handle) void {
        const connection = https.Connection.accept(std.heap.smp_allocator, &self.serverContext.?, handle) catch {
            // A failed handshake (a port scan, a client that went away) only loses that connection, as with Node.
            return;
        };
        defer connection.close();
        var server = std.http.Server.init(&connection.reader, &connection.writer);
        while (self.waitForRequest(connection)) {
            var request = server.receiveHead() catch {
                return;
            };
            const keepServing = self.handleRequest(&request) catch {
                return;
            };
            if (!keepServing or !request.head.keep_alive) {
                return;
            }
        }
    }

    //
    // Waits for a valid payload to arrive from a sender.
    // Returns the payload on success, or null on timeout or cancellation. The payload belongs to the receiver
    // and is freed by deinit.
    //
    pub fn receive(self: *LanShareReceiver) !?std.json.Value {
        const deadline = std.Io.Clock.awake.now(self.io).toMilliseconds() + self.timeoutMs;
        while (!self.isDone.load(.acquire)) {
            if (std.Io.Clock.awake.now(self.io).toMilliseconds() >= deadline) {
                self.complete(null);
                break;
            }
            try self.io.sleep(.fromMilliseconds(20), .awake);
        }
        self.shutdown();
        return self.payload;
    }

    //
    // Cancels the receiver, cleaning up all resources.
    // The receive() call resolves with null. Safe to call from a signal handler or another thread: it only sets
    // flags, and the receiver's threads and receive() see them.
    //
    pub fn cancel(self: *LanShareReceiver) void {
        self.complete(null);
    }

    //
    // Writes a JSON response.
    //
    fn respondJson(request: *std.http.Server.Request, status: std.http.Status, body: []const u8) !void {
        try request.respond(body, .{
            .status = status,
            .extra_headers = &.{
                .{
                    .name = "Content-Type",
                    .value = "application/json",
                },
            },
        });
    }

    //
    // Handles an incoming HTTP request to the HTTPS server. Returns false when the connection should be closed.
    //
    fn handleRequest(self: *LanShareReceiver, request: *std.http.Server.Request) !bool {
        const requestCount = self.requestCount.fetchAdd(1, .acq_rel) + 1;
        if (requestCount > MAX_REQUESTS) {
            try respondJson(request, .too_many_requests, "{\"error\":\"Too many requests\"}");
            self.complete(null);
            return false;
        }

        if (request.head.method == .GET and std.mem.eql(u8, request.head.target, "/pairing-code-hash")) {
            const body: IPairingCodeHashResponse = .{ .codeHash = &self.codeHash };
            var bodyBuffer: [128]u8 = undefined;
            var bodyWriter = std.Io.Writer.fixed(&bodyBuffer);
            try std.json.Stringify.value(body, .{}, &bodyWriter);
            try respondJson(request, .ok, bodyWriter.buffered());
            return true;
        }

        if (request.head.method == .POST and std.mem.eql(u8, request.head.target, "/share-payload")) {
            var readBuffer: [4096]u8 = undefined;
            const bodyReader = try request.readerExpectContinue(&readBuffer);
            const rawBody = try bodyReader.allocRemaining(std.heap.smp_allocator, .unlimited);
            defer std.heap.smp_allocator.free(rawBody);

            self.arenaMutex.lockUncancelable(self.io);
            const parsed = std.json.parseFromSliceLeaky(std.json.Value, self.allocator(), rawBody, .{});
            self.arenaMutex.unlock(self.io);
            const shareRequest = parsed catch {
                try respondJson(request, .bad_request, "{\"error\":\"Invalid JSON\"}");
                return true;
            };

            const codeHash: ?std.json.Value = if (shareRequest == .object) shareRequest.object.get("codeHash") else null;
            if (codeHash == null or codeHash.? != .string or !std.mem.eql(u8, codeHash.?.string, &self.codeHash)) {
                try respondJson(request, .forbidden, "{\"error\":\"Invalid pairing code\"}");
                return true;
            }

            try respondJson(request, .ok, "{\"success\":true}");
            self.complete(shareRequest.object.get("payload"));
            return true;
        }

        try respondJson(request, .not_found, "{\"error\":\"Not found\"}");
        return true;
    }

    //
    // Completes the receive operation: records the payload and tells the threads and receive() to finish. Only the
    // first call counts.
    //
    fn complete(self: *LanShareReceiver, payload: ?std.json.Value) void {
        if (self.isCompleting.swap(true, .acq_rel)) {
            return;
        }
        // A JSON null payload is no payload, as `if (!rawPayload)` treats it.
        if (payload != null and payload.? != .null) {
            self.payload = payload;
        }
        self.isDone.store(true, .release);
    }

    //
    // Waits for the threads to finish and closes the sockets and the TLS settings (the cleanup of complete()).
    //
    fn shutdown(self: *LanShareReceiver) void {
        if (self.isShutDown) {
            return;
        }
        self.isShutDown = true;

        if (self.broadcastTimer) |thread| {
            thread.join();
            self.broadcastTimer = null;
        }

        if (self.serverThread) |thread| {
            thread.join();
            self.serverThread = null;
        }

        for (self.connectionThreads.items) |thread| {
            thread.join();
        }
        self.connectionThreads.clearRetainingCapacity();

        if (self.udpSocket) |udpSocket| {
            socket.close(udpSocket);
            self.udpSocket = null;
        }

        if (self.httpsServer) |httpsServer| {
            socket.close(httpsServer);
            self.httpsServer = null;
        }

        if (self.serverContext) |*serverContext| {
            serverContext.deinit();
            self.serverContext = null;
        }
    }
};
