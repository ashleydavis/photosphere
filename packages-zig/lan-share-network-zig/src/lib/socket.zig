const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils-zig");

//
// The UDP and TCP sockets the LAN share sender and receiver use. This file has no TypeScript counterpart: it stands
// in for the parts of node:dgram and node:net that lan-share-sender.ts and lan-share-receiver.ts use. It calls the
// operating system's socket API directly (the C library's on Linux and macOS, Winsock on Windows) rather than
// std.Io.net, because the discovery socket needs SO_REUSEADDR on a UDP socket (Node's `reuseAddr: true`), which
// std.Io.net only offers for listening TCP sockets.
//
// Every wait is a poll with a timeout, so a caller can give up on a wait (a timeout or a cancel) without a second
// thread having to close the socket underneath it.
//

//
// Names used from other files (the equivalent of the TypeScript imports).
//
const errors = utils.errors;

//
// True on Windows, where the sockets are Winsock sockets.
//
const is_windows = builtin.os.tag == .windows;

//
// A socket handle: a Winsock SOCKET on Windows, a file descriptor elsewhere.
//
pub const Handle = if (is_windows) usize else std.c.fd_t;

//
// Winsock's address of a socket (sockaddr_in) and the C library's.
//
const SockaddrIn = if (is_windows) std.os.windows.ws2_32.sockaddr.in else std.c.sockaddr.in;

//
// Winsock's generic socket address.
//
const Sockaddr = if (is_windows) std.os.windows.ws2_32.sockaddr else std.c.sockaddr;

//
// Winsock's WSAPOLLFD.
//
const WsaPollFd = extern struct {
    // The socket to poll.
    fd: usize,

    // The events to wait for.
    events: i16,

    // The events that happened.
    revents: i16,
};

//
// The Winsock data WSAStartup fills in (WSADATA, 64-bit layout). Only its size matters here.
//
const WsaData = extern struct {
    // The Winsock version the caller will use.
    wVersion: u16,

    // The highest version this Winsock supports.
    wHighVersion: u16,

    // The number of sockets (not used since Winsock 2).
    iMaxSockets: u16,

    // The largest datagram (not used since Winsock 2).
    iMaxUdpDg: u16,

    // Vendor information (not used since Winsock 2).
    lpVendorInfo: ?*u8,

    // The description of the implementation.
    szDescription: [257]u8,

    // The status of the implementation.
    szSystemStatus: [129]u8,
};

//
// The Winsock functions used (ws2_32.dll).
//
const winsock = struct {
    // Starts Winsock for the process.
    extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WsaData) callconv(.winapi) c_int;

    // The error of the last failed Winsock call on this thread.
    extern "ws2_32" fn WSAGetLastError() callconv(.winapi) c_int;

    // Creates a socket.
    extern "ws2_32" fn socket(af: c_int, @"type": c_int, protocol: c_int) callconv(.winapi) usize;

    // Closes a socket.
    extern "ws2_32" fn closesocket(s: usize) callconv(.winapi) c_int;

    // Sets a socket option.
    extern "ws2_32" fn setsockopt(s: usize, level: c_int, optname: c_int, optval: [*]const u8, optlen: c_int) callconv(.winapi) c_int;

    // Binds a socket to an address.
    extern "ws2_32" fn bind(s: usize, name: *const Sockaddr, namelen: c_int) callconv(.winapi) c_int;

    // Starts listening for connections.
    extern "ws2_32" fn listen(s: usize, backlog: c_int) callconv(.winapi) c_int;

    // Accepts a connection.
    extern "ws2_32" fn accept(s: usize, addr: ?*Sockaddr, addrlen: ?*c_int) callconv(.winapi) usize;

    // Connects a socket to an address.
    extern "ws2_32" fn connect(s: usize, name: *const Sockaddr, namelen: c_int) callconv(.winapi) c_int;

    // Gets the address a socket is bound to.
    extern "ws2_32" fn getsockname(s: usize, name: *Sockaddr, namelen: *c_int) callconv(.winapi) c_int;

    // Receives a datagram and its sender.
    extern "ws2_32" fn recvfrom(s: usize, buf: [*]u8, len: c_int, flags: c_int, from: *Sockaddr, fromlen: *c_int) callconv(.winapi) c_int;

    // Sends a datagram to an address.
    extern "ws2_32" fn sendto(s: usize, buf: [*]const u8, len: c_int, flags: c_int, to: *const Sockaddr, tolen: c_int) callconv(.winapi) c_int;

    // Waits for sockets to be ready.
    extern "ws2_32" fn WSAPoll(fdArray: [*]WsaPollFd, fds: u32, timeout: c_int) callconv(.winapi) c_int;
};

