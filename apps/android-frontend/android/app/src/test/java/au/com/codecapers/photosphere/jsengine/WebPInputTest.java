package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;

//
// Covers the parts of the WebP substitution that decide what gets converted and which argument names
// the input. The decode itself is Android's and is exercised by the import running on a device.
//
public class WebPInputTest {

    //
    // Writes bytes to a throwaway file and returns it.
    //
    private File fileContaining(byte[] contents) throws IOException {
        File file = File.createTempFile("webp-input-test", ".bin");
        file.deleteOnExit();
        try (FileOutputStream stream = new FileOutputStream(file)) {
            stream.write(contents);
        }

        return file;
    }

    @Test
    public void theInputOfAPlainCommandIsItsFirstArgument() {
        assertEquals(0, WebPInput.inputPathIndex(new String[] { "/photos/a.webp", "-resize", "300x300" }));
    }

    @Test
    public void theInputOfAnIdentifyComesAfterTheSubcommand() {
        assertEquals(1, WebPInput.inputPathIndex(new String[] { "identify", "/photos/a.webp", "-format", "%w" }));
    }

    @Test
    public void anArgvWithNothingInItNamesNoInput() {
        assertEquals(-1, WebPInput.inputPathIndex(new String[] {}));
    }

    @Test
    public void anIdentifyWithNoPathAfterItNamesNoInputToSubstitute() {
        assertEquals(0, WebPInput.inputPathIndex(new String[] { "identify" }));
    }

    @Test
    public void aRiffContainerMarkedWebPIsOne() throws IOException {
        byte[] header = { 'R', 'I', 'F', 'F', 0x10, 0, 0, 0, 'W', 'E', 'B', 'P', 'V', 'P', '8', 'X' };
        assertTrue(WebPInput.isWebP(fileContaining(header)));
    }

    @Test
    public void aRiffContainerOfSomethingElseIsNot() throws IOException {
        byte[] header = { 'R', 'I', 'F', 'F', 0x10, 0, 0, 0, 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ' };
        assertFalse(WebPInput.isWebP(fileContaining(header)));
    }

    @Test
    public void aJpegIsNot() throws IOException {
        byte[] header = { (byte) 0xFF, (byte) 0xD8, (byte) 0xFF, (byte) 0xE0, 0, 0x10, 'J', 'F', 'I', 'F', 0, 1, 0, 0, 0, 0 };
        assertFalse(WebPInput.isWebP(fileContaining(header)));
    }

    @Test
    public void aFileTooShortToCarryTheHeaderIsNot() throws IOException {
        assertFalse(WebPInput.isWebP(fileContaining(new byte[] { 'R', 'I', 'F', 'F' })));
    }

    @Test
    public void aFileThatIsNotThereIsNot() {
        assertFalse(WebPInput.isWebP(new File("/no/such/file.webp")));
    }
}
