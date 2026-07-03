import XCTest
import JavaScriptCore
@testable import App

//
// Tests the media host-function wiring: argv path tokens are sandbox-resolved to absolute paths, the
// three media host functions are installed on globalThis.host, and they return the JSON contract the
// mobile runMediaTool helper decodes. The actual ImageMagick/ffmpeg output (dimensions, probe JSON)
// requires the vendored native libraries and is exercised by the asset-processing smoke test on the
// simulator; here the exit code may be the "not linked" sentinel when the libs are absent, which is
// still valid JSON and proves the bridge wiring.
//
final class HostBridgeMediaTests: XCTestCase {

    //
    // A flag token (no path separator) is returned unchanged.
    //
    func testResolveLeavesFlagsUnchanged() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        XCTAssertEqual(try HostBridge.resolveMediaToken(root: root, token: "-resize"), "-resize")
        XCTAssertEqual(try HostBridge.resolveMediaToken(root: root, token: "300x300"), "300x300")
        XCTAssertEqual(try HostBridge.resolveMediaToken(root: root, token: "info:"), "info:")
        XCTAssertEqual(try HostBridge.resolveMediaToken(root: root, token: "histogram:info:"), "histogram:info:")
    }

    //
    // A relative path token is resolved to its absolute path under the storage root.
    //
    func testResolveMakesRelativePathAbsolute() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mediaroot")
        let resolved = try HostBridge.resolveMediaToken(root: root, token: "tmp/a.jpg")
        XCTAssertEqual(resolved, root.appendingPathComponent("tmp/a.jpg").path)
    }

    //
    // An ImageMagick "encoder:path" token keeps its prefix and resolves only the path part.
    //
    func testResolveKeepsEncoderPrefix() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mediaroot")
        let resolved = try HostBridge.resolveMediaToken(root: root, token: "jpeg:tmp/out.jpg")
        XCTAssertEqual(resolved, "jpeg:" + root.appendingPathComponent("tmp/out.jpg").path)
    }

    //
    // A path that escapes the sandbox (absolute or `..` traversal) is rejected.
    //
    func testResolveRejectsEscapingPaths() {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mediaroot")
        XCTAssertThrowsError(try HostBridge.resolveMediaToken(root: root, token: "/etc/passwd"))
        XCTAssertThrowsError(try HostBridge.resolveMediaToken(root: root, token: "../escape/a.jpg"))
    }

    //
    // The three media host functions are installed and return decodable { exitCode, output } JSON.
    //
    func testMediaHostFunctionsInstalledAndReturnJson() {
        let context = JSContext()!
        let bridge = HostBridge(sessionId: "test-session",
                                storageRoot: URL(fileURLWithPath: NSTemporaryDirectory()),
                                isCancelledProvider: { _ in false },
                                messageSink: { _, _ in })
        bridge.install(into: context)

        for name in ["imageMagick", "ffmpeg", "ffprobe"] {
            let script = "JSON.parse(host.\(name)(JSON.stringify([\"-version\"]))).exitCode !== undefined"
            let value = context.evaluateScript(script)
            XCTAssertTrue(value?.toBool() ?? false, "host.\(name) did not return decodable { exitCode } JSON")
        }
    }
}
