import XCTest
@testable import App

//
// Unit tests for the device photo library helpers, mirroring Android's MediaLibraryTest: where a
// page starts and stops, the sandbox path an exported item lands on, which library items automatic
// import can take in, and how deletions are batched so one system confirmation covers many photos.
//
// The tables below are the same ones the Android test asserts. A photo has to page, export and batch
// the same way on both platforms, or the same library backs up differently depending on the phone;
// keep the two in step when changing either.
//
final class MediaLibraryTests: XCTestCase {

    func testAnAbsentCursorStartsAtTheBeginning() {
        XCTAssertEqual(MediaLibrary.offsetFromCursor(nil), 0)
        XCTAssertEqual(MediaLibrary.offsetFromCursor(""), 0)
    }

    func testACursorSaysWhereThePageStarts() {
        XCTAssertEqual(MediaLibrary.offsetFromCursor("50"), 50)
    }

    func testAnUnreadableCursorStartsAtTheBeginningRatherThanFailing() {
        XCTAssertEqual(MediaLibrary.offsetFromCursor("not-a-number"), 0)
        XCTAssertEqual(MediaLibrary.offsetFromCursor("-5"), 0)
    }

    func testThePageAfterThisOneStartsWhereThisOneEnded() {
        XCTAssertEqual(MediaLibrary.nextCursor(offset: 0, itemsReturned: 50, totalCount: 200), "50")
        XCTAssertEqual(MediaLibrary.nextCursor(offset: 50, itemsReturned: 50, totalCount: 200), "100")
    }

    func testTheLastPageHasNoCursorAfterIt() {
        XCTAssertNil(MediaLibrary.nextCursor(offset: 150, itemsReturned: 50, totalCount: 200))
    }

    func testAPageThatWentPastTheEndHasNoCursorAfterIt() {
        XCTAssertNil(MediaLibrary.nextCursor(offset: 180, itemsReturned: 50, totalCount: 200))
    }

    func testAnEmptyPageEndsTheListing() {
        XCTAssertNil(MediaLibrary.nextCursor(offset: 0, itemsReturned: 0, totalCount: 200))
    }

    func testAnEmptyLibraryEndsAtOnce() {
        XCTAssertNil(MediaLibrary.nextCursor(offset: 0, itemsReturned: 0, totalCount: 0))
    }

    func testAnExportedItemLandsInTheMediaTempDirectory() {
        XCTAssertEqual(
            MediaLibrary.buildExportPath(itemId: "1234", displayName: "holiday.jpg", mimeType: "image/jpeg"),
            ".media-tmp/1234.jpg")
    }

    func testAnExportedItemTakesItsExtensionFromTheMimeTypeWhenTheNameHasNone() {
        XCTAssertEqual(
            MediaLibrary.buildExportPath(itemId: "1234", displayName: "holiday", mimeType: "image/jpeg"),
            ".media-tmp/1234.jpeg")
    }

    func testAnExportedItemWithNoNameOrTypeStillGetsAPath() {
        XCTAssertEqual(
            MediaLibrary.buildExportPath(itemId: "1234", displayName: nil, mimeType: nil),
            ".media-tmp/1234.bin")
    }

    func testTheSameItemAlwaysExportsToTheSamePath() {
        let first = MediaLibrary.buildExportPath(itemId: "1234", displayName: "holiday.jpg", mimeType: "image/jpeg")
        let second = MediaLibrary.buildExportPath(itemId: "1234", displayName: "holiday.jpg", mimeType: "image/jpeg")
        XCTAssertEqual(first, second)
    }

    func testAPhAssetIdentifierCannotEscapeTheTempDirectory() {
        // A PHAsset local identifier looks like "<uuid>/L0/001", so the separator is the ordinary
        // case here rather than a hostile one.
        let path = MediaLibrary.buildExportPath(
            itemId: "1B2C3D4E-0000-0000-0000-000000000000/L0/001",
            displayName: "IMG_0001.HEIC",
            mimeType: "image/heic")
        XCTAssertFalse(path.dropFirst(MediaLibrary.mediaTempDir.count + 1).contains("/"))
        XCTAssertTrue(path.hasPrefix(".media-tmp/"))
    }

