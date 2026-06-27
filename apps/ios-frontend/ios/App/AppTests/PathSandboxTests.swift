import XCTest
@testable import App

//
// Tests the shared PathSandbox guard: traversal and absolute-path vectors are rejected while
// legitimate in-root paths resolve to a location inside the storage root. Mirrors the Android
// path-sandbox tests so both platforms share the same vectors.
//
final class PathSandboxTests: XCTestCase {

    //
    // The temporary storage root used by each test, created fresh in setUp and removed in tearDown.
    //
    private var storageRoot: URL!

    //
    // Creates a unique temporary directory to act as the storage root for the test.
    //
    override func setUpWithError() throws {
        storageRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
    }

    //
    // Removes the temporary storage root after each test.
    //
    override func tearDownWithError() throws {
        if let storageRoot = storageRoot {
            try? FileManager.default.removeItem(at: storageRoot)
        }
    }

    //
    // A plain relative path inside the root resolves to a URL under the root.
    //
    func testInRootPathAccepted() throws {
        let resolved = try PathSandbox.resolveWithin(root: storageRoot, candidate: "photos/x.jpg")
        let canonicalRoot = storageRoot.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalResolved = resolved.standardizedFileURL.resolvingSymlinksInPath().path
        XCTAssertTrue(canonicalResolved.hasPrefix(canonicalRoot))
    }

    //
    // A `..` traversal vector is rejected.
    //
    func testParentTraversalRejected() {
        XCTAssertThrowsError(try PathSandbox.resolveWithin(root: storageRoot, candidate: "../escape.txt")) { error in
            guard case PathSandboxError.traversal = error else {
                return XCTFail("expected traversal error, got \(error)")
            }
        }
    }

    //
    // A nested `..` traversal vector is rejected.
    //
    func testNestedTraversalRejected() {
        XCTAssertThrowsError(try PathSandbox.resolveWithin(root: storageRoot, candidate: "photos/../../escape.txt")) { error in
            guard case PathSandboxError.traversal = error else {
                return XCTFail("expected traversal error, got \(error)")
            }
        }
    }

    //
    // A backslash-separated traversal vector is rejected (normalised before the segment check).
    //
    func testBackslashTraversalRejected() {
        XCTAssertThrowsError(try PathSandbox.resolveWithin(root: storageRoot, candidate: "photos\\..\\escape.txt")) { error in
            guard case PathSandboxError.traversal = error else {
                return XCTFail("expected traversal error, got \(error)")
            }
        }
    }

    //
    // An absolute path is rejected.
    //
    func testAbsolutePathRejected() {
        XCTAssertThrowsError(try PathSandbox.resolveWithin(root: storageRoot, candidate: "/etc/passwd")) { error in
            guard case PathSandboxError.absolutePath = error else {
                return XCTFail("expected absolutePath error, got \(error)")
            }
        }
    }
}
