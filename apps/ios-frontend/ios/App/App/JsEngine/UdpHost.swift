import Foundation

//
// The native UDP datagram layer behind the three host.udp* functions. The embedded engine cannot open
// UDP sockets, which LAN-share discovery needs (the receiver broadcasts its availability and the sender
// listens for it). This binds a POSIX UDP socket, receives datagrams on a background queue, and pushes
// inbound "message" events onto a thread-safe queue the engine drains on its JSContext thread and
// delivers into the JS dgram shim via globalThis.__udpEvent. Outbound sends are driven synchronously.
//
// Mirrors the Android UdpHost and the iOS TcpHost structure: JS-facing calls (udpBind/udpSend/udpClose)
// run on the engine queue; the receive loop runs on its own queue and only touches the synchronized
// collections and the event queue, never the JSContext.
//
final class UdpHost {

    //
    // Serializes access to the sockets and event collections.
    //
    private let lock = NSLock()

    //
    // Open sockets keyed by socket id.
    //
    private var sockets: [String: Int32] = [:]

    //
    // Pending inbound event JSON strings, drained by the engine on its JSContext thread.
    //
    private var inboundEvents: [String] = []

    //
    // Monotonic source of socket ids.
    //
    private var nextId: Int = 1

    //
    // True once shutdown has been requested, so receive loops exit.
    //
    private var shuttingDown = false

    //
    // Invoked (off the engine thread) whenever an inbound event is enqueued, so the engine can drain and
    // deliver events on its JSContext thread. Set by the engine after the host bridge is built.
    //
    var onEventAvailable: (() -> Void)?

    //
    // Background queue running the per-socket receive loops.
    //
    private let receiveQueue = DispatchQueue(label: "photosphere.udp.receive", attributes: .concurrent)

    //
    // Allocates the next id with the given prefix under the lock.
    //
    private func makeId(_ prefix: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        let id = "\(prefix)\(nextId)"
        nextId += 1
        return id
    }

    //
    // host.udpBind(host, port, broadcast): binds a UDP socket (broadcast enabled when requested, address
    // reuse always on) and starts receiving on a background queue. Returns a JSON string
    // { socketId, port } with the actual bound port, or an error envelope on failure.
    //
    func udpBind(host: String, port: Int, broadcast: Bool) -> String {
        let udpSocket = socket(AF_INET, SOCK_DGRAM, 0)
        if udpSocket < 0 {
            return HostBridge.hostErrorEnvelope(NSError(domain: "udp", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed"]))
        }

        var reuse: Int32 = 1
        setsockopt(udpSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        if broadcast {
            var enableBroadcast: Int32 = 1
            setsockopt(udpSocket, SOL_SOCKET, SO_BROADCAST, &enableBroadcast, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = host.isEmpty || host == "0.0.0.0" ? INADDR_ANY.bigEndian : inet_addr(host)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(udpSocket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            close(udpSocket)
            return HostBridge.hostErrorEnvelope(NSError(domain: "udp", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "bind() failed"]))
        }

        // Read back the actually bound port (resolves port 0 to the OS-assigned port).
        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                _ = getsockname(udpSocket, sockaddrPointer, &boundLength)
            }
        }
        let boundPort = UInt16(bigEndian: boundAddress.sin_port)

        let socketId = makeId("U")
        lock.lock()
        sockets[socketId] = udpSocket
        lock.unlock()

        receiveQueue.async { [weak self] in
            self?.receiveLoop(socketId: socketId, udpSocket: udpSocket)
        }

        return "{\"socketId\":\"\(socketId)\",\"port\":\(Int(boundPort))}"
    }

    //
    // Receives datagrams until the socket is closed, enqueuing a "message" event (sender address/port and
    // base64 payload) per datagram.
    //
    private func receiveLoop(socketId: String, udpSocket: Int32) {
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            var senderAddress = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bytesRead = withUnsafeMutablePointer(to: &senderAddress) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    recvfrom(udpSocket, &buffer, bufferSize, 0, sockaddrPointer, &senderLength)
                }
            }
            if bytesRead < 0 {
                break
            }

            let data = Data(bytes: buffer, count: bytesRead)
            let base64 = data.base64EncodedString()
            let senderIp = String(cString: inet_ntoa(senderAddress.sin_addr))
            let senderPort = Int(UInt16(bigEndian: senderAddress.sin_port))
            enqueue("{\"kind\":\"message\",\"socketId\":\"\(socketId)\",\"address\":\"\(HostBridge.jsonEscape(senderIp))\",\"port\":\(senderPort),\"base64\":\"\(base64)\"}")
        }
    }

    //
    // host.udpSend(socketId, base64, host, port): sends base64-decoded bytes as a datagram to host/port.
    // Returns nil on success or an error envelope on failure.
    //
    func udpSend(socketId: String, base64: String, host: String, port: Int) -> String? {
        lock.lock()
        let udpSocket = sockets[socketId]
        lock.unlock()
        guard let udpSocket = udpSocket else {
            return nil
        }
        guard let data = Data(base64Encoded: base64) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "udp", code: 0, userInfo: [NSLocalizedDescriptionKey: "invalid base64"]))
        }

        var destination = sockaddr_in()
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = in_port_t(UInt16(port)).bigEndian
        destination.sin_addr.s_addr = host == "255.255.255.255" ? INADDR_BROADCAST.bigEndian : inet_addr(host)

        let sent: Int = data.withUnsafeBytes { rawBuffer -> Int in
            let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            return withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    sendto(udpSocket, base, data.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            return HostBridge.hostErrorEnvelope(NSError(domain: "udp", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "sendto() failed"]))
        }
        return nil
    }

    //
    // host.udpClose(socketId): closes a UDP socket.
    //
    func udpClose(socketId: String) -> String? {
        lock.lock()
        let udpSocket = sockets.removeValue(forKey: socketId)
        lock.unlock()
        if let udpSocket = udpSocket {
            close(udpSocket)
        }
        return nil
    }

    //
    // Returns the next inbound event JSON without blocking, or nil when none is queued.
    //
    func pollInboundEvent() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if inboundEvents.isEmpty {
            return nil
        }
        return inboundEvents.removeFirst()
    }

    //
    // Returns true while any UDP socket is still open (so the engine keeps a discovery task alive).
    //
    func hasLiveSockets() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !sockets.isEmpty
    }

    //
    // Enqueues an inbound event JSON and notifies the engine to drain it on the JSContext thread.
    //
    private func enqueue(_ eventJson: String) {
        lock.lock()
        inboundEvents.append(eventJson)
        lock.unlock()
        onEventAvailable?()
    }

    //
    // Closes all sockets and clears the queue. Called when the engine is disposed.
    //
    func shutdown() {
        lock.lock()
        shuttingDown = true
        let udpSockets = Array(sockets.values)
        sockets.removeAll()
        inboundEvents.removeAll()
        lock.unlock()
        for udpSocket in udpSockets {
            close(udpSocket)
        }
    }
}
