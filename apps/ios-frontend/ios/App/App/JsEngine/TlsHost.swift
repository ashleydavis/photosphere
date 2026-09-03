import Foundation
import Network
import Security

//
// The native TLS layer behind the five host.tls* functions, built on Network.framework. LAN-share's
// receiver runs an HTTPS server with a runtime self-signed cert, and its sender connects with
// certificate pinning; the embedded engine cannot perform a TLS handshake, so this class provides both
// a TLS server (built from the PEM cert/key the TypeScript generates) and a cert-capturing TLS client.
// It mirrors TcpHost/the Android TlsHost over TLS: inbound connection/data/close events are queued for
// the engine's JSContext thread and delivered into the JS tls shim via globalThis.__tlsEvent; writes and
// closes are driven synchronously.
//
// One TlsHost belongs to one engine context. JS-facing calls run on the engine queue; NWListener /
// NWConnection callbacks run on the private networkQueue and only touch the synchronized collections and
// the event queue, never the JSContext.
//
final class TlsHost {

    //
    // Serializes access to the listeners/connections/event collections.
    //
    private let lock = NSLock()

    //
    // Open listeners keyed by listener id.
    //
    private var listeners: [String: NWListener] = [:]

    //
    // The keychain label used to import each listener's identity, kept so the items can be removed when
    // the listener stops (the private key and certificate are added to the keychain to form a SecIdentity).
    //
    private var listenerKeychainLabels: [String: String] = [:]

    //
    // Open connections (accepted or client) keyed by connection id.
    //
    private var connections: [String: NWConnection] = [:]

    //
    // Monotonic source of listener / connection ids.
    //
    private var nextId: Int = 1

    //
    // Pending inbound event JSON strings, drained by the engine on its JSContext thread.
    //
    private var inboundEvents: [String] = []

    //
    // Invoked (off the engine thread) whenever an inbound event is enqueued, so the engine can drain and
    // deliver events on its JSContext thread. Set by the engine after the host bridge is built.
    //
    var onEventAvailable: (() -> Void)?

    //
    // The queue Network.framework runs listener/connection callbacks on.
    //
    private let networkQueue = DispatchQueue(label: "photosphere.tls.network", attributes: .concurrent)

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
    // host.tlsListen(host, port, certPem, keyPem): builds a TLS server identity from the PEM cert/key,
    // binds a loopback listener (port 0 = OS-assigned), and starts accepting on the network queue.
    // Returns a JSON string { listenerId, port } with the actual bound port, or an error envelope.
    //
    func tlsListen(host: String, port: Int, certPem: String, keyPem: String) -> String {
        let keychainLabel = "photosphere-tls-\(UUID().uuidString)"
        guard let identity = makeServerIdentity(certPem: certPem, keyPem: keyPem, keychainLabel: keychainLabel) else {
            deleteKeychainItems(label: keychainLabel)
            return HostBridge.hostErrorEnvelope(NSError(domain: "tls", code: 0, userInfo: [NSLocalizedDescriptionKey: "tlsListen: could not build a server identity from the cert/key"]))
        }

        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, identity)

        let parameters = NWParameters(tls: tlsOptions)
        parameters.allowLocalEndpointReuse = true

