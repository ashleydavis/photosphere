package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

//
// Proves the app can hold its databases.toml on device.
//
// The database list lives in databases.toml at the root of the app's storage sandbox, read and
// written by the read-databases-config / write-databases-config worker tasks. Those tasks reach the
// file through FileStorage, which on device calls the native fs host functions tested here. The
// TypeScript tests cover the TOML itself; what they cannot reach is whether the native layer will
// actually serve a file at that path, which is what these assert:
//
//   - a config written at the sandbox root can be read back byte for byte
//   - the file is visible to the existence check the read path gates on
//   - a config that is not there reads as absent rather than failing, which is a fresh install
//   - the path stays inside the sandbox, so the config cannot be pointed outside the app
//
// The fs functions are plain java.io, so this runs on the JVM with no device and no Android stubs,
// the same as HostFunctionsTest.
//
public final class DatabasesConfigFileTest {

    //
    // A fresh temporary storage root per test, standing in for the app's private files directory.
    //
    @Rule
    public TemporaryFolder temporaryFolder = new TemporaryFolder();

    //
    // The name the app reads its database list from, relative to the storage root. Must match
    // DATABASES_CONFIG_PATH in packages/mobile-frontend/src/lib/mobile-databases-config-file.ts.
    //
    private static final String DATABASES_CONFIG = "databases.toml";

    //
    // A databases config in the format both platforms read and write, holding one of the user's own
    // databases and one seeded test database.
    //
    private static final String CONFIG_TOML =
        "recent_database_names = [ \"My photos\" ]\n"
        + "\n"
        + "[[databases]]\n"
        + "name = \"My photos\"\n"
        + "description = \"Everything\"\n"
        + "path = \"/storage/photos\"\n"
        + "s3_key = \"default:s3\"\n"
        + "\n"
        + "[[databases]]\n"
        + "name = \"test-50-assets\"\n"
        + "description = \"\"\n"
        + "path = \"50-assets\"\n";

    //
    // Writes text to a sandbox-relative path through the native write host function, the way the
    // write-databases-config task does.
    //
    private void writeConfig(File storageRoot, String relativePath, String contents) {
        String base64 = Base64.getEncoder().encodeToString(contents.getBytes(StandardCharsets.UTF_8));
        HostFunctions.fsWriteFile(storageRoot, relativePath, base64, false);
    }

    //
    // Reads a sandbox-relative path through the native read host function and decodes it, the way the
    // read-databases-config task does. Returns null when the file is not there.
    //
    private String readConfig(File storageRoot, String relativePath) {
        String base64 = HostFunctions.fsReadFile(storageRoot, relativePath);
        if (base64 == null) {
            return null;
        }
        return new String(Base64.getDecoder().decode(base64), StandardCharsets.UTF_8);
    }

    //
    // A config written at the sandbox root comes back exactly as written. This is the round trip the
    // app depends on: the write task saves the list, the read task loads it on the next start.
    //
    @Test
    public void databasesConfigRoundTripsAtTheSandboxRoot() {
        File storageRoot = temporaryFolder.getRoot();
        writeConfig(storageRoot, DATABASES_CONFIG, CONFIG_TOML);

        assertEquals(CONFIG_TOML, readConfig(storageRoot, DATABASES_CONFIG));
    }

    //
    // The file lands where the sandbox says it should, at the root of the app's storage directory
    // rather than anywhere else under it.
    //
    @Test
    public void databasesConfigIsWrittenAtTheRootOfTheStorageDirectory() {
        File storageRoot = temporaryFolder.getRoot();
        writeConfig(storageRoot, DATABASES_CONFIG, CONFIG_TOML);

        File expected = new File(storageRoot, DATABASES_CONFIG);
        assertTrue("databases.toml should exist at the storage root", expected.isFile());
    }

    //
    // The read path checks the file exists before reading it, so that check has to see the config.
    //
    @Test
    public void databasesConfigIsVisibleToTheExistenceCheck() {
        File storageRoot = temporaryFolder.getRoot();
        assertFalse(HostFunctions.fsAccess(storageRoot, DATABASES_CONFIG));

        writeConfig(storageRoot, DATABASES_CONFIG, CONFIG_TOML);

        assertTrue(HostFunctions.fsAccess(storageRoot, DATABASES_CONFIG));
    }

    //
    // A device that has never registered a database has no config, and that must read as absent. It
    // is the state of every fresh install, and the app starts from an empty list rather than failing.
    //
    @Test
    public void aMissingDatabasesConfigReadsAsAbsent() {
        File storageRoot = temporaryFolder.getRoot();

        assertFalse(HostFunctions.fsAccess(storageRoot, DATABASES_CONFIG));
        assertEquals(null, HostFunctions.fsReadFile(storageRoot, DATABASES_CONFIG));
    }

    //
    // Rewriting the config replaces it rather than appending, so removing a database really removes
    // it instead of leaving the old list behind the new one.
    //
    @Test
    public void rewritingTheDatabasesConfigReplacesIt() {
        File storageRoot = temporaryFolder.getRoot();
        writeConfig(storageRoot, DATABASES_CONFIG, CONFIG_TOML);

        String shorter = "recent_database_names = [ ]\n";
        writeConfig(storageRoot, DATABASES_CONFIG, shorter);

        assertEquals(shorter, readConfig(storageRoot, DATABASES_CONFIG));
    }

    //
    // Non-ASCII survives the round trip. Database names are free text, so a config naming a database
    // in another script has to come back unmangled rather than as replacement characters.
    //
    @Test
    public void databasesConfigRoundTripsNonAsciiNames() {
        File storageRoot = temporaryFolder.getRoot();
        String toml =
            "recent_database_names = [ \"Fotos münchen\" ]\n"
            + "\n"
            + "[[databases]]\n"
            + "name = \"Fotos münchen\"\n"
            + "description = \"Ferien 🌴\"\n"
            + "path = \"fotos\"\n";
        writeConfig(storageRoot, DATABASES_CONFIG, toml);

        assertEquals(toml, readConfig(storageRoot, DATABASES_CONFIG));
    }

    //
    // The config path is sandboxed like every other path: it cannot be pointed outside the app's
    // storage, so nothing can be tricked into reading or writing another app's config.
    //
    @Test
    public void theDatabasesConfigPathCannotEscapeTheSandbox() {
        File storageRoot = temporaryFolder.getRoot();

        try {
            HostFunctions.fsReadFile(storageRoot, "../" + DATABASES_CONFIG);
            fail("reading a config outside the sandbox should be rejected");
        }
        catch (RuntimeException expected) {
            assertNotNull(expected);
        }

        try {
            writeConfig(storageRoot, "/etc/" + DATABASES_CONFIG, CONFIG_TOML);
            fail("writing a config outside the sandbox should be rejected");
        }
        catch (RuntimeException expected) {
            assertNotNull(expected);
        }
    }
}
