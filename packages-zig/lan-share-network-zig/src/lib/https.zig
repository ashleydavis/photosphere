const std = @import("std");
const utils = @import("utils-zig");
const c = @import("openssl");
const socket = @import("socket.zig");

//
// The TLS connections of the LAN share HTTPS server and client. This file has no TypeScript counterpart: it stands
// in for the parts of node:https (and node:tls) that lan-share-sender.ts and lan-share-receiver.ts use, over
// aws-lc's libssl (Node's https is OpenSSL's libssl). A connection is exposed as a std.Io.Reader and std.Io.Writer,
// so that the HTTP messages are read and written by std.http, as Node's http module reads and writes them.
//

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const errors = utils.errors;

//
// The size of each connection's read and write buffers. The read buffer must hold a whole HTTP head (std.http).
//
const buffer_size = 16 * 1024;

//
// Throws the oldest error on libssl's error queue, naming the operation, and clears the queue.
//
fn throwSslError(operation: []const u8) errors.ThrownError {
    const packedError = c.ERR_get_error();
    c.ERR_clear_error();
    if (packedError == 0) {
        return errors.throwError("{s} failed", .{operation});
    }
    var text: [256]u8 = undefined;
    _ = c.ERR_error_string_n(packedError, &text, text.len);
    return errors.throwError("{s} failed: {s}", .{ operation, std.mem.sliceTo(&text, 0) });
}

//
// Opens a read-only memory BIO over text.
//
fn openMemoryBio(text: []const u8) !*c.BIO {
    return c.BIO_new_mem_buf(text.ptr, @intCast(text.len)) orelse {
        return throwSslError("BIO_new_mem_buf");
    };
}

//
// The TLS settings of an HTTPS server: its certificate and private key (`https.createServer({ key, cert })`).
//
pub const ServerContext = struct {
    // The libssl context the server's connections are made from.
    context: *c.SSL_CTX,

    //
    // Creates the server settings from a PEM certificate and a PEM private key.
    //
    pub fn init(certificatePem: []const u8, privateKeyPem: []const u8) !ServerContext {
        c.ERR_clear_error();
        const context = c.SSL_CTX_new(c.TLS_server_method()) orelse {
            return throwSslError("SSL_CTX_new");
        };
        errdefer c.SSL_CTX_free(context);

        const certificateBio = try openMemoryBio(certificatePem);
        defer _ = c.BIO_free(certificateBio);
        const certificate = c.PEM_read_bio_X509(certificateBio, null, null, null) orelse {
            return throwSslError("PEM_read_bio_X509");
        };
        defer c.X509_free(certificate);
        if (c.SSL_CTX_use_certificate(context, certificate) != 1) {
            return throwSslError("SSL_CTX_use_certificate");
        }

        const keyBio = try openMemoryBio(privateKeyPem);
        defer _ = c.BIO_free(keyBio);
        const key = c.PEM_read_bio_PrivateKey(keyBio, null, null, null) orelse {
            return throwSslError("PEM_read_bio_PrivateKey");
        };
        defer c.EVP_PKEY_free(key);
        if (c.SSL_CTX_use_PrivateKey(context, key) != 1) {
            return throwSslError("SSL_CTX_use_PrivateKey");
        }
        return .{ .context = context };
    }

    //
    // Frees the settings.
    //
    pub fn deinit(self: *ServerContext) void {
        c.SSL_CTX_free(self.context);
    }
};

