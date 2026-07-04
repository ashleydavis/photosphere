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
    // The extension comes from the picked file's own extension, then the display name, then "bin".
    //
    static func buildRelativePath(uuid: String, displayName: String?, fileExtension: String?) -> String {
        let ext = extensionFor(displayName: displayName, fileExtension: fileExtension)
        return importTempDir + "/" + uuid + "." + ext
    }

    //
    // Derives a lowercase file extension: the picked file's own extension when present, otherwise the
    // display name's extension, otherwise "bin".
    //
    static func extensionFor(displayName: String?, fileExtension: String?) -> String {
        if let fileExtension = fileExtension, !fileExtension.isEmpty {
            return fileExtension.lowercased()
        }

        if let fromName = extensionFromName(displayName) {
            return fromName
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
}