//
// Winsock's INVALID_SOCKET.
//
const invalid_socket: usize = std.math.maxInt(usize);

//
// Winsock's POLLRDNORM | POLLRDBAND (POLLIN).
//
const winsock_pollin: i16 = 0x0100 | 0x0200;

//
// Set once WSAStartup has succeeded (Windows only).
//
var winsockStarted = std.atomic.Value(bool).init(false);

//
// An IPv4 address and port.
//
pub const IAddress = struct {
    // The four bytes of the address, in network order.
    address: [4]u8,

    // The port.
    port: u16,

    //
    // Formats the address as dotted decimal (e.g. "192.168.1.5").
    //
    pub fn format(self: IAddress, allocator: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{ self.address[0], self.address[1], self.address[2], self.address[3] });
    }
};

//
// A datagram received by receiveFrom.
//
pub const IDatagram = struct {
    // The bytes of the datagram, in the caller's buffer.
    data: []u8,

    // Who sent it.
    from: IAddress,
};

//
// Parses a dotted decimal IPv4 address.
//
pub fn parseAddress(text: []const u8, port: u16) !IAddress {
    const parsed = std.Io.net.Ip4Address.parse(text, port) catch {
        return errors.throwError("Invalid IPv4 address: {s}", .{text});
    };
    return .{ .address = parsed.bytes, .port = port };
}

//
// Throws the error of the last failed socket call, naming the call.
//
fn throwLastError(operation: []const u8) errors.ThrownError {
    if (is_windows) {
        return errors.throwError("{s} failed with Winsock error {d}", .{ operation, winsock.WSAGetLastError() });
    }
    return errors.throwError("{s} failed: {s}", .{ operation, @tagName(std.posix.errno(@as(c_int, -1))) });
}

//
// Starts Winsock once for the process (Windows only; nothing to do elsewhere).
//
fn ensureStarted() !void {
    if (!is_windows) {
        return;
    }
    if (winsockStarted.load(.acquire)) {
        return;
    }
    var data: WsaData = undefined;
    const result = winsock.WSAStartup(0x0202, &data);
    if (result != 0) {
        return errors.throwError("WSAStartup failed with Winsock error {d}", .{result});
    }
    winsockStarted.store(true, .release);
}

//
// Converts an address to the socket API's sockaddr_in.
//
fn toSockaddr(address: IAddress) SockaddrIn {
    return .{
        .port = std.mem.nativeToBig(u16, address.port),
        .addr = @bitCast(address.address),
    };
}

//
// Converts the socket API's sockaddr_in to an address.
//
fn fromSockaddr(sockaddr: SockaddrIn) IAddress {
    return .{
        .address = @bitCast(sockaddr.addr),
        .port = std.mem.bigToNative(u16, sockaddr.port),
    };
}

//
// Creates an IPv4 socket of a kind (SOCK_DGRAM or SOCK_STREAM).
//
fn create(kind: c_int) !Handle {
    try ensureStarted();
    if (is_windows) {
        const handle = winsock.socket(std.os.windows.ws2_32.AF.INET, kind, 0);
        if (handle == invalid_socket) {
            return throwLastError("socket");
        }
        return handle;
    }
    const handle = std.c.socket(std.c.AF.INET, @intCast(kind), 0);
    if (handle < 0) {
        return throwLastError("socket");
    }
    return handle;
}

