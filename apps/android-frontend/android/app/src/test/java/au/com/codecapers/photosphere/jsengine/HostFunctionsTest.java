package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

//
// Plain-JVM unit tests for the native fs READ host functions and their marshalling helpers. The fs
// functions are written against plain java.io so they run here with no Android stubs and no device.
// base64Encode is checked against java.util.Base64 (the JVM test runtime is a full JDK), the read
// functions are checked against real temp files, and the path sandbox rejections are asserted.
//
public final class HostFunctionsTest {

    //
    // A fresh temporary storage root per test, used as the sandbox root.
    //
    @Rule
    public TemporaryFolder temporaryFolder = new TemporaryFolder();

    //
    // Writes bytes to a file under the given root, creating parent directories as needed.
    //
    private File writeFile(File root, String relativePath, byte[] bytes) throws Exception {
        File target = new File(root, relativePath);
        File parent = target.getParentFile();
        if (parent != null) {
            parent.mkdirs();
        }
        try (FileOutputStream output = new FileOutputStream(target)) {
            output.write(bytes);
        }
        return target;
    }

    //
    // base64Encode must match java.util.Base64 for inputs of every length-mod-3 (covering the
    // zero/one/two trailing-byte padding cases) and for binary bytes including high values.
    //
    @Test
    public void base64EncodeMatchesJdk() {
        byte[][] inputs = new byte[][] {
            new byte[] {},
            new byte[] { 0 },
            new byte[] { 0, 1 },
            new byte[] { 0, 1, 2 },
            new byte[] { 0, 1, 2, 3 },
            new byte[] { (byte) 0xFF, (byte) 0xFE, (byte) 0x80, 0x7F, 0x00, (byte) 0xAA },
        };
        for (byte[] input : inputs) {
            assertEquals(Base64.getEncoder().encodeToString(input), HostFunctions.base64Encode(input));
        }
    }

    //
    // jsonEscape must escape quotes, backslashes, and control characters so directory listings
    // cannot produce malformed JSON.
    //
    @Test
    public void jsonEscapeEscapesSpecialCharacters() {
        assertEquals("a\\\"b", HostFunctions.jsonEscape("a\"b"));
        assertEquals("a\\\\b", HostFunctions.jsonEscape("a\\b"));
        assertEquals("a\\nb", HostFunctions.jsonEscape("a\nb"));
        assertEquals("plain.txt", HostFunctions.jsonEscape("plain.txt"));
    }

    //
    // fsReadFile returns the file bytes as base64 that decodes back to the original content.
    //
    @Test
    public void fsReadFileReturnsBase64OfContents() throws Exception {
        File root = temporaryFolder.getRoot();
        byte[] content = new byte[] { 0, 1, 2, (byte) 200, (byte) 255, 42 };
        writeFile(root, "db/data.bin", content);

        String base64 = HostFunctions.fsReadFile(root, "db/data.bin");
        assertArrayEquals(content, Base64.getDecoder().decode(base64));
    }

    //
    // fsReadFile returns null for a missing file and for a directory (not a regular file).
    //
    @Test
    public void fsReadFileReturnsNullForMissingOrDirectory() throws Exception {
        File root = temporaryFolder.getRoot();
        new File(root, "db").mkdirs();
        assertNull(HostFunctions.fsReadFile(root, "db/missing.bin"));
        assertNull(HostFunctions.fsReadFile(root, "db"));
    }

    //
    // fsAccess returns true for an existing file and directory, false for a missing path.
    //
    @Test
    public void fsAccessReflectsExistence() throws Exception {
        File root = temporaryFolder.getRoot();
        writeFile(root, "db/a.txt", "x".getBytes(StandardCharsets.UTF_8));
        assertTrue(HostFunctions.fsAccess(root, "db/a.txt"));
        assertTrue(HostFunctions.fsAccess(root, "db"));
        assertFalse(HostFunctions.fsAccess(root, "db/missing"));
    }

