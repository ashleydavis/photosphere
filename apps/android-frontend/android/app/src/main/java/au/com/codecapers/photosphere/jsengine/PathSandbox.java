package au.com.codecapers.photosphere.jsengine;

import java.io.File;
import java.io.IOException;

//
// Shared path-sandbox guard used by every path-taking host function (sha256 and
// the future fs/media host functions). It rejects task-supplied paths that try to
// escape the storage root via absolute paths or `..` traversal, then verifies the
// resolved canonical path is still physically inside the root before any IO runs.
//
public final class PathSandbox {

    //
    // Private constructor: this is a static helper class and must never be instantiated.
    //
    private PathSandbox() {
    }

    //
    // Resolves a task-supplied candidate path against the storage root and returns the
    // resolved File only if it is safely inside the root. Throws SecurityException for
    // any path that is absolute, contains a `..` traversal segment, or whose resolved
    // canonical location escapes the root. The failure surfaces as the task's error result.
    //
    public static File resolveWithin(File root, String candidate) {

        if (root == null) {
            throw new SecurityException("PathSandbox: storage root must not be null.");
        }

        if (candidate == null) {
            throw new SecurityException("PathSandbox: candidate path must not be null.");
        }

        // Reject absolute paths outright: only paths relative to the storage root are allowed.
        File candidateFile = new File(candidate);
        if (candidateFile.isAbsolute()) {
            throw new SecurityException("PathSandbox: absolute paths are not allowed: " + candidate);
        }

        // Reject any path that begins with a filesystem separator (covers both `/` and `\`).
        if (candidate.startsWith("/") || candidate.startsWith("\\")) {
            throw new SecurityException("PathSandbox: absolute paths are not allowed: " + candidate);
        }

        // Reject any `..` traversal segment. Normalising the separators first catches both
        // `../foo` and encoded-then-decoded `..\foo` style vectors. The check is on path
        // segments so a legitimate filename containing `..` (rare) is not mistaken for traversal.
        String normalisedSeparators = candidate.replace('\\', '/');
        for (String segment : normalisedSeparators.split("/")) {
            if (segment.equals("..")) {
                throw new SecurityException("PathSandbox: path traversal is not allowed: " + candidate);
            }
        }

        // Resolve the candidate against the root and canonicalise both so symlinks and `.`
        // segments are collapsed, then verify the resolved path is still inside the root.
        try {
            File resolved = new File(root, candidate);
            String canonicalRoot = root.getCanonicalPath();
            String canonicalResolved = resolved.getCanonicalPath();

            // The resolved path must equal the root or sit beneath it (with a separator
            // boundary so `/root-evil` is not accepted as inside `/root`).
            String rootWithSeparator = canonicalRoot.endsWith(File.separator)
                ? canonicalRoot
                : canonicalRoot + File.separator;

            if (!canonicalResolved.equals(canonicalRoot) && !canonicalResolved.startsWith(rootWithSeparator)) {
                throw new SecurityException("PathSandbox: resolved path escapes the storage root: " + candidate);
            }

            return resolved;
        }
        catch (IOException error) {
            throw new SecurityException("PathSandbox: failed to canonicalise path: " + candidate, error);
        }
    }
}
