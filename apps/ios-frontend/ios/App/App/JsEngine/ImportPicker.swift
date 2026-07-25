import Foundation

//
// Pure helpers for the native photo picker's copy-into-sandbox step, mirroring the Android
// ImportPicker. The picker copies each chosen item into a temp directory under the storage root and
// hands the import task sandbox-relative paths; these helpers build those paths deterministically.
//
enum ImportPicker {

    //
    // The sandbox-relative directory picked media is copied into before import. The import task is
    // handed these exact file paths, not a directory to scan.
    //
    static let importTempDir = ".import-tmp"

    //
    // Builds the sandbox-relative path a picked file is copied to: "<importTempDir>/<uuid>.<ext>".
    // The extension comes from the picked file's own extension, then the display name, then the mime
    // subtype, then "bin".
    //
    static func buildRelativePath(uuid: String, displayName: String?, fileExtension: String?, mimeType: String?) -> String {
        let ext = extensionFor(displayName: displayName, fileExtension: fileExtension, mimeType: mimeType)
        return importTempDir + "/" + uuid + "." + ext
    }

    //
    // Derives a lowercase file extension: the picked file's own extension when present, otherwise the
    // display name's extension, otherwise the mime subtype ("image/jpeg" -> "jpeg"), otherwise "bin".
    //
    // This must resolve the same extension as the Android ImportPicker for the same picked item, so
    // one photo does not import as an image on one platform and as an untyped blob on the other. Both
    // platforms run the same chain: a name's extension, then the mime subtype, then "bin", using the
    // same rules at each step (see extensionFromName and extensionFromMime, which mirror Android's
    // line for line). ImportPickerTests.testSharedParityCases and Android's
    // ImportPickerTest.sharedParityCases assert an identical table of inputs and results; keep them
    // in step when changing either platform.
    //
    // The one structural difference is that iOS gets two names for an item, so it has two candidate
    // sources for the "name extension" step: the temp file URL PHPicker vends (the closer analogue of
    // Android's DISPLAY_NAME, so it is checked first) and the picker's suggestedName, which often has
    // no extension. Android's content URI exposes only DISPLAY_NAME. The two agree in practice; if
    // they ever disagree the file's own extension is the one that describes the actual bytes.
    //
    static func extensionFor(displayName: String?, fileExtension: String?, mimeType: String?) -> String {
        if let fileExtension = fileExtension, !fileExtension.isEmpty {
            return fileExtension.lowercased()
        }

        if let fromName = extensionFromName(displayName) {
            return fromName
        }

        if let fromMime = extensionFromMime(mimeType) {
            return fromMime
        }

        return "bin"
    }

    //
    // Returns the lowercase extension of a file name (the part after the last dot), or nil when the
    // name is nil, has no dot, ends in a dot, or the dot is the first character.
    //
    private static func extensionFromName(_ displayName: String?) -> String? {
        guard let displayName = displayName, let dotIndex = displayName.lastIndex(of: ".") else {
            return nil
        }

        if dotIndex == displayName.startIndex || dotIndex == displayName.index(before: displayName.endIndex) {
            return nil
        }

        return String(displayName[displayName.index(after: dotIndex)...]).lowercased()
    }

    //
    // Returns the subtype of a "type/subtype" mime string as a lowercase extension, or nil when the
    // mime is nil or malformed. "*" subtypes yield nil. Mirrors the Android ImportPicker.
    //
    private static func extensionFromMime(_ mimeType: String?) -> String? {
        guard let mimeType = mimeType, let slashIndex = mimeType.firstIndex(of: "/") else {
            return nil
        }

        if slashIndex == mimeType.index(before: mimeType.endIndex) {
            return nil
        }

        let subtype = String(mimeType[mimeType.index(after: slashIndex)...]).lowercased()
        if subtype.isEmpty || subtype == "*" {
            return nil
        }

        return subtype
    }
}
