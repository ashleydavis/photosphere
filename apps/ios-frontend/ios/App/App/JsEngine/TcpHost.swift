import Foundation

//
// The native TCP socket layer behind the four host.tcp* functions on iOS. The embedded engine cannot
// open or accept TCP connections in JavaScript, so this binds a loopback POSIX listener, accepts
// connections, and reads bytes on background queues. Inbound events (a new connection, received bytes,
// a closed connection) are pushed onto a thread-safe queue; whenever an event is enqueued the
// `onEventAvailable` closure is invoked so the engine can drain the queue on its JSContext thread and
// deliver each event into the JS net shim via globalThis.__tcpEvent. Outbound writes and closes are
// driven synchronously from the running handler.
//
// One TcpHost belongs to one engine context (the one running the long-lived asset-server task). The
// JS-facing calls (tcpListen/tcpWrite/tcpClose/tcpStopListening) run on the engine queue; the
// accept/read work runs on its own queues and only touches the synchronized collections and the
// event queue, never the JSContext.
//
final class TcpHost {

    //
    // Serializes access to the listeners/connections/event collections.
    //
    private let lock = NSLock()

    //
    // Open listener sockets keyed by listener id.
    //
    private var listeners: [String: Int32] = [:]

    //
    // Accepted connection sockets keyed by connection id.
    //
    private var connections: [String: Int32] = [:]

    //
    // Pending inbound event JSON strings, drained by the engine on its JSContext thread.
    //
    private var inboundEvents: [String] = []

    //
    // Monotonic source of listener / connection ids.
    //
    private var nextId: Int = 1

    //
    // True once shutdown has been requested, so accept/read loops exit.
    //
    private var shuttingDown = false

    //
    // Invoked (off the engine thread) whenever an inbound event is enqueued, so the engine can drain
    // and deliver events on its JSContext thread. Set by the engine after the host bridge is built.
    //
    var onEventAvailable: (() -> Void)?

    //
    // Background queue running the accept loops.
    //
    private let acceptQueue = DispatchQueue(label: "photosphere.tcp.accept", attributes: .concurrent)

