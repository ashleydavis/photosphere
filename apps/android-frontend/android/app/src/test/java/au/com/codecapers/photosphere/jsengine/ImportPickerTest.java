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
    // A "jpg" display-name extension is used verbatim (lowercased), not remapped to "jpeg", even when
    // the mime type is "image/jpeg". The display name's own extension wins over the mime subtype.
    //
    @Test
    public void jpgDisplayNameExtensionIsUsedVerbatim() {
        assertEquals("jpg", ImportPicker.extensionFor("cat.jpg", "image/jpeg"));
        assertEquals("jpg", ImportPicker.extensionFor("cat.JPG", null));
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
    // The cross-platform parity table. Every case here must yield the same extension on iOS, where
    // ImportPickerTests.testSharedParityCases asserts the identical inputs and results (passing no
    // file extension, the one source Android has no counterpart for). The two tables are mirrored on
    // purpose: a change to one platform's inference that is not made to the other breaks one of them,
    // rather than silently letting the same photo import differently on each platform.
    //
    @Test
    public void sharedParityCases() {
        // A name extension wins over the mime type, and is lowercased.
        assertEquals("png", ImportPicker.extensionFor("photo.PNG", "image/jpeg"));

        // Used verbatim: no jpg -> jpeg remap on either platform.
        assertEquals("jpg", ImportPicker.extensionFor("cat.jpg", "image/jpeg"));

        // The last dot wins, so a double extension keeps only its final part.
        assertEquals("gz", ImportPicker.extensionFor("archive.tar.gz", null));

        // No usable name extension, so the mime subtype is used. This is the case iOS used to fail.
        assertEquals("jpeg", ImportPicker.extensionFor("IMG_0001", "image/jpeg"));

        // The subtype is used verbatim, even when it is not a real extension.
        assertEquals("quicktime", ImportPicker.extensionFor("clip", "video/quicktime"));

        // A trailing dot is not an extension, so the mime subtype is used.
        assertEquals("jpeg", ImportPicker.extensionFor("trailing.", "image/jpeg"));

        // A leading dot marks a hidden file, not an extension, so the mime subtype is used.
        assertEquals("png", ImportPicker.extensionFor(".hidden", "image/png"));

        // A wildcard subtype names no format, so it falls through to the default.
        assertEquals("bin", ImportPicker.extensionFor("noext", "image/*"));

        // A mime with no slash, or an empty subtype, is malformed and falls through.
        assertEquals("bin", ImportPicker.extensionFor(null, "image"));
        assertEquals("bin", ImportPicker.extensionFor(null, "image/"));

        // Nothing usable at all.
        assertEquals("bin", ImportPicker.extensionFor(null, null));
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