    //
    // fsStat reports size and type predicates for a file and for a directory, and null when missing.
    //
    @Test
    public void fsStatReportsFieldsAndNullWhenMissing() throws Exception {
        File root = temporaryFolder.getRoot();
        writeFile(root, "db/a.txt", "hello".getBytes(StandardCharsets.UTF_8));

        String fileStat = HostFunctions.fsStat(root, "db/a.txt");
        assertTrue(fileStat.contains("\"size\":5"));
        assertTrue(fileStat.contains("\"isFile\":true"));
        assertTrue(fileStat.contains("\"isDirectory\":false"));

        String dirStat = HostFunctions.fsStat(root, "db");
        assertTrue(dirStat.contains("\"isDirectory\":true"));
        assertTrue(dirStat.contains("\"isFile\":false"));

        assertNull(HostFunctions.fsStat(root, "db/missing"));
    }

    //
    // fsReaddir lists entries with their directory flag, and returns null for a missing directory or
    // a regular file.
    //
    @Test
    public void fsReaddirListsEntries() throws Exception {
        File root = temporaryFolder.getRoot();
        writeFile(root, "db/a.txt", "a".getBytes(StandardCharsets.UTF_8));
        new File(root, "db/sub").mkdirs();

        String listing = HostFunctions.fsReaddir(root, "db");
        assertTrue(listing.contains("\"name\":\"a.txt\""));
        assertTrue(listing.contains("\"name\":\"sub\""));
        assertTrue(listing.contains("\"name\":\"sub\",\"isDirectory\":true"));

        assertNull(HostFunctions.fsReaddir(root, "db/missing"));
        assertNull(HostFunctions.fsReaddir(root, "db/a.txt"));
    }

    //
    // base64Decode must invert base64Encode and match java.util.Base64 for inputs of every
    // length-mod-3 and for high-byte binary data.
    //
    @Test
    public void base64DecodeMatchesJdkAndRoundTrips() {
        byte[][] inputs = new byte[][] {
            new byte[] {},
            new byte[] { 0 },
            new byte[] { 0, 1 },
            new byte[] { 0, 1, 2 },
            new byte[] { (byte) 0xFF, (byte) 0xFE, (byte) 0x80, 0x7F, 0x00, (byte) 0xAA, 0x10 },
        };
        for (byte[] input : inputs) {
            String encoded = Base64.getEncoder().encodeToString(input);
            assertArrayEquals(input, HostFunctions.base64Decode(encoded));
            assertArrayEquals(Base64.getDecoder().decode(encoded), HostFunctions.base64Decode(encoded));
        }
    }

    //
    // fsWriteFile writes base64-decoded bytes and creates parent directories; the file reads back
    // byte-for-byte.
    //
    @Test
    public void fsWriteFileWritesBytesAndCreatesParents() throws Exception {
        File root = temporaryFolder.getRoot();
        byte[] content = new byte[] { 9, 8, 7, (byte) 254, 0, 33 };
        HostFunctions.fsWriteFile(root, "db/nested/out.bin", Base64.getEncoder().encodeToString(content), false);

        File written = new File(root, "db/nested/out.bin");
        assertTrue(written.isFile());
        assertArrayEquals(content, HostFunctions.readAllBytes(written));
    }

    //
    // fsWriteFile with exclusive=true throws an EEXIST-marked error when the file already exists, and
    // succeeds when it does not.
    //
    @Test
    public void fsWriteFileExclusiveThrowsWhenPresent() throws Exception {
        File root = temporaryFolder.getRoot();
        HostFunctions.fsWriteFile(root, "db/lock", Base64.getEncoder().encodeToString("a".getBytes(StandardCharsets.UTF_8)), true);
        try {
            HostFunctions.fsWriteFile(root, "db/lock", Base64.getEncoder().encodeToString("b".getBytes(StandardCharsets.UTF_8)), true);
            fail("Expected an EEXIST error for an exclusive write over an existing file");
        }
        catch (RuntimeException expected) {
            assertTrue(expected.getMessage().contains("EEXIST"));
        }
    }

