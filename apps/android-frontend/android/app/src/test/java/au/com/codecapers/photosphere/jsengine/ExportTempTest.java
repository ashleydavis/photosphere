package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;

import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.List;

//
// Plain-JVM unit tests for the asset-export temp lifecycle helpers. They assert the parts either side
// of the (untestable) share sheet: the sandbox temp path stays inside PathSandbox, the copied bytes
// match the source, the completion handler deletes the temp on every exit (shared, cancelled, error),
// cancel yields null while success yields the path, and the start-up sweep removes an orphan.
//
public final class ExportTempTest {

    //
    // A fresh temporary storage root per test, standing in for the app's private files directory.
    //
    private File storageRoot;

    //
    // Creates a unique temporary directory to act as the storage root.
    //
    @Before
    public void setUp() throws IOException {
        storageRoot = Files.createTempDirectory("export-temp-test").toFile();
    }

    //
    // Removes the temporary storage root after each test.
    //
    @After
    public void tearDown() {
        deleteRecursively(storageRoot);
    }

    //
    // The export temp path the frontend builds resolves to a location inside the storage root.
    //
    @Test
    public void tempPathStaysInsideSandbox() {
        String relativePath = ExportTemp.EXPORT_TEMP_DIR + "/uuid-1/cat.jpeg";
        File resolved = PathSandbox.resolveWithin(storageRoot, relativePath);
        assertTrue(resolved.getAbsolutePath().startsWith(storageRoot.getAbsolutePath()));
        assertTrue(resolved.getName().equals("cat.jpeg"));
    }

    //
    // copyStream reproduces the source bytes exactly into the destination stream.
    //
    @Test
    public void copyStreamMatchesSourceBytes() throws IOException {
        byte[] source = "the decrypted original bytes".getBytes(StandardCharsets.UTF_8);
        ByteArrayInputStream input = new ByteArrayInputStream(source);
        ByteArrayOutputStream output = new ByteArrayOutputStream();

        ExportTemp.copyStream(input, output);

        assertArrayEquals(source, output.toByteArray());
    }

    //
    // finishExport on the shared exit deletes the temp copy and returns the exported path.
    //
    @Test
    public void finishExportSharedDeletesTempAndReturnsPath() throws IOException {
        String relativePath = writeTemp("uuid-a/cat.jpeg", "bytes");

        String result = ExportTemp.finishExport(storageRoot, relativePath, false);

        assertEquals(relativePath, result);
        assertFalse(new File(storageRoot, relativePath).exists());
        // The now-empty per-export directory is cleaned up too.
        assertFalse(new File(storageRoot, ExportTemp.EXPORT_TEMP_DIR + "/uuid-a").exists());
    }

    //
    // finishExport on the cancelled exit deletes the temp copy and returns null.
    //
    @Test
    public void finishExportCancelledDeletesTempAndReturnsNull() throws IOException {
        String relativePath = writeTemp("uuid-b/cat.jpeg", "bytes");

        String result = ExportTemp.finishExport(storageRoot, relativePath, true);

        assertNull(result);
        assertFalse(new File(storageRoot, relativePath).exists());
    }

    //
    // finishExportBatch deletes every temp copy on the shared exit and returns the paths.
    //
    @Test
    public void finishExportBatchSharedDeletesAllAndReturnsPaths() throws IOException {
        String first = writeTemp("uuid-c/a.jpeg", "a");
        String second = writeTemp("uuid-c/b.png", "bb");
        List<String> paths = Arrays.asList(first, second);

        List<String> result = ExportTemp.finishExportBatch(storageRoot, paths, false);

        assertEquals(paths, result);
        assertFalse(new File(storageRoot, first).exists());
        assertFalse(new File(storageRoot, second).exists());
    }

    //
    // finishExportBatch deletes every temp copy on the cancelled exit and returns null.
    //
    @Test
    public void finishExportBatchCancelledDeletesAllAndReturnsNull() throws IOException {
        String first = writeTemp("uuid-d/a.jpeg", "a");
        String second = writeTemp("uuid-d/b.png", "bb");

        List<String> result = ExportTemp.finishExportBatch(storageRoot, Arrays.asList(first, second), true);

        assertNull(result);
        assertFalse(new File(storageRoot, first).exists());
        assertFalse(new File(storageRoot, second).exists());
    }

    //
    // The start-up sweep removes an orphaned temp copy left by a kill mid-sheet.
    //
    @Test
    public void sweepRemovesOrphanedTemp() throws IOException {
        writeTemp("uuid-orphan/cat.jpeg", "left behind");
        assertTrue(new File(storageRoot, ExportTemp.EXPORT_TEMP_DIR).exists());

        ExportTemp.sweep(storageRoot);

        assertFalse(new File(storageRoot, ExportTemp.EXPORT_TEMP_DIR).exists());
    }

    //
    // Writes a temp file at "<EXPORT_TEMP_DIR>/<subPath>" with the given text and returns its
    // sandbox-relative path.
    //
    private String writeTemp(String subPath, String text) throws IOException {
        String relativePath = ExportTemp.EXPORT_TEMP_DIR + "/" + subPath;
        File file = new File(storageRoot, relativePath);
        file.getParentFile().mkdirs();
        Files.write(file.toPath(), text.getBytes(StandardCharsets.UTF_8));
        return relativePath;
    }

    //
    // Recursively deletes a directory tree used by a test.
    //
    private void deleteRecursively(File target) {
        if (target == null || !target.exists()) {
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
}
