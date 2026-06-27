import Foundation

//
// Error thrown by the path sandbox when a task-supplied path is rejected. Carrying a
// dedicated error type lets host functions surface a clear failure message that becomes
// the task's error result, and lets tests assert the specific rejection reason.
//
enum PathSandboxError: Error, CustomStringConvertible {

    //
    // The candidate path was absolute; only paths relative to the storage root are allowed.
    //
    case absolutePath(String)

    //
    // The candidate path contained a `..` traversal segment.
    //
    case traversal(String)

    //
    // The resolved path escaped the storage root (for example via a symlink).
    //
    case escapesRoot(String)

    //
    // A human-readable description used when the error surfaces as the task's error message.
    //
    var description: String {
        switch self {
        case .absolutePath(let candidate):
            return "PathSandbox: absolute paths are not allowed: \(candidate)"
        case .traversal(let candidate):
            return "PathSandbox: path traversal is not allowed: \(candidate)"
        case .escapesRoot(let candidate):
            return "PathSandbox: resolved path escapes the storage root: \(candidate)"
        }
    }
}

//
// Shared path-sandbox guard used by every path-taking host function (sha256 and
// the future fs/media host functions). It rejects task-supplied paths that try to
// escape the storage root via absolute paths or `..` traversal, then verifies the
// resolved path is still physically inside the root before any IO runs. This mirrors
// the Android `PathSandbox` so both platforms enforce the same rules and share test
// vectors.
//
enum PathSandbox {

    //
    // Resolves a task-supplied candidate path against the storage root and returns the
    // resolved URL only if it is safely inside the root. Throws a PathSandboxError for
    // any path that is absolute, contains a `..` traversal segment, or whose resolved
    // location escapes the root. The failure surfaces as the task's error result.
    //
    static func resolveWithin(root: URL, candidate: String) throws -> URL {

        // Reject any path that begins with a filesystem separator: it names an absolute
        // location and must not be resolved against the storage root.
        if candidate.hasPrefix("/") || candidate.hasPrefix("\\") {
            throw PathSandboxError.absolutePath(candidate)
        }

        // Reject any `..` traversal segment. Normalising the separators first catches both
        // `../foo` and `..\foo` style vectors. The check is per path segment so a legitimate
        // filename merely containing `..` is not mistaken for a traversal segment.
        let normalisedSeparators = candidate.replacingOccurrences(of: "\\", with: "/")
        for segment in normalisedSeparators.split(separator: "/", omittingEmptySubsequences: false) {
            if segment == ".." {
                throw PathSandboxError.traversal(candidate)
            }
        }

        // Resolve the candidate against the root and standardise both so symlinks and `.`
        // segments are collapsed, then verify the resolved path is still inside the root.
        let resolved = root.appendingPathComponent(candidate)
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let canonicalResolved = resolved.standardizedFileURL.resolvingSymlinksInPath().path

        // The resolved path must equal the root or sit beneath it (with a separator boundary
        // so a sibling directory like `/root-evil` is not accepted as inside `/root`).
        let rootWithSeparator = canonicalRoot.hasSuffix("/") ? canonicalRoot : canonicalRoot + "/"
        if canonicalResolved != canonicalRoot && !canonicalResolved.hasPrefix(rootWithSeparator) {
            throw PathSandboxError.escapesRoot(candidate)
        }

        return resolved
    }
}
