import XCTest
@testable import App

//
// Unit tests for the pure photo-picker path helpers. They assert the sandbox-relative path and
// extension derivation the native picker relies on. Mirrors the Android ImportPickerTest so both
// platforms resolve the same extension for the same picked item, in particular the extension-less
// (mime fallback) and jpg cases.
//
final class ImportPickerTests: XCTestCase {

    //
    // The picked file's own extension is used when present, lowercased, taking priority over the
    // display name and mime type.
    //
    func testExtensionFromFileExtension() {
        XCTAssertEqual("png", ImportPicker.extensionFor(displayName: "holiday.jpeg", fileExtension: "PNG", mimeType: "image/jpeg"))
    }

    //
    // With no file extension, the display name's own extension is used.
    //
    func testExtensionFromDisplayName() {
        XCTAssertEqual("png", ImportPicker.extensionFor(displayName: "photo.PNG", fileExtension: nil, mimeType: "image/jpeg"))
        XCTAssertEqual("jpeg", ImportPicker.extensionFor(displayName: "holiday.jpeg", fileExtension: "", mimeType: nil))
    }

    //
    // A "jpg" display-name extension is used verbatim (lowercased), not remapped to "jpeg", even when
    // the mime type is "image/jpeg". The display name's own extension wins over the mime subtype.
    //
    func testJpgDisplayNameExtensionIsUsedVerbatim() {
        XCTAssertEqual("jpg", ImportPicker.extensionFor(displayName: "cat.jpg", fileExtension: nil, mimeType: "image/jpeg"))
        XCTAssertEqual("jpg", ImportPicker.extensionFor(displayName: "cat.JPG", fileExtension: nil, mimeType: nil))
    }

    //
    // With no file extension and no usable display-name extension, the mime subtype is used. This is
    // the extension-less case that used to default to "bin" on iOS while Android inferred "jpeg".
    //
    func testExtensionFromMimeWhenNameHasNone() {
        XCTAssertEqual("jpeg", ImportPicker.extensionFor(displayName: "IMG_0001", fileExtension: nil, mimeType: "image/jpeg"))
        XCTAssertEqual("png", ImportPicker.extensionFor(displayName: nil, fileExtension: nil, mimeType: "image/png"))
        XCTAssertEqual("mp4", ImportPicker.extensionFor(displayName: "clip", fileExtension: "", mimeType: "video/mp4"))
    }

    //
    // With neither a usable file extension, name, nor mime, the extension defaults to "bin".
    //
    func testExtensionDefaultsToBin() {
        XCTAssertEqual("bin", ImportPicker.extensionFor(displayName: nil, fileExtension: nil, mimeType: nil))
        XCTAssertEqual("bin", ImportPicker.extensionFor(displayName: "noext", fileExtension: "", mimeType: "image/*"))
        XCTAssertEqual("bin", ImportPicker.extensionFor(displayName: ".hidden", fileExtension: nil, mimeType: "*/*"))
    }

    //
    // The cross-platform parity table, mirroring Android's ImportPickerTest.sharedParityCases case
    // for case. No file extension is supplied, because that is the one source Android has no
    // counterpart for, so these inputs exercise the chain both platforms share. The two tables are
    // mirrored on purpose: a change to one platform's inference that is not made to the other breaks
    // one of them, rather than silently letting the same photo import differently on each platform.
    //
    func testSharedParityCases() {
        // A name extension wins over the mime type, and is lowercased.
        XCTAssertEqual("png", ImportPicker.extensionFor(displayName: "photo.PNG", fileExtension: nil, mimeType: "image/jpeg"))

        // Used verbatim: no jpg -> jpeg remap on either platform.
        XCTAssertEqual("jpg", ImportPicker.extensionFor(displayName: "cat.jpg", fileExtension: nil, mimeType: "image/jpeg"))

        // The last dot wins, so a double extension keeps only its final part.
        XCTAssertEqual("gz", ImportPicker.extensionFor(displayName: "archive.tar.gz", fileExtension: nil, mimeType: nil))

        // No usable name extension, so the mime subtype is used. This is the case iOS used to fail.
        XCTAssertEqual("jpeg", ImportPicker.extensionFor(displayName: "IMG_0001", fileExtension: nil, mimeType: "image/jpeg"))

        // The subtype is used verbatim, even when it is not a real extension.
        XCTAssertEqual("quicktime", ImportPicker.extensionFor(displayName: "clip", fileExtension: nil, mimeType: "video/quicktime"))

        // A trailing dot is not an extension, so the mime subtype is used.
        XCTAssertEqual("jpeg", ImportPicker.extensionFor(displayName: "trailing.", fileExtension: nil, mimeType: "image/jpeg"))

        // A leading dot marks a hidden file, not an extension, so the mime subtype is used.
        XCTAssertEqual("png", ImportPicker.extensionFor(displayName: ".hidden", fileExtension: nil, mimeType: "image/png"))

        // A wildcard subtype names no format, so it falls through to the default.
        XCTAssertEqual("bin", ImportPicker.extensionFor(displayName: "noext", fileExtension: nil, mimeType: "image/*"))

        // A mime with no slash, or an empty subtype, is malformed and falls through.
        XCTAssertEqual("bin", ImportPicker.extensionFor(displayName: nil, fileExtension: nil, mimeType: "image"))
        XCTAssertEqual("bin", ImportPicker.extensionFor(displayName: nil, fileExtension: nil, mimeType: "image/"))

        // Nothing usable at all.
        XCTAssertEqual("bin", ImportPicker.extensionFor(displayName: nil, fileExtension: nil, mimeType: nil))
    }

    //
    // The empty file extension PHPicker vends for an extension-less temp URL must behave exactly as
    // no file extension at all, so iOS falls through to the shared chain rather than producing a path
    // that ends in a bare dot. This is what routes the common iOS case onto the parity table above.
    //
    func testEmptyFileExtensionFallsThroughToTheSharedChain() {
        XCTAssertEqual("jpeg", ImportPicker.extensionFor(displayName: "IMG_0001", fileExtension: "", mimeType: "image/jpeg"))
        XCTAssertEqual("png", ImportPicker.extensionFor(displayName: "photo.PNG", fileExtension: "", mimeType: "image/jpeg"))
        XCTAssertEqual("bin", ImportPicker.extensionFor(displayName: nil, fileExtension: "", mimeType: nil))
    }

    //
    // The relative path is "<importTempDir>/<uuid>.<ext>".
    //
    func testBuildsRelativePathUnderImportTempDir() {
        let path = ImportPicker.buildRelativePath(uuid: "abc-123", displayName: "cat.jpeg", fileExtension: nil, mimeType: "image/jpeg")
        XCTAssertEqual(".import-tmp/abc-123.jpeg", path)
    }

    //
    // The extension-less item builds its path from the mime fallback rather than defaulting to "bin".
    //
    func testBuildsRelativePathFromMimeFallback() {
        let path = ImportPicker.buildRelativePath(uuid: "abc-123", displayName: "IMG_0001", fileExtension: nil, mimeType: "image/jpeg")
        XCTAssertEqual(".import-tmp/abc-123.jpeg", path)
    }
}
