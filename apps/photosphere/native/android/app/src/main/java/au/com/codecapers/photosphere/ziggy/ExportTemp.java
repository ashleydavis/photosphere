package au.com.codecapers.photosphere.ziggy;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.List;

//
// Pure helpers for the asset-export flow's sandbox-temp lifecycle. A
// download writes a decrypted original to a sandbox temp path under EXPORT_TEMP_DIR, the native
// export sheet hands that file out, and the temp copy is then deleted on every sheet exit. These
// helpers own the copy, the delete-on-exit, and the start-up sweep, kept free of Android
// types so they can be unit-tested on a plain JVM (the activity code that calls them cannot).
//
public final class ExportTemp {

    //
    // The sandbox-relative directory a download's finished bytes are written to before the export
    // sheet hands them out. Swept on start-up to collect any temp left by a kill mid-sheet.
    //
    public static final String EXPORT_TEMP_DIR = ".export-tmp";

    //
    // Buffer size used when copying a temp file's bytes into the user's chosen destination stream.
    //
    private static final int COPY_BUFFER_SIZE = 64 * 1024;

    //
    // Not instantiable; only static helpers.
    //
    private ExportTemp() {
    }

    //
    // Copies all bytes from an input stream to an output stream. Used to write a sandbox temp file's
    // bytes into the content:// destination the user chose in ACTION_CREATE_DOCUMENT.
    //
    public static void copyStream(InputStream input, OutputStream output) throws IOException {
        byte[] buffer = new byte[COPY_BUFFER_SIZE];
        int bytesRead = input.read(buffer);
        while (bytesRead != -1) {
            output.write(buffer, 0, bytesRead);
            bytesRead = input.read(buffer);
        }
    }

    //
    // Deletes one sandbox temp file (resolved through PathSandbox so a hostile path cannot reach
    // outside the storage root) and removes its now-empty per-export parent directory when that
    // parent sits under EXPORT_TEMP_DIR. A missing file is not an error: cleanup is idempotent.
    //
    public static void deleteTemp(File storageRoot, String relativePath) {
        File resolved = PathSandbox.resolveWithin(storageRoot, relativePath);
        if (resolved.exists()) {
            resolved.delete();
        }

        File parent = resolved.getParentFile();
        File exportRoot = new File(storageRoot, EXPORT_TEMP_DIR);
        if (parent != null && isUnder(exportRoot, parent) && !parent.equals(exportRoot)) {
            String[] remaining = parent.list();
            if (remaining == null || remaining.length == 0) {
                parent.delete();
            }
        }
    }

    //
    // Makes the folder one export's files are written into and returns it. The save tasks write to an absolute path in a folder that
    // exists, so the page asks for the folder first. The folder is resolved through PathSandbox and must sit under EXPORT_TEMP_DIR, so a
    // request cannot make a folder anywhere else in the storage root.
    //
    public static File prepareFolder(File storageRoot, String relativeFolder) throws IOException {
        File folder = PathSandbox.resolveWithin(storageRoot, relativeFolder);
        File exportRoot = new File(storageRoot, EXPORT_TEMP_DIR);
        if (!isUnder(exportRoot, folder) || folder.equals(exportRoot)) {
            throw new SecurityException("An export folder must be inside " + EXPORT_TEMP_DIR + ": " + relativeFolder);
        }
        if (!folder.isDirectory() && !folder.mkdirs()) {
            throw new IOException("Could not make the export folder " + relativeFolder);
        }
        return folder;
    }

    //
    // Reads the outcome a test staged for an export in place of the system's save picker: "shared" completes as if the user chose
    // a destination and "cancelled" as if they backed out. Returns true for cancelled. Any other word is an error, so a mistyped
    // outcome fails the test loudly instead of being taken for one of the two.
    //
    public static boolean isCancelledTestOutcome(String testOutcome) {
        if (testOutcome.equals("cancelled")) {
            return true;
        }
        if (testOutcome.equals("shared")) {
            return false;
        }
        throw new IllegalArgumentException("The staged export outcome \"" + testOutcome + "\" is not \"shared\" or \"cancelled\".");
    }

    //
    // Finishes a single-file export: deletes the temp copy (on every exit: shared, cancelled, error)
    // and returns the exported sandbox-relative path on success, or null when the user cancelled the
    // sheet. The frontend maps null to its "cancelled" undefined contract.
    //
    public static String finishExport(File storageRoot, String relativePath, boolean cancelled) {
        deleteTemp(storageRoot, relativePath);
        return cancelled ? null : relativePath;
    }

    //
    // Finishes a batch export: deletes every temp copy (on every exit) and returns the exported
    // sandbox-relative paths on success, or null when the user cancelled the sheet.
    //
    public static List<String> finishExportBatch(File storageRoot, List<String> relativePaths, boolean cancelled) {
        for (String relativePath : relativePaths) {
            deleteTemp(storageRoot, relativePath);
        }
        return cancelled ? null : relativePaths;
    }

    //
    // Removes the whole export temp directory and its contents on app start-up, collecting any temp
    // copy orphaned by a process kill that happened while the export sheet was still up.
    //
    public static void sweep(File storageRoot) {
        deleteRecursively(new File(storageRoot, EXPORT_TEMP_DIR));
    }

    //
    // Recursively deletes a file or directory tree. A missing path is a no-op.
    //
    private static void deleteRecursively(File target) {
        if (!target.exists()) {
            return;
        }
        File[] children = target.listFiles();
        if (children != null) {
            for (File child : children) {
                deleteRecursively(child);
            }
        }
        target.delete();
    }

    //
    // Reports whether candidate is the given root or sits beneath it, comparing canonical paths so a
    // symlink or `.` segment cannot slip a sibling directory past the check.
    //
    private static boolean isUnder(File root, File candidate) {
        try {
            String canonicalRoot = root.getCanonicalPath();
            String canonicalCandidate = candidate.getCanonicalPath();
            if (canonicalCandidate.equals(canonicalRoot)) {
                return true;
            }
            String rootWithSeparator = canonicalRoot.endsWith(File.separator)
                ? canonicalRoot
                : canonicalRoot + File.separator;
            return canonicalCandidate.startsWith(rootWithSeparator);
        }
        catch (IOException error) {
            return false;
        }
    }
}