    //
    // Background queue running the per-connection read loops.
    //
    private let readQueue = DispatchQueue(label: "photosphere.tcp.read", attributes: .concurrent)

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
    // host.tcpListen(host, port): binds a loopback TCP listener (port 0 = OS-assigned) and starts
    // accepting connections on a background queue. Returns a JSON string { listenerId, port } with the
    // actual bound port, or an error envelope on failure.
    //
    func tcpListen(host: String, port: Int) -> String {
        let listenSocket = socket(AF_INET, SOCK_STREAM, 0)
        if listenSocket < 0 {
            return HostBridge.hostErrorEnvelope(NSError(domain: "tcp", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed"]))
        }

        var reuse: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listenSocket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindResult < 0 {
            close(listenSocket)
            return HostBridge.hostErrorEnvelope(NSError(domain: "tcp", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "bind() failed"]))
        }

        if listen(listenSocket, 16) < 0 {
            close(listenSocket)
            return HostBridge.hostErrorEnvelope(NSError(domain: "tcp", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "listen() failed"]))
        }

        // Read back the actually bound port (resolves port 0 to the OS-assigned port).
        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                _ = getsockname(listenSocket, sockaddrPointer, &boundLength)
            }
        }
        let boundPort = UInt16(bigEndian: boundAddress.sin_port)

        let listenerId = makeId("L")
        lock.lock()
        listeners[listenerId] = listenSocket
        lock.unlock()

        acceptQueue.async { [weak self] in
            self?.acceptLoop(listenerId: listenerId, listenSocket: listenSocket)
        }

        return "{\"listenerId\":\"\(listenerId)\",\"port\":\(Int(boundPort))}"
    }

    //
    // Accepts connections until the listener is closed. Each accepted connection is registered, a
    // "connection" event is enqueued (before the read loop starts, so the JS server registers the
    // socket before any data arrives), then a read loop streams its inbound bytes.
    //
    private func acceptLoop(listenerId: String, listenSocket: Int32) {
        while true {
            lock.lock()
            let stop = shuttingDown || listeners[listenerId] == nil
            lock.unlock()
            if stop {
                return
            }

            let connectionSocket = accept(listenSocket, nil, nil)
            if connectionSocket < 0 {
                return
            }

            let connectionId = makeId("C")
            lock.lock()
            connections[connectionId] = connectionSocket
            lock.unlock()

            enqueue("{\"kind\":\"connection\",\"listenerId\":\"\(listenerId)\",\"connectionId\":\"\(connectionId)\"}")

            readQueue.async { [weak self] in
                self?.readLoop(connectionId: connectionId, connectionSocket: connectionSocket)
            }
        }
    }

    //
    // Reads inbound bytes from one connection, enqueuing a base64 "data" event per chunk, then a
    // "close" event when the remote closes or the read fails.
    //
    private func readLoop(connectionId: String, connectionSocket: Int32) {
        let bufferSize = 16 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while true {
            let bytesRead = read(connectionSocket, &buffer, bufferSize)
            if bytesRead <= 0 {
                break
            }
            let data = Data(bytes: buffer, count: bytesRead)
            let base64 = data.base64EncodedString()
            enqueue("{\"kind\":\"data\",\"connectionId\":\"\(connectionId)\",\"base64\":\"\(base64)\"}")
        }
        enqueue("{\"kind\":\"close\",\"connectionId\":\"\(connectionId)\"}")
    }

    //
    // host.tcpWrite(connectionId, base64): writes base64-decoded bytes to an accepted connection.
    // Returns nil on success or an error envelope on failure.
    //
    func tcpWrite(connectionId: String, base64: String) -> String? {
        lock.lock()
        let connectionSocket = connections[connectionId]
        lock.unlock()
        guard let connectionSocket = connectionSocket else {
            return nil
        }
        guard let data = Data(base64Encoded: base64) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "tcp", code: 0, userInfo: [NSLocalizedDescriptionKey: "invalid base64"]))
        }

        var totalWritten = 0
        let result: Int = data.withUnsafeBytes { rawBuffer -> Int in
            let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress!
            while totalWritten < data.count {
                let written = write(connectionSocket, base + totalWritten, data.count - totalWritten)
                if written <= 0 {
                    return -1
                }
                totalWritten += written
            }
            return totalWritten
        }
        if result < 0 {
            return HostBridge.hostErrorEnvelope(NSError(domain: "tcp", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "write() failed"]))
        }
        return nil
    }

    //
    // host.tcpClose(connectionId): closes one accepted connection.
    //
    func tcpClose(connectionId: String) -> String? {
        lock.lock()
        let connectionSocket = connections.removeValue(forKey: connectionId)
        lock.unlock()
        if let connectionSocket = connectionSocket {
            close(connectionSocket)
        }
        return nil
    }

    //
    // host.tcpStopListening(listenerId): closes a listener so it accepts no further connections.
    //
    func tcpStopListening(listenerId: String) -> String? {
        lock.lock()
        let listenSocket = listeners.removeValue(forKey: listenerId)
        lock.unlock()
        if let listenSocket = listenSocket {
            close(listenSocket)
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
    // Returns true while any listener is still open (i.e. a server task is running).
    //
    func hasLiveListeners() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !listeners.isEmpty
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
    // Closes all listeners and connections and clears the queue. Called when the engine is disposed.
    //
    func shutdown() {
        lock.lock()
        shuttingDown = true
        let listenSockets = Array(listeners.values)
        let connectionSockets = Array(connections.values)
        listeners.removeAll()
        connections.removeAll()
        inboundEvents.removeAll()
        lock.unlock()
        for listenSocket in listenSockets {
            close(listenSocket)
        }
        for connectionSocket in connectionSockets {
            close(connectionSocket)
        }
    }
}