        let listener: NWListener
        do {
            if port == 0 {
                listener = try NWListener(using: parameters)
            }
            else {
                guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
                    deleteKeychainItems(label: keychainLabel)
                    return HostBridge.hostErrorEnvelope(NSError(domain: "tls", code: 0, userInfo: [NSLocalizedDescriptionKey: "tlsListen: invalid port"]))
                }
                listener = try NWListener(using: parameters, on: nwPort)
            }
        }
        catch {
            deleteKeychainItems(label: keychainLabel)
            return HostBridge.hostErrorEnvelope(error)
        }

        let listenerId = makeId("TL")

        listener.newConnectionHandler = { [weak self] connection in
            self?.acceptConnection(listenerId: listenerId, connection: connection)
        }

        // Block until the listener is ready (so the OS-assigned port is known) or fails.
        let readySemaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                readySemaphore.signal()
            case .failed(let error):
                startError = error
                readySemaphore.signal()
            default:
                break
            }
        }
        listener.start(queue: networkQueue)

        if readySemaphore.wait(timeout: .now() + 10) == .timedOut {
            listener.cancel()
            deleteKeychainItems(label: keychainLabel)
            return HostBridge.hostErrorEnvelope(NSError(domain: "tls", code: 0, userInfo: [NSLocalizedDescriptionKey: "tlsListen: listener did not become ready"]))
        }
        if let startError = startError {
            listener.cancel()
            deleteKeychainItems(label: keychainLabel)
            return HostBridge.hostErrorEnvelope(startError)
        }

        let boundPort = Int(listener.port?.rawValue ?? 0)

        lock.lock()
        listeners[listenerId] = listener
        listenerKeychainLabels[listenerId] = keychainLabel
        lock.unlock()

        return "{\"listenerId\":\"\(listenerId)\",\"port\":\(boundPort)}"
    }

    //
    // Registers an accepted server connection, enqueues a "connection" event (before the read loop so the
    // JS server registers the socket before any data arrives), and starts streaming its inbound bytes.
    //
    private func acceptConnection(listenerId: String, connection: NWConnection) {
        let connectionId = makeId("TC")
        lock.lock()
        connections[connectionId] = connection
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.enqueue("{\"kind\":\"connection\",\"listenerId\":\"\(listenerId)\",\"connectionId\":\"\(connectionId)\"}")
                self?.receiveLoop(connectionId: connectionId, connection: connection)
            case .failed, .cancelled:
                self?.handleConnectionClosed(connectionId: connectionId)
            default:
                break
            }
        }
        connection.start(queue: networkQueue)
    }

    //
    // host.tlsConnect(host, port, rejectUnauthorized): opens a TLS client connection, completes the
    // handshake, and returns a JSON string { connectionId, peerCertBase64 } (the server's cert DER,
    // base64) so the JS side can pin it. Streams inbound bytes on the network queue. Returns an error
    // envelope on failure.
    //
    // `rejectUnauthorized` is Node's own option, passed straight through rather than reinterpreted:
    // true evaluates the chain and the hostname against the system trust store, which is Node's default
    // and what any ordinary HTTPS client gets. False accepts any certificate, which is what LAN share
    // asks for because it presents a runtime self-signed cert and pins the fingerprint itself in JS.
    //
    func tlsConnect(host: String, port: Int, rejectUnauthorized: Bool) -> String {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "tls", code: 0, userInfo: [NSLocalizedDescriptionKey: "tlsConnect: invalid port"]))
        }

        // Capture the server's leaf certificate during the handshake so the JS side can pin it, then
        // either evaluate the trust chain or accept whatever was presented, per rejectUnauthorized.
        let peerCertBox = PeerCertificateBox()
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            if SecTrustGetCertificateCount(secTrust) > 0, let certificate = SecTrustGetCertificateAtIndex(secTrust, 0) {
                peerCertBox.certificateDer = SecCertificateCopyData(certificate) as Data
            }
            if rejectUnauthorized {
                // SecPolicyCreateSSL(true, host) checks the hostname as well as the chain, so a
                // certificate valid for another host fails the handshake.
                SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, host as CFString))
                var evaluationError: CFError?
                complete(SecTrustEvaluateWithError(secTrust, &evaluationError))
            }
            else {
                complete(true)
            }
        }, networkQueue)

        let parameters = NWParameters(tls: tlsOptions)
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)

        let readySemaphore = DispatchSemaphore(value: 0)
        var connectError: Error?
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                readySemaphore.signal()
            case .failed(let error):
                connectError = error
                readySemaphore.signal()
            case .cancelled:
                self?.handleConnectionClosed(connectionId: "")
            default:
                break
            }
        }
        connection.start(queue: networkQueue)

        if readySemaphore.wait(timeout: .now() + 15) == .timedOut {
            connection.cancel()
            return HostBridge.hostErrorEnvelope(NSError(domain: "tls", code: 0, userInfo: [NSLocalizedDescriptionKey: "tlsConnect: handshake timed out"]))
        }
        if let connectError = connectError {
            connection.cancel()
            return HostBridge.hostErrorEnvelope(connectError)
        }

        let connectionId = makeId("TC")
        lock.lock()
        connections[connectionId] = connection
        lock.unlock()

        // The handshake succeeded; replace the ready/fail handler with one that reports later closure.
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.handleConnectionClosed(connectionId: connectionId)
            default:
                break
            }
        }
        receiveLoop(connectionId: connectionId, connection: connection)

        let peerCertBase64 = peerCertBox.certificateDer?.base64EncodedString() ?? ""
        return "{\"connectionId\":\"\(connectionId)\",\"peerCertBase64\":\"\(peerCertBase64)\"}"
    }

    //
    // Reads inbound bytes from one connection, enqueuing a base64 "data" event per chunk and recursing;
    // a completed stream or an error ends the loop and the state handler enqueues the "close" event.
    //
    private func receiveLoop(connectionId: String, connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else {
                return
            }
            if let data = data, !data.isEmpty {
                self.enqueue("{\"kind\":\"data\",\"connectionId\":\"\(connectionId)\",\"base64\":\"\(data.base64EncodedString())\"}")
            }
            if isComplete || error != nil {
                self.handleConnectionClosed(connectionId: connectionId)
                return
            }
            self.receiveLoop(connectionId: connectionId, connection: connection)
        }
    }

    //
    // Drops a closed connection (so hasLiveConnections stops counting it) and enqueues a "close" event.
    // Safe to call more than once for the same id; only the first call emits the event.
    //
    private func handleConnectionClosed(connectionId: String) {
        if connectionId.isEmpty {
            return
        }
        lock.lock()
        let closedConnection = connections.removeValue(forKey: connectionId)
        lock.unlock()
        if let closedConnection = closedConnection {
            // Cancelled here rather than only dropped. A connection that is let go of without being
            // cancelled keeps its socket, and once it is out of the map nothing can ever cancel it.
            // The same fault in the plain TCP host left an Android phone holding 646 sockets in
            // CLOSE_WAIT while syncing a real photo library, after which every upload timed out.
            closedConnection.cancel()
            enqueue("{\"kind\":\"close\",\"connectionId\":\"\(connectionId)\"}")
        }
    }

    //
    // host.tlsWrite(connectionId, base64): writes base64-decoded bytes to a TLS connection. Returns nil on
    // success or an error envelope on failure (invalid base64 or an unknown connection is a no-op).
    //
    func tlsWrite(connectionId: String, base64: String) -> String? {
        lock.lock()
        let connection = connections[connectionId]
        lock.unlock()
        guard let connection = connection else {
            return nil
        }
        guard let data = Data(base64Encoded: base64) else {
            return HostBridge.hostErrorEnvelope(NSError(domain: "tls", code: 0, userInfo: [NSLocalizedDescriptionKey: "invalid base64"]))
        }
        connection.send(content: data, completion: .contentProcessed { _ in })
        return nil
    }

    //
    // host.tlsClose(connectionId): closes one TLS connection. Flushes any pending sends and signals
    // end-of-stream before tearing down: NWConnection.send is asynchronous and NWConnection.cancel()
    // aborts an in-flight send, so a response written immediately before the close (the receiver's HTTP
    // reply) would be dropped. Sends are ordered, so this final empty message flushes after the reply and
    // then cancels, matching the flush-on-close semantics of the Android SSLSocket.
    //
    func tlsClose(connectionId: String) -> String? {
        lock.lock()
        let connection = connections.removeValue(forKey: connectionId)
        lock.unlock()
        if let connection = connection {
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
        return nil
    }

    //
    // host.tlsStopListening(listenerId): closes a TLS listener so it accepts no further connections and
    // removes its imported keychain items.
    //
    func tlsStopListening(listenerId: String) -> String? {
        lock.lock()
        let listener = listeners.removeValue(forKey: listenerId)
        let keychainLabel = listenerKeychainLabels.removeValue(forKey: listenerId)
        lock.unlock()
        listener?.cancel()
        if let keychainLabel = keychainLabel {
            deleteKeychainItems(label: keychainLabel)
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
    // Returns true while any listener is still open (so the engine keeps a receiver task alive).
    //
    func hasLiveListeners() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !listeners.isEmpty
    }

    //
    // Returns true while any TLS connection is still open. The engine uses this to keep a client-request
    // task (the sender's cert-pinned HTTPS transfer) alive while it awaits the server's response.
    //
    func hasLiveConnections() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !connections.isEmpty
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
    // Closes all listeners and connections, removes imported keychain items, and clears the queue. Called
    // when the engine is disposed.
    //
    func shutdown() {
        lock.lock()
        let listenerList = Array(listeners.values)
        let connectionList = Array(connections.values)
        let labels = Array(listenerKeychainLabels.values)
        listeners.removeAll()
        listenerKeychainLabels.removeAll()
        connections.removeAll()
        inboundEvents.removeAll()
        lock.unlock()
        for listener in listenerList {
            listener.cancel()
        }
        for connection in connectionList {
            connection.cancel()
        }
        for label in labels {
            deleteKeychainItems(label: label)
        }
    }

    //
    // Builds a Network.framework sec_identity_t for the server from the PEM certificate and PKCS#8 private
    // key. Apple has no API to form a SecIdentity from a detached cert/key, so both are added to the
    // keychain under a unique label and the resulting identity is queried back. Returns nil on any failure.
    //
    private func makeServerIdentity(certPem: String, keyPem: String, keychainLabel: String) -> sec_identity_t? {
        let certDer = CryptoHost.derFromPem(certPem)
        guard let certificate = SecCertificateCreateWithData(nil, Data(certDer) as CFData) else {
            return nil
        }

        let pkcs8 = CryptoHost.derFromPem(keyPem)
        guard let pkcs1 = CryptoHost.unwrapPkcs8(pkcs8: pkcs8) else {
            return nil
        }
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        guard let privateKey = SecKeyCreateWithData(Data(pkcs1) as CFData, keyAttributes as CFDictionary, nil) else {
            return nil
        }

        let labelData = keychainLabel.data(using: .utf8)!

        let addKey: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecValueRef as String: privateKey,
            kSecAttrApplicationTag as String: labelData
        ]
        let keyStatus = SecItemAdd(addKey as CFDictionary, nil)
        if keyStatus != errSecSuccess && keyStatus != errSecDuplicateItem {
            return nil
        }

        let addCert: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: keychainLabel
        ]
        let certStatus = SecItemAdd(addCert as CFDictionary, nil)
        if certStatus != errSecSuccess && certStatus != errSecDuplicateItem {
            return nil
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: keychainLabel,
            kSecReturnRef as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let identityResult = result else {
            return nil
        }

        let secIdentity = identityResult as! SecIdentity
        return sec_identity_create(secIdentity)
    }

    //
    // Removes the certificate and private key a listener imported into the keychain under the given label.
    //
    private func deleteKeychainItems(label: String) {
        let labelData = label.data(using: .utf8)!
        SecItemDelete([
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label
        ] as CFDictionary)
        SecItemDelete([
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: labelData
        ] as CFDictionary)
    }
}

//
// A reference box that lets the TLS verify block (which runs on the network queue during the handshake)
// hand the captured peer certificate DER back to the synchronous tlsConnect call.
//
private final class PeerCertificateBox {

    //
    // The server's leaf certificate DER captured during the handshake, or nil if none was presented.
    //
    var certificateDer: Data?
}