//
// Sets a boolean socket option at the socket level.
//
fn setFlag(handle: Handle, option: u32, operation: []const u8) !void {
    const enabled: c_int = 1;
    if (is_windows) {
        if (winsock.setsockopt(handle, std.os.windows.ws2_32.SOL.SOCKET, @intCast(option), @ptrCast(&enabled), @sizeOf(c_int)) != 0) {
            return throwLastError(operation);
        }
        return;
    }
    if (std.c.setsockopt(handle, std.c.SOL.SOCKET, option, &enabled, @sizeOf(c_int)) != 0) {
        return throwLastError(operation);
    }
}

//
// Creates a UDP socket (dgram `createSocket("udp4")`). With reuseAddress, several sockets can bind the same port
// (dgram's `reuseAddr: true`, which libuv turns into SO_REUSEADDR, and SO_REUSEPORT on macOS). With allowBroadcast,
// the socket can send to 255.255.255.255 (dgram's `setBroadcast(true)`).
//
pub fn createUdp(reuseAddress: bool, allowBroadcast: bool) !Handle {
    const handle = try create(if (is_windows) std.os.windows.ws2_32.SOCK.DGRAM else std.c.SOCK.DGRAM);
    errdefer close(handle);
    if (reuseAddress) {
        try setFlag(handle, if (is_windows) std.os.windows.ws2_32.SO.REUSEADDR else std.c.SO.REUSEADDR, "setsockopt(SO_REUSEADDR)");
        if (builtin.os.tag == .macos) {
            try setFlag(handle, std.c.SO.REUSEPORT, "setsockopt(SO_REUSEPORT)");
        }
    }
    if (allowBroadcast) {
        try setFlag(handle, if (is_windows) std.os.windows.ws2_32.SO.BROADCAST else std.c.SO.BROADCAST, "setsockopt(SO_BROADCAST)");
    }
    return handle;
}

//
// Creates a TCP socket.
//
pub fn createTcp() !Handle {
    return create(if (is_windows) std.os.windows.ws2_32.SOCK.STREAM else std.c.SOCK.STREAM);
}

//
// Binds a socket to an address (port 0 for a port chosen by the system).
//
pub fn bind(handle: Handle, address: IAddress) !void {
    const sockaddr = toSockaddr(address);
    if (is_windows) {
        if (winsock.bind(handle, @ptrCast(&sockaddr), @sizeOf(SockaddrIn)) != 0) {
            return throwLastError("bind");
        }
        return;
    }
    if (std.c.bind(handle, @ptrCast(&sockaddr), @sizeOf(SockaddrIn)) != 0) {
        return throwLastError("bind");
    }
}

//
// Gets the port a socket is bound to (`server.address().port`).
//
pub fn localPort(handle: Handle) !u16 {
    var sockaddr: SockaddrIn = undefined;
    if (is_windows) {
        var length: c_int = @sizeOf(SockaddrIn);
        if (winsock.getsockname(handle, @ptrCast(&sockaddr), &length) != 0) {
            return throwLastError("getsockname");
        }
    }
    else {
        var length: std.c.socklen_t = @sizeOf(SockaddrIn);
        if (std.c.getsockname(handle, @ptrCast(&sockaddr), &length) != 0) {
            return throwLastError("getsockname");
        }
    }
    return fromSockaddr(sockaddr).port;
}

//
// Starts listening for connections on a bound TCP socket.
//
pub fn listen(handle: Handle) !void {
    if (is_windows) {
        if (winsock.listen(handle, 511) != 0) {
            return throwLastError("listen");
        }
        return;
    }
    if (std.c.listen(handle, 511) != 0) {
        return throwLastError("listen");
    }
}

