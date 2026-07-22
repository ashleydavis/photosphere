import XCTest
@testable import App

//
// Tests that a photo pick which fails to load or copy an item surfaces as a rejection rather than
// silently dropping the item, matching the Android plugin's reject-on-IOException behaviour. Exercises
// the pure aggregation the picker delegate uses to decide between resolving with paths and rejecting.
//
final class PickFilesCopyFailureTests: XCTestCase {

    //
    // A distinct error used to stand in for a copy or load-representation failure of a picked item.
    //
    private struct SampleCopyError: Error {}

    //
    // When every picked item copies, the aggregation succeeds with the relative paths in pick order,
    // so pickFiles resolves with the full list.
    //
    func testAllItemsCopiedResolvesWithPaths() {
        let outcomes: [PickedItemOutcome] = [
            .copied(".import-tmp/a.jpg"),
            .copied(".import-tmp/b.png")
        ]

        switch aggregatePickedOutcomes(outcomes) {
        case .success(let paths):
            XCTAssertEqual(paths, [".import-tmp/a.jpg", ".import-tmp/b.png"])
        case .failure(let error):
            XCTFail("expected success, got failure \(error)")
        }
    }

    //
    // When one picked item fails to copy, the whole pick fails so pickFiles rejects instead of dropping
    // the failed item and resolving with a short list (the silent-drop bug this step fixes).
    //
    func testFailedCopySurfacesAsFailure() {
        let outcomes: [PickedItemOutcome] = [
            .copied(".import-tmp/a.jpg"),
            .failed(SampleCopyError()),
            .copied(".import-tmp/c.jpg")
        ]

        switch aggregatePickedOutcomes(outcomes) {
        case .success(let paths):
            XCTFail("expected failure, got success \(paths)")
        case .failure(let error):
            XCTAssertTrue(error is SampleCopyError)
        }
    }

    //
    // The first failure wins and short-circuits the pick, matching Android which rejects on the first
    // IOException.
    //
    func testFirstFailureWins() {
        let firstError = SampleCopyError()
        let outcomes: [PickedItemOutcome] = [
            .failed(firstError),
            .failed(JsEnginePickError.missingFileRepresentation)
        ]

        switch aggregatePickedOutcomes(outcomes) {
        case .success(let paths):
            XCTFail("expected failure, got success \(paths)")
        case .failure(let error):
            XCTAssertTrue(error is SampleCopyError)
        }
    }

    //
    // A missing file representation (the picker vended neither a URL nor an error) is treated as a
    // failure so the item is never silently dropped.
    //
    func testMissingFileRepresentationIsFailure() {
        switch aggregatePickedOutcomes([.failed(JsEnginePickError.missingFileRepresentation)]) {
        case .success(let paths):
            XCTFail("expected failure, got success \(paths)")
        case .failure(let error):
            guard case JsEnginePickError.missingFileRepresentation = error else {
                return XCTFail("expected missingFileRepresentation, got \(error)")
            }
        }
    }

    //
    // An empty pick (the user cancelled) aggregates to success with no paths, so pickFiles resolves
    // with an empty list rather than rejecting.
    //
    func testEmptyPickResolvesEmpty() {
        switch aggregatePickedOutcomes([]) {
        case .success(let paths):
            XCTAssertTrue(paths.isEmpty)
        case .failure(let error):
            XCTFail("expected success, got failure \(error)")
        }
    }
}
