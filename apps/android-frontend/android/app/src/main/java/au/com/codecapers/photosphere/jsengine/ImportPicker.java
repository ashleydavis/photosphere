package au.com.codecapers.photosphere.jsengine;

import java.util.Locale;

//
// Pure helpers for the native photo picker's copy-into-sandbox step. The picker copies each chosen
// item into a temp directory under the storage root and hands the import task sandbox-relative paths;
// these helpers build those paths deterministically. Kept free of Android types so they can be
// unit-tested on a plain JVM (the JsEnginePlugin Activity code that calls them cannot).
//
final class ImportPicker {

    //
    // The sandbox-relative directory picked media is copied into before import. Chosen so it is
    // ignored by the import scanner's ".db" filter is irrelevant here; the import task is handed these
    // exact paths, not a directory to scan.
    //
    static final String IMPORT_TEMP_DIR = ".import-tmp";

    //
    // Not instantiable; only static helpers.
    //
    private ImportPicker() {
    }

    //
    // Builds the sandbox-relative path a picked file is copied to: "<IMPORT_TEMP_DIR>/<uuid>.<ext>".
    // The extension is derived from the display name, then the mime type, then defaults to "bin".
    //
    static String buildRelativePath(String uuid, String displayName, String mimeType) {
        String extension = extensionFor(displayName, mimeType);
        return IMPORT_TEMP_DIR + "/" + uuid + "." + extension;
    }

    //
    // Derives a lowercase file extension for a picked item: the display name's own extension when it
    // has one, otherwise the mime subtype ("image/jpeg" -> "jpeg"), otherwise "bin". "jpg" is mapped
    // to "jpeg" so the extension matches the content type the importer infers.
    //
    static String extensionFor(String displayName, String mimeType) {
        String fromName = extensionFromName(displayName);
        if (fromName != null) {
            return fromName;
        }

        String fromMime = extensionFromMime(mimeType);
        if (fromMime != null) {
            return fromMime;
        }

        return "bin";
    }

    //
    // Returns the lowercase extension of a file name (the part after the last dot), or null when the
    // name is null/empty, has no dot, ends in a dot, or the dot is the first character.
    //
    private static String extensionFromName(String displayName) {
        if (displayName == null) {
            return null;
        }

        int dotIndex = displayName.lastIndexOf('.');
        if (dotIndex <= 0 || dotIndex == displayName.length() - 1) {
            return null;
        }

        return displayName.substring(dotIndex + 1).toLowerCase(Locale.ROOT);
    }

    //
    // Returns the subtype of a "type/subtype" mime string as a lowercase extension, or null when the
    // mime is null or malformed. "*" subtypes yield null.
    //
    private static String extensionFromMime(String mimeType) {
        if (mimeType == null) {
            return null;
        }

        int slashIndex = mimeType.indexOf('/');
        if (slashIndex < 0 || slashIndex == mimeType.length() - 1) {
            return null;
        }

        String subtype = mimeType.substring(slashIndex + 1).toLowerCase(Locale.ROOT);
        if (subtype.isEmpty() || subtype.equals("*")) {
            return null;
        }

        return subtype;
    }
}