    func testAnIdWithAPathTraversalInItCannotEscapeTheTempDirectory() {
        let path = MediaLibrary.buildExportPath(itemId: "../../etc/passwd", displayName: "x.jpg", mimeType: "image/jpeg")
        XCTAssertFalse(path.contains(".."))
        XCTAssertTrue(path.hasPrefix(".media-tmp/"))
    }

    func testAnEmptyIdStillYieldsAPath() {
        XCTAssertEqual(
            MediaLibrary.buildExportPath(itemId: "", displayName: "x.jpg", mimeType: "image/jpeg"),
            ".media-tmp/unknown.jpg")
    }

    func testImagesAndVideosAreSupported() {
        XCTAssertTrue(MediaLibrary.isSupportedMimeType("image/jpeg"))
        XCTAssertTrue(MediaLibrary.isSupportedMimeType("image/png"))
        XCTAssertTrue(MediaLibrary.isSupportedMimeType("video/mp4"))
        XCTAssertTrue(MediaLibrary.isSupportedMimeType("IMAGE/JPEG"))
    }

    func testTheTypesTheImportCannotProcessAreNotSupported() {
        XCTAssertFalse(MediaLibrary.isSupportedMimeType("image/svg+xml"))
        XCTAssertFalse(MediaLibrary.isSupportedMimeType("image/vnd.adobe.photoshop"))
        XCTAssertFalse(MediaLibrary.isSupportedMimeType("application/pdf"))
        XCTAssertFalse(MediaLibrary.isSupportedMimeType("text/plain"))
        XCTAssertFalse(MediaLibrary.isSupportedMimeType(nil))
    }

    func testDeletionsAreSplitIntoBatches() throws {
        let batches = try MediaLibrary.buildDeleteBatches(itemIds: ["1", "2", "3", "4", "5"], batchSize: 2)

        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches[0], ["1", "2"])
        XCTAssertEqual(batches[1], ["3", "4"])
        XCTAssertEqual(batches[2], ["5"])
    }

    func testEverythingFitsInOneBatchWhenItCan() throws {
        let batches = try MediaLibrary.buildDeleteBatches(itemIds: ["1", "2"], batchSize: 50)

        XCTAssertEqual(batches.count, 1)
        XCTAssertEqual(batches[0].count, 2)
    }

    func testNothingToDeleteIsNoBatches() throws {
        XCTAssertEqual(try MediaLibrary.buildDeleteBatches(itemIds: [], batchSize: 50).count, 0)
    }

    func testABatchSizeBelowOneIsRefusedRatherThanLoopingForever() {
        XCTAssertThrowsError(try MediaLibrary.buildDeleteBatches(itemIds: ["1"], batchSize: 0))
    }

    func testTheDefaultBatchSizeIsWhatTheDeleteRequestUses() throws {
        let itemIds = (0...MediaLibrary.deleteBatchSize).map { String($0) }

        let batches = try MediaLibrary.buildDeleteBatches(itemIds: itemIds, batchSize: MediaLibrary.deleteBatchSize)

        XCTAssertEqual(batches.count, 2)
        XCTAssertEqual(batches[0].count, MediaLibrary.deleteBatchSize)
        XCTAssertEqual(batches[1].count, 1)
    }

    //
    // The batch size and temp directory have to be the same on both platforms, or a photo exported
    // on one lands somewhere the other would not look, and one platform asks the user twice as often
    // as the other.
    //
    func testTheSharedConstantsMatchAndroid() {
        XCTAssertEqual(MediaLibrary.mediaTempDir, ".media-tmp")
        XCTAssertEqual(MediaLibrary.deleteBatchSize, 50)
    }
}
