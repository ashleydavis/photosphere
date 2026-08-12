import Foundation

//
// Pure helpers for reading the device photo library, mirroring the Android MediaLibrary.
//
// Automatic import walks the library a page at a time, exports a chosen item into the sandbox so the
// import task can read it as a file, and deletes source files in batches once they are confirmed in
// the database.
//
// Kept free of Photos framework types so it can be unit-tested without a photo library. The PHAsset
// fetch, the resource export and the deletion live in MediaLibraryHost, which needs the framework.
//
// The rules here must match Android's MediaLibrary line for line: a photo has to page, export and
// batch the same way on both platforms, or the same library backs up differently depending on the
// phone. MediaLibraryTests and Android's MediaLibraryTest assert the same table of cases.
//
enum MediaLibrary {

    //
    // The sandbox-relative directory an exported library item is copied into before import. Separate
    // from the picker's own temp directory so a background export and a user's pick cannot collide.
    //
    static let mediaTempDir = ".media-tmp"

    //
    // How many items a delete request may cover. iOS confirms deletion of assets the app did not
    // create, so deleting one photo per request would mean one dialog per photo.
    //
    static let deleteBatchSize = 50

    //
    // Where in the library a page starts, read from the opaque cursor the auto-import task hands
    // back. An absent or unreadable cursor starts at the beginning rather than failing: the cursor is
    // persisted between runs, and a database written by an older build has none.
    //
    static func offsetFromCursor(_ cursor: String?) -> Int {
        guard let cursor = cursor, !cursor.isEmpty else {
            return 0
        }

        guard let offset = Int(cursor), offset >= 0 else {
            return 0
        }

        return offset
    }

    //
    // The cursor for the page after this one, or nil at the end of the library.
    //
    // Nil is what tells the caller to stop, so it is returned only when this page reached the end. A
    // page that came back short because the library changed under us still yields a cursor, and the
    // next fetch simply finds nothing.
    //
    static func nextCursor(offset: Int, itemsReturned: Int, totalCount: Int) -> String? {
        let nextOffset = offset + itemsReturned
        if itemsReturned <= 0 || nextOffset >= totalCount {
            return nil
        }
        return String(nextOffset)
    }

    //
    // The sandbox-relative path a library item is exported to: "<mediaTempDir>/<id>.<ext>".
    //
    // The item's own library id is used rather than a fresh uuid, so exporting the same item twice
    // lands on the same path and a file left behind by a killed run is reused rather than orphaned.
    //
    static func buildExportPath(itemId: String, displayName: String?, mimeType: String?) -> String {
        let ext = ImportPicker.extensionFor(displayName: displayName, fileExtension: nil, mimeType: mimeType)
        return mediaTempDir + "/" + sanitiseId(itemId) + "." + ext
    }

    //
    // Makes a library id safe to use as a file name. A PHAsset local identifier contains a slash
    // ("<uuid>/L0/001"), which would put the export somewhere other than the temp directory.
    //
    static func sanitiseId(_ itemId: String) -> String {
        if itemId.isEmpty {
            return "unknown"
        }

        var safe = ""
        for character in itemId {
            let allowed = (character >= "a" && character <= "z")
                || (character >= "A" && character <= "Z")
                || (character >= "0" && character <= "9")
                || character == "-"
                || character == "_"
            safe.append(allowed ? character : "-")
        }
        return safe
    }

    //
    // Whether a library item is media automatic import can take in. The library holds types the
    // import cannot process.
    //
    static func isSupportedMimeType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType else {
            return false
        }

        let lower = mimeType.lowercased()
        if lower == "image/svg+xml" || lower.hasPrefix("image/vnd.adobe.photoshop") {
            return false
        }
        return lower.hasPrefix("image/") || lower.hasPrefix("video/")
    }

    //
    // One album in the device photo library, as the settings list shows it.
    //
    struct Album: Equatable {
        // The identifier the platform groups the album's items under.
        let id: String

        // The album's name, as the user sees it.
        let name: String

        // How many items the album holds.
        let itemCount: Int
    }

    //
    // Splits the ids to delete into batches, so each batch becomes one system confirmation rather
    // than one per photo.
    //
    static func buildDeleteBatches(itemIds: [String], batchSize: Int) throws -> [[String]] {
        if batchSize < 1 {
            throw MediaLibraryError.badBatchSize(batchSize)
        }

        var batches: [[String]] = []
        var start = 0
        while start < itemIds.count {
            let end = min(start + batchSize, itemIds.count)
            batches.append(Array(itemIds[start..<end]))
            start += batchSize
        }
        return batches
    }
}

//
// What can go wrong reading or changing the device photo library.
//
enum MediaLibraryError: Error, LocalizedError {
    // A batch size that would loop forever.
    case badBatchSize(Int)

    // The library would not give up an item's bytes.
    case exportFailed(String)

    // The library holds no item with that id.
    case itemNotFound(String)

    var errorDescription: String? {
        switch self {
        case .badBatchSize(let size):
            return "Delete batch size must be at least 1, got \(size)."
        case .exportFailed(let itemId):
            return "Failed to export item \(itemId) from the photo library."
        case .itemNotFound(let itemId):
            return "The photo library holds no item with id \(itemId)."
        }
    }
}
