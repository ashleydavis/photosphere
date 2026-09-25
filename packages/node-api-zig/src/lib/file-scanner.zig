//
// Only IFileStat is ported from file-scanner.ts (it is the parameter type of computeAssetHash).
// Not ported: ScannerState, ScanProgressCallback, the scanner functions (psi add, not psi replicate or psi verify).
//

//
// The information about a file that is needed to hash it.
//
pub const IFileStat = struct {
    // The content type of the file (optional).
    contentType: ?[]const u8 = null,

    // The length of the file in bytes.
    length: u64,

    // The last modified date of the file (milliseconds since the Unix epoch, like a JS Date).
    lastModified: i64,
};