//
// A TLS connection over a TCP socket, read and written through `reader` and `writer`.
//
pub const Connection = struct {
    // Allocates the connection.
    allocator: std.mem.Allocator,

    // The libssl connection.
    ssl: *c.SSL,

    // The client-side context, owned by the connection (null for a server connection, whose context is the
    // server's).
    clientContext: ?*c.SSL_CTX,

    // The TCP socket, closed with the connection.
    handle: socket.Handle,

    // Reads the decrypted bytes.
    reader: std.Io.Reader,

    // Writes bytes to encrypt.
    writer: std.Io.Writer,

    //
    // Creates a connection over a socket from a libssl context, set up but not yet handshaken.
    //
    fn create(allocator: std.mem.Allocator, context: *c.SSL_CTX, clientContext: ?*c.SSL_CTX, handle: socket.Handle) !*Connection {
        const ssl = c.SSL_new(context) orelse {
            return throwSslError("SSL_new");
        };
        errdefer c.SSL_free(ssl);
        if (c.SSL_set_fd(ssl, @intCast(handle)) != 1) {
            return throwSslError("SSL_set_fd");
        }
        const connection = try allocator.create(Connection);
        connection.* = .{
            .allocator = allocator,
            .ssl = ssl,
            .clientContext = clientContext,
            .handle = handle,
            .reader = .{
                .vtable = &.{
                    .stream = stream,
                },
                .buffer = try allocator.alloc(u8, buffer_size),
                .seek = 0,
                .end = 0,
            },
            .writer = .{
                .vtable = &.{
                    .drain = drain,
                },
                .buffer = try allocator.alloc(u8, buffer_size),
            },
        };
        return connection;
    }

    //
    // Performs the server side of the TLS handshake on an accepted socket. The socket is closed if it fails.
    //
    pub fn accept(allocator: std.mem.Allocator, server: *const ServerContext, handle: socket.Handle) !*Connection {
        errdefer socket.close(handle);
        c.ERR_clear_error();
        const connection = try create(allocator, server.context, null, handle);
        errdefer c.SSL_free(connection.ssl);
        if (c.SSL_accept(connection.ssl) != 1) {
            return throwSslError("SSL_accept");
        }
        return connection;
    }

    //
    // Connects to an HTTPS server and performs the client side of the TLS handshake, without verifying the server's
    // certificate (`rejectUnauthorized: false`: the caller pins it by its fingerprint instead).
    //
    pub fn connect(allocator: std.mem.Allocator, address: socket.IAddress) !*Connection {
        c.ERR_clear_error();
        const handle = try socket.createTcp();
        errdefer socket.close(handle);
        try socket.connect(handle, address);
        const context = c.SSL_CTX_new(c.TLS_client_method()) orelse {
            return throwSslError("SSL_CTX_new");
        };
        errdefer c.SSL_CTX_free(context);
        c.SSL_CTX_set_verify(context, c.SSL_VERIFY_NONE, null);
        const connection = try create(allocator, context, context, handle);
        errdefer c.SSL_free(connection.ssl);
        if (c.SSL_connect(connection.ssl) != 1) {
            return throwSslError("SSL_connect");
        }
        return connection;
    }

    //
    // The DER bytes of the certificate the other end presented (`tlsSocket.getPeerCertificate().raw`).
    //
    pub fn peerCertificateDer(self: *Connection, allocator: std.mem.Allocator) ![]u8 {
        const certificate = c.SSL_get_peer_certificate(self.ssl) orelse {
            return errors.throwError("The server presented no certificate", .{});
        };
        defer c.X509_free(certificate);
        var der: [*c]u8 = null;
        const length = c.i2d_X509(certificate, &der);
        if (length <= 0) {
            return throwSslError("i2d_X509");
        }
        defer c.OPENSSL_free(der);
        return allocator.dupe(u8, der[0..@intCast(length)]);
    }


    //
    // True when decrypted bytes are waiting to be read (in the reader's buffer or in libssl's), so a read will not
    // wait for the socket.
    //
    pub fn hasBufferedInput(self: *Connection) bool {
        return self.reader.bufferedLen() > 0 or c.SSL_pending(self.ssl) > 0;
    }
    //
    // Shuts the TLS session down and closes the socket.
    //
    pub fn close(self: *Connection) void {
        _ = c.SSL_shutdown(self.ssl);
        c.SSL_free(self.ssl);
        if (self.clientContext) |context| {
            c.SSL_CTX_free(context);
        }
        socket.close(self.handle);
        self.allocator.free(self.reader.buffer);
        self.allocator.free(self.writer.buffer);
        self.allocator.destroy(self);
    }

    //
    // std.Io.Reader.stream: reads decrypted bytes (SSL_read). A closed connection is the end of the stream.
    //
    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Connection = @alignCast(@fieldParentPtr("reader", reader));
        const destination = limit.slice(try writer.writableSliceGreedy(1));
        const readLength: c_int = @intCast(@min(destination.len, std.math.maxInt(c_int)));
        const count = c.SSL_read(self.ssl, destination.ptr, readLength);
        if (count <= 0) {
            const reason = c.SSL_get_error(self.ssl, count);
            c.ERR_clear_error();
            if (reason == c.SSL_ERROR_ZERO_RETURN or reason == c.SSL_ERROR_SYSCALL) {
                return error.EndOfStream;
            }
            return error.ReadFailed;
        }
        writer.advance(@intCast(count));
        return @intCast(count);
    }

    //
    // Writes all of the bytes (SSL_write).
    //
    fn writeAll(self: *Connection, bytes: []const u8) std.Io.Writer.Error!void {
        var offset: usize = 0;
        while (offset < bytes.len) {
            const writeLength: c_int = @intCast(@min(bytes.len - offset, std.math.maxInt(c_int)));
            const count = c.SSL_write(self.ssl, bytes[offset..].ptr, writeLength);
            if (count <= 0) {
                c.ERR_clear_error();
                return error.WriteFailed;
            }
            offset += @intCast(count);
        }
    }

    //
    // std.Io.Writer.drain: encrypts and sends the buffered bytes, then the data (the last slice `splat` times).
    //
    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *Connection = @alignCast(@fieldParentPtr("writer", writer));
        try self.writeAll(writer.buffered());
        writer.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.writeAll(bytes);
            written += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try self.writeAll(last);
            written += last.len;
        }
        return written;
    }
};

//
// The response to a request made with `request`.
//
pub const IResponse = struct {
    // The HTTP status code.
    statusCode: u16,

    // The body, as text.
    body: []const u8,
};

//
// Makes one HTTPS request on a connection and reads the response (`https.request(options, callback)` with the
// response's data collected until its end). The request asks for the connection to be closed after it.
//
pub fn request(allocator: std.mem.Allocator, connection: *Connection, host: []const u8, method: []const u8, path: []const u8, requestBody: ?[]const u8) !IResponse {
    const writer = &connection.writer;
    try writer.print("{s} {s} HTTP/1.1\r\nHost: {s}\r\nConnection: close\r\n", .{ method, path, host });
    if (requestBody) |body| {
        try writer.print("Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n", .{body.len});
        try writer.writeAll(body);
    }
    else {
        try writer.writeAll("\r\n");
    }
    try writer.flush();

    var httpReader: std.http.Reader = .{
        .in = &connection.reader,
        .state = .ready,
        .interface = undefined,
        .max_head_len = connection.reader.buffer.len,
    };
    const headBytes = try httpReader.receiveHead();
    const head = try std.http.Client.Response.Head.parse(headBytes);
    const statusCode: u16 = @intFromEnum(head.status);
    var bodyBuffer: [buffer_size]u8 = undefined;
    const bodyReader = httpReader.bodyReader(&bodyBuffer, head.transfer_encoding, head.content_length);
    const body = try bodyReader.allocRemaining(allocator, .unlimited);
    return .{ .statusCode = statusCode, .body = body };
}
