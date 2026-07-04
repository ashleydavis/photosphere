package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

//
// Plain-JVM unit tests for the pure photo-picker path helpers. They assert the sandbox-relative path
// and extension derivation the native picker relies on, with no Android runtime.
//
public final class ImportPickerTest {

    //
    // The extension comes from the display name when it has one.
    //
    @Test
    public void extensionFromDisplayName() {
        assertEquals("png", ImportPicker.extensionFor("photo.PNG", "image/jpeg"));
        assertEquals("jpeg", ImportPicker.extensionFor("holiday.jpeg", null));
    }

    //
    // With no usable display-name extension, the mime subtype is used.
    //
    @Test
    public void extensionFromMimeWhenNameHasNone() {
        assertEquals("jpeg", ImportPicker.extensionFor("IMG_0001", "image/jpeg"));
        assertEquals("png", ImportPicker.extensionFor(null, "image/png"));
        assertEquals("mp4", ImportPicker.extensionFor("clip", "video/mp4"));
    }

    //
    // With neither a usable name nor mime, the extension defaults to "bin".
    //
    @Test
    public void extensionDefaultsToBin() {
        assertEquals("bin", ImportPicker.extensionFor(null, null));
        assertEquals("bin", ImportPicker.extensionFor("noext", "image/*"));
        assertEquals("bin", ImportPicker.extensionFor(".hidden", "*/*"));
    }

    //
    // The relative path is "<IMPORT_TEMP_DIR>/<uuid>.<ext>".
    //
    @Test
    public void buildsRelativePathUnderImportTempDir() {
        String path = ImportPicker.buildRelativePath("abc-123", "cat.jpeg", "image/jpeg");
        assertEquals(".import-tmp/abc-123.jpeg", path);
    }
}