    //
    // fsMkdir creates nested directories recursively and is a no-op when the directory exists.
    //
    @Test
    public void fsMkdirCreatesRecursivelyAndIsIdempotent() {
        File root = temporaryFolder.getRoot();
        HostFunctions.fsMkdir(root, "db/a/b/c", true);
        assertTrue(new File(root, "db/a/b/c").isDirectory());
        // Idempotent: a second call does not throw.
        HostFunctions.fsMkdir(root, "db/a/b/c", true);
    }

    //
    // fsRename moves a file and overwrites an existing destination.
    //
    @Test
    public void fsRenameMovesAndOverwrites() throws Exception {
        File root = temporaryFolder.getRoot();
        writeFile(root, "db/src.txt", "source".getBytes(StandardCharsets.UTF_8));
        writeFile(root, "db/dest.txt", "old-dest".getBytes(StandardCharsets.UTF_8));

        HostFunctions.fsRename(root, "db/src.txt", "db/dest.txt");

        assertFalse(new File(root, "db/src.txt").exists());
        assertArrayEquals("source".getBytes(StandardCharsets.UTF_8), HostFunctions.readAllBytes(new File(root, "db/dest.txt")));
    }

    //
    // fsUnlink deletes a file and throws ENOENT when it is missing.
    //
    @Test
    public void fsUnlinkDeletesAndThrowsWhenMissing() throws Exception {
        File root = temporaryFolder.getRoot();
        writeFile(root, "db/a.txt", "x".getBytes(StandardCharsets.UTF_8));
        HostFunctions.fsUnlink(root, "db/a.txt");
        assertFalse(new File(root, "db/a.txt").exists());
        try {
            HostFunctions.fsUnlink(root, "db/a.txt");
            fail("Expected ENOENT for unlink of a missing file");
        }
        catch (RuntimeException expected) {
            assertTrue(expected.getMessage().contains("ENOENT"));
        }
    }

    //
    // fsRm removes a directory tree; with force a missing path is a no-op.
    //
    @Test
    public void fsRmRemovesTreeAndForceIgnoresMissing() throws Exception {
        File root = temporaryFolder.getRoot();
        writeFile(root, "db/sub/a.txt", "a".getBytes(StandardCharsets.UTF_8));
        writeFile(root, "db/sub/b.txt", "b".getBytes(StandardCharsets.UTF_8));
        HostFunctions.fsRm(root, "db/sub", true, false);
        assertFalse(new File(root, "db/sub").exists());
        // force: missing path does not throw.
        HostFunctions.fsRm(root, "db/missing", true, true);
    }

    //
    // hostErrorEnvelope encodes the error message with the recognised code (EEXIST/ENOENT) so the JS
    // shim decodes and throws it. The prefix and code segment must match the shared format.
    //
    @Test
    public void hostErrorEnvelopeEncodesCodeAndMessage() {
        assertEquals("@@HOSTERR@@EEXIST:EEXIST: file already exists: x",
            HostFunctions.hostErrorEnvelope(new RuntimeException("EEXIST: file already exists: x")));
        assertEquals("@@HOSTERR@@ENOENT:ENOENT: missing",
            HostFunctions.hostErrorEnvelope(new RuntimeException("ENOENT: missing")));
        assertEquals("@@HOSTERR@@:some other failure",
            HostFunctions.hostErrorEnvelope(new RuntimeException("some other failure")));
    }

    //
    // Path sandbox rejection: absolute paths and `..` traversal must throw before any IO, on every
    // path-taking fs function.
    //
    @Test
    public void fsFunctionsRejectAbsoluteAndTraversalPaths() {
        File root = temporaryFolder.getRoot();
        assertRejected(() -> HostFunctions.fsReadFile(root, "/etc/passwd"));
        assertRejected(() -> HostFunctions.fsReadFile(root, "../escape"));
        assertRejected(() -> HostFunctions.fsAccess(root, "/etc"));
        assertRejected(() -> HostFunctions.fsStat(root, "../../escape"));
        assertRejected(() -> HostFunctions.fsReaddir(root, "/"));
        assertRejected(() -> HostFunctions.fsWriteFile(root, "/tmp/evil", "AA==", false));
        assertRejected(() -> HostFunctions.fsMkdir(root, "../evil", true));
        assertRejected(() -> HostFunctions.fsRename(root, "../a", "b"));
    }

