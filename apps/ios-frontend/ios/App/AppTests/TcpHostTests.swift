import XCTest
import Foundation
@testable import App

//
// Unit tests for the native TCP host. Real loopback POSIX sockets exercise the listen, accept,
// inbound-data, outbound-write, and close paths with no simulator UI. Mirrors the Android TcpHost
// tests so both platforms share the same vectors.
//
final class TcpHostTests: XCTestCase {

    //
    // The host under test; shut down after each test to release listeners and connections.
    //
    private var tcpHost: TcpHost!

    override func setUp() {
        super.setUp()
        tcpHost = TcpHost()
    }

    override func tearDown() {
        tcpHost.shutdown()
        tcpHost = nil
        super.tearDown()
    }

    //
    // Parses one of the flat JSON envelopes TcpHost emits into a dictionary.
    //
    private func parse(_ json: String) -> [String: Any] {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return object
    }

    //
    // Polls the host's inbound-event queue until an event is available or the timeout elapses.
    //
    private func waitForEvent(timeout: TimeInterval = 3.0) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let event = tcpHost.pollInboundEvent() {
                return event
            }
            usleep(10_000)
        }
        return nil
    }

    //
    // Opens a blocking loopback client connection to the given port, returning the connected socket.
    //
    private func connectClient(port: Int) -> Int32 {
        let clientSocket = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertTrue(clientSocket >= 0, "client socket() failed")
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port)).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(clientSocket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertTrue(connectResult >= 0, "client connect() failed")
        return clientSocket
    }

    func testListenAcceptDataAndCloseFlowThroughEvents() {
        let listen = tcpHost.tcpListen(host: "127.0.0.1", port: 0)
        XCTAssertFalse(listen.hasPrefix("@@HOSTERR@@"), "listen is not an error envelope")
        let port = parse(listen)["port"] as? Int ?? 0
        XCTAssertTrue(port > 0, "bound to an OS-assigned port")

        let client = connectClient(port: port)
        defer { close(client) }

        // The accept loop enqueues a connection event before starting the read loop.
        guard let connectionEvent = waitForEvent() else {
            return XCTFail("a connection event arrived")
        }
        let connectionFields = parse(connectionEvent)
        XCTAssertEqual(connectionFields["kind"] as? String, "connection")
        let connectionId = connectionFields["connectionId"] as? String ?? ""
        XCTAssertFalse(connectionId.isEmpty)

        // Client -> server: bytes arrive as a base64 data event.
        let fromClient = Array("hello-from-client".utf8)
        _ = fromClient.withUnsafeBytes { rawBuffer in
            write(client, rawBuffer.baseAddress, rawBuffer.count)
        }

        guard let dataEvent = waitForEvent() else {
            return XCTFail("a data event arrived")
        }
        let dataFields = parse(dataEvent)
        XCTAssertEqual(dataFields["kind"] as? String, "data")
        XCTAssertEqual(dataFields["connectionId"] as? String, connectionId)
        let base64 = dataFields["base64"] as? String ?? ""
        let decoded = Data(base64Encoded: base64).flatMap { String(data: $0, encoding: .utf8) }
        XCTAssertEqual(decoded, "hello-from-client")

        // Server -> client: tcpWrite reaches the client socket.
        let fromServer = "hello-from-server"
        let writeResult = tcpHost.tcpWrite(connectionId: connectionId, base64: Data(fromServer.utf8).base64EncodedString())
        XCTAssertNil(writeResult, "tcpWrite returns nil on success")

        var received = [UInt8](repeating: 0, count: fromServer.utf8.count)
        var offset = 0
        received.withUnsafeMutableBytes { rawBuffer in
            let base = rawBuffer.baseAddress!
            while offset < rawBuffer.count {
                let bytesRead = Foundation.read(client, base + offset, rawBuffer.count - offset)
                if bytesRead <= 0 {
                    break
                }
                offset += bytesRead
            }
        }
        XCTAssertEqual(offset, fromServer.utf8.count, "stream did not close early")
        XCTAssertEqual(String(bytes: received, encoding: .utf8), fromServer)

        // Client close -> server emits a close event for the connection.
        close(client)
        guard let closeEvent = waitForEvent() else {
            return XCTFail("a close event arrived")
        }
        let closeFields = parse(closeEvent)
        XCTAssertEqual(closeFields["kind"] as? String, "close")
        XCTAssertEqual(closeFields["connectionId"] as? String, connectionId)
    }

    func testHasLiveListenersReflectsOpenListeners() {
        XCTAssertFalse(tcpHost.hasLiveListeners())
        let listen = tcpHost.tcpListen(host: "127.0.0.1", port: 0)
        let listenerId = parse(listen)["listenerId"] as? String ?? ""
        XCTAssertFalse(listenerId.isEmpty)
        XCTAssertTrue(tcpHost.hasLiveListeners())
        _ = tcpHost.tcpStopListening(listenerId: listenerId)
        XCTAssertFalse(tcpHost.hasLiveListeners())
    }

    func testTcpWriteToUnknownConnectionReturnsNil() {
        XCTAssertNil(tcpHost.tcpWrite(connectionId: "C999", base64: Data("x".utf8).base64EncodedString()))
    }

    func testPollInboundEventReturnsNilWhenIdle() {
        XCTAssertNil(tcpHost.pollInboundEvent())
    }
}
