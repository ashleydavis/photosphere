import XCTest
@testable import App

//
// Tests the NOT IMPLEMENTED contract: the notImplemented helper produces the exact verbatim message
// (asserted character-for-character so it can never drift from the TypeScript counterpart) and the
// error carries that message as its description. Mirrors the Android NOT IMPLEMENTED test.
//
final class NotImplementedTests: XCTestCase {

    //
    // The helper must produce the exact NOT IMPLEMENTED message for a named host function on iOS.
    //
    func testExactMessageFormat() {
        let error = notImplemented("fsReadFile")
        XCTAssertEqual(error.message, "NOT IMPLEMENTED: native host function \"fsReadFile\" is not implemented yet on ios. Implement it ASAP.")
    }

    //
    // The error's description must equal its message so it surfaces verbatim as the task error.
    //
    func testErrorDescriptionMatchesMessage() {
        let error = notImplemented("transcodeVideo")
        XCTAssertEqual(error.description, error.message)
        XCTAssertEqual("\(error)", "NOT IMPLEMENTED: native host function \"transcodeVideo\" is not implemented yet on ios. Implement it ASAP.")
    }

    //
    // The message must name the specific function passed in, so different functions produce distinct
    // messages.
    //
    func testMessageNamesFunction() {
        XCTAssertTrue(notImplemented("probeMedia").message.contains("\"probeMedia\""))
        XCTAssertTrue(notImplemented("makeThumbnail").message.contains("\"makeThumbnail\""))
    }
}
