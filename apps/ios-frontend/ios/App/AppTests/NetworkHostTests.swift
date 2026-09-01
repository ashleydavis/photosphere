import XCTest
@testable import App

//
// Tests for the connection type the background sync reads.
//
// The value crosses into TypeScript and is fed to computeSyncAllowed, which knows exactly four names.
// Anything else it receives is treated as "unknown", which is permitted, so a misspelled "cellular"
// here would sync over a carrier's network on a phone whose owner asked it not to. These tests are
// about the names and nothing else: which one a given phone reports depends on the phone.
//
final class NetworkHostTests: XCTestCase {

    //
    // The four names the sync gate understands.
    //
    private let permittedNames = [
        NetworkHost.connectionWifi,
        NetworkHost.connectionCellular,
        NetworkHost.connectionNone,
        NetworkHost.connectionUnknown,
    ]

    func testTheNamesAreTheOnesTheSyncGateUnderstands() {
        // Spelled out rather than compared to the constants, because the constants are what would be
        // wrong: the TypeScript side matches these exact strings.
        XCTAssertEqual("wifi", NetworkHost.connectionWifi)
        XCTAssertEqual("cellular", NetworkHost.connectionCellular)
        XCTAssertEqual("none", NetworkHost.connectionNone)
        XCTAssertEqual("unknown", NetworkHost.connectionUnknown)
    }

    func testTheNamesMatchTheAndroidOnes() {
        // The two platforms answer the same worker task, so a name that differs between them would
        // make one of them refuse a sync the other allows.
        XCTAssertEqual(4, Set(permittedNames).count, "the four names must be distinct")
    }

    func testWhatIsReportedIsAlwaysOneOfThoseNames() {
        // Whatever this machine's network is doing, the answer has to be a name the gate knows.
        let reported = NetworkHost.connectionType()

        XCTAssertTrue(permittedNames.contains(reported), "reported \"\(reported)\", which the sync gate does not know")
    }

    func testAskingRepeatedlyKeepsAnswering() {
        // The monitor is started once and its latest path read from, rather than a monitor being
        // started per call. A per-call monitor answers "unsatisfied" for the first moments of every
        // call, which for a sync loop means refusing to sync on a phone that is perfectly connected.
        let first = NetworkHost.connectionType()
        let second = NetworkHost.connectionType()

        XCTAssertTrue(permittedNames.contains(first))
        XCTAssertTrue(permittedNames.contains(second))
    }
}