    //
    // The digest of an empty file, which is the SHA-256 of no bytes at all. A hasher that never fed
    // its digest anything returns exactly this, so it is the one case worth pinning by hand: it
    // catches the stream loop being skipped entirely.
    //
    private static final String EMPTY_SHA256 =
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";

    //
    // The digest of the three ASCII bytes "abc", the standard SHA-256 test vector.
    //
    private static final String ABC_SHA256 =
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

    //
    // A known input hashes to its published digest. Pinned against the standard vector rather than
    // against another run of the same code, because the whole value of this function is that it
    // agrees with what Node's crypto produced for every asset already in every database.
    //
    @Test
    public void sha256MatchesTheKnownVectorForAbc() throws Exception {
        File root = temporaryFolder.getRoot();
        File target = new File(root, "abc.bin");
        try (FileOutputStream output = new FileOutputStream(target)) {
            output.write("abc".getBytes(StandardCharsets.UTF_8));
        }

        assertEquals(ABC_SHA256, HostFunctions.sha256(root, "abc.bin"));
    }

    //
    // An empty file hashes to the digest of no bytes, rather than to null or an error.
    //
    @Test
    public void sha256HandlesAnEmptyFile() throws Exception {
        File root = temporaryFolder.getRoot();
        File target = new File(root, "empty.bin");
        try (FileOutputStream output = new FileOutputStream(target)) {
            // Deliberately writes nothing.
        }

        assertEquals(EMPTY_SHA256, HostFunctions.sha256(root, "empty.bin"));
    }

    //
    // A file bigger than one read buffer hashes the same as the JDK's own digest over the same
    // bytes. This is what proves the streaming loop feeds every chunk in, in order: a loop that
    // dropped or repeated a buffer would still return a plausible-looking digest.
    //
    @Test
    public void sha256StreamsAFileLargerThanItsReadBuffer() throws Exception {
        File root = temporaryFolder.getRoot();
        byte[] contents = new byte[(1024 * 1024 * 2) + 12345];
        for (int index = 0; index < contents.length; index++) {
            contents[index] = (byte) (index % 251);
        }

        File target = new File(root, "large.bin");
        try (FileOutputStream output = new FileOutputStream(target)) {
            output.write(contents);
        }

        String expected = HostFunctions.toHex(
            java.security.MessageDigest.getInstance("SHA-256").digest(contents));
        assertEquals(expected, HostFunctions.sha256(root, "large.bin"));
    }

    //
    // A missing file answers null, the same as fsReadFile, which the shim turns into ENOENT.
    //
    @Test
    public void sha256AnswersNullForAMissingFile() {
        File root = temporaryFolder.getRoot();
        assertNull(HostFunctions.sha256(root, "nothing-here.bin"));
    }

    //
    // A directory is not a file and must not be hashed as one.
    //
    @Test
    public void sha256AnswersNullForADirectory() {
        File root = temporaryFolder.getRoot();
        assertTrue(new File(root, "a-directory").mkdir());
        assertNull(HostFunctions.sha256(root, "a-directory"));
    }

    //
    // Hashing goes through the same sandbox as every other path-taking host function, so a path
    // outside the storage root is refused rather than read.
    //
    @Test
    public void sha256RefusesAPathOutsideTheSandbox() {
        File root = temporaryFolder.getRoot();
        assertRejected(() -> HostFunctions.sha256(root, "../../etc/passwd"));
        assertRejected(() -> HostFunctions.sha256(root, "/etc/passwd"));
    }

    //
    // Asserts that running the action throws a SecurityException (the PathSandbox rejection).
    //
    private void assertRejected(Runnable action) {
        try {
            action.run();
            fail("Expected a SecurityException for a sandbox-violating path");
        }
        catch (SecurityException expected) {
            // Expected.
        }
    }
}