//
// Waits up to timeoutMs for a socket to be readable (a datagram, a connection to accept, or data). Returns false
// when the time ran out.
//
pub fn waitReadable(handle: Handle, timeoutMs: i32) !bool {
    if (is_windows) {
        var pollFds = [1]WsaPollFd{.{ .fd = handle, .events = winsock_pollin, .revents = 0 }};
        const result = winsock.WSAPoll(&pollFds, 1, timeoutMs);
        if (result < 0) {
            return throwLastError("WSAPoll");
        }
        return result > 0;
    }
    var pollFds = [1]std.c.pollfd{.{ .fd = handle, .events = std.c.POLL.IN, .revents = 0 }};
    while (true) {
        const result = std.c.poll(&pollFds, 1, timeoutMs);
        if (result < 0) {
            if (std.posix.errno(result) == .INTR) {
                continue;
            }
            return throwLastError("poll");
        }
        return result > 0;
    }
}

//
// Accepts a connection on a listening socket (call it once waitReadable says one is waiting).
//
pub fn accept(handle: Handle) !Handle {
    if (is_windows) {
        const accepted = winsock.accept(handle, null, null);
        if (accepted == invalid_socket) {
            return throwLastError("accept");
        }
        return accepted;
    }
    const accepted = std.c.accept(handle, null, null);
    if (accepted < 0) {
        return throwLastError("accept");
    }
    return accepted;
}

//
// Connects a TCP socket to an address.
//
pub fn connect(handle: Handle, address: IAddress) !void {
    const sockaddr = toSockaddr(address);
    if (is_windows) {
        if (winsock.connect(handle, @ptrCast(&sockaddr), @sizeOf(SockaddrIn)) != 0) {
            return throwLastError("connect");
        }
        return;
    }
    if (std.c.connect(handle, @ptrCast(&sockaddr), @sizeOf(SockaddrIn)) != 0) {
        return throwLastError("connect");
    }
}

//
// Receives one datagram (call it once waitReadable says one is waiting).
//
pub fn receiveFrom(handle: Handle, buffer: []u8) !IDatagram {
    var sockaddr: SockaddrIn = undefined;
    if (is_windows) {
        var length: c_int = @sizeOf(SockaddrIn);
        const received = winsock.recvfrom(handle, buffer.ptr, @intCast(buffer.len), 0, @ptrCast(&sockaddr), &length);
        if (received < 0) {
            return throwLastError("recvfrom");
        }
        return .{ .data = buffer[0..@intCast(received)], .from = fromSockaddr(sockaddr) };
    }
    var length: std.c.socklen_t = @sizeOf(SockaddrIn);
    const received = std.c.recvfrom(handle, buffer.ptr, buffer.len, 0, @ptrCast(&sockaddr), &length);
    if (received < 0) {
        return throwLastError("recvfrom");
    }
    return .{ .data = buffer[0..@intCast(received)], .from = fromSockaddr(sockaddr) };
}

//
// Sends one datagram to an address (dgram `socket.send(message, 0, message.length, port, address)`).
//
pub fn sendTo(handle: Handle, data: []const u8, address: IAddress) !void {
    const sockaddr = toSockaddr(address);
    if (is_windows) {
        if (winsock.sendto(handle, data.ptr, @intCast(data.len), 0, @ptrCast(&sockaddr), @sizeOf(SockaddrIn)) < 0) {
            return throwLastError("sendto");
        }
        return;
    }
    if (std.c.sendto(handle, data.ptr, data.len, 0, @ptrCast(&sockaddr), @sizeOf(SockaddrIn)) < 0) {
        return throwLastError("sendto");
    }
}

//
// Closes a socket.
//
pub fn close(handle: Handle) void {
    if (is_windows) {
        _ = winsock.closesocket(handle);
        return;
    }
    _ = std.c.close(handle);
}
