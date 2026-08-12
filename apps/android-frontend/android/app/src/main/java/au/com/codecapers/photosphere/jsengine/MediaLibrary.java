package au.com.codecapers.photosphere.jsengine;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

//
// Pure helpers for reading the device photo library, mirroring the iOS MediaLibrary. Automatic
// import walks the library a page at a time, exports a chosen item into the sandbox so the import
// task can read it as a file, and deletes source files in batches once they are confirmed in the
// database.
//
// Kept free of Android types so it can be unit-tested on a plain JVM. The MediaStore query, the
// content observer and the delete request need an Activity and a ContentResolver and live in the
// plugin code that calls these.
//
public final class MediaLibrary {

    //
    // The sandbox-relative directory an exported library item is copied into before import. Separate
    // from the picker's own temp directory so a background export and a user's pick cannot collide,
    // and so a sweep of one does not take the other's files.
    //
    public static final String MEDIA_TEMP_DIR = ".media-tmp";

    //
    // How many items a delete request may cover. Android 11 and later force a system confirmation
    // for media the app does not own, so deleting one photo per request would mean one dialog per
    // photo. One request per batch is one dialog per batch.
    //
    public static final int DELETE_BATCH_SIZE = 50;

    //
    // Not instantiable; only static helpers.
    //
    private MediaLibrary() {
    }

    //
    // Where in the library a page starts, read from the opaque cursor the auto-import task hands
    // back. An absent or unreadable cursor starts at the beginning rather than failing: the cursor
    // is persisted between runs, and a database written by an older build has none.
    //
    public static int offsetFromCursor(String cursor) {
        if (cursor == null || cursor.isEmpty()) {
            return 0;
        }

        try {
            int offset = Integer.parseInt(cursor);
            return offset < 0 ? 0 : offset;
        }
        catch (NumberFormatException error) {
            return 0;
        }
    }

    //
    // The cursor for the page after this one, or null at the end of the library.
    //
    // Null is what tells the caller to stop, so it is returned only when this page reached the end.
    // A page that came back short because the library changed under us still yields a cursor, and
    // the next query simply finds nothing.
    //
    public static String nextCursor(int offset, int itemsReturned, int totalCount) {
        int nextOffset = offset + itemsReturned;
        if (itemsReturned <= 0 || nextOffset >= totalCount) {
            return null;
        }
        return String.valueOf(nextOffset);
    }

    //
    // The sandbox-relative path a library item is exported to: "<MEDIA_TEMP_DIR>/<id>.<ext>".
    //
    // The item's own library id is used rather than a fresh uuid, so exporting the same item twice
    // lands on the same path and a file left behind by a killed run is reused rather than orphaned.
    //
    public static String buildExportPath(String itemId, String displayName, String mimeType) {
        String extension = ImportPicker.extensionFor(displayName, mimeType);
        return MEDIA_TEMP_DIR + "/" + sanitiseId(itemId) + "." + extension;
    }

    //
    // Makes a library id safe to use as a file name. MediaStore ids are numeric, but the id arrives
    // here as a string from the JavaScript side, and a path separator in it would put the export
    // somewhere other than the temp directory.
    //
    static String sanitiseId(String itemId) {
        if (itemId == null || itemId.isEmpty()) {
            return "unknown";
        }

        StringBuilder safe = new StringBuilder(itemId.length());
        for (int index = 0; index < itemId.length(); index += 1) {
            char character = itemId.charAt(index);
            boolean allowed = (character >= 'a' && character <= 'z')
                || (character >= 'A' && character <= 'Z')
                || (character >= '0' && character <= '9')
                || character == '-'
                || character == '_';
            safe.append(allowed ? character : '-');
        }
        return safe.toString();
    }

    //
    // Whether a library item is media automatic import can take in. MediaStore hands back whatever
    // is in the images and video collections, which includes types the import cannot process.
    //
    public static boolean isSupportedMimeType(String mimeType) {
        if (mimeType == null) {
            return false;
        }

        String lower = mimeType.toLowerCase(Locale.ROOT);
        if (lower.equals("image/svg+xml") || lower.startsWith("image/vnd.adobe.photoshop")) {
            return false;
        }
        return lower.startsWith("image/") || lower.startsWith("video/");
    }

    //
    // One album in the device photo library, as the settings list shows it.
    //
    public static final class Album {
        //
        // The bucket id MediaStore groups the album's items under.
        //
        public final String id;

        //
        // The album's name, as the user sees it.
        //
        public final String name;

        //
        // How many items the album holds.
        //
        public final int itemCount;

        public Album(String id, String name, int itemCount) {
            this.id = id;
            this.name = name;
            this.itemCount = itemCount;
        }
    }

    //
    // Groups the bucket id and name of every library item into a list of albums with counts.
    //
    // MediaStore has no album table: an album is a bucket that items say they belong to, so the only
    // way to list albums is to look at what the items claim. Insertion order is kept, so the list is
    // in the order the query returned rather than an order that changes between calls.
    //
    public static List<Album> groupAlbums(List<String> bucketIds, List<String> bucketNames) {
        if (bucketIds.size() != bucketNames.size()) {
            throw new IllegalArgumentException(
                "Album ids and names must line up: got " + bucketIds.size() + " ids and " + bucketNames.size() + " names.");
        }

        Map<String, Album> albumsById = new LinkedHashMap<>();
        for (int index = 0; index < bucketIds.size(); index += 1) {
            String bucketId = bucketIds.get(index);
            if (bucketId == null || bucketId.isEmpty()) {
                continue;
            }

            String bucketName = bucketNames.get(index);
            Album existing = albumsById.get(bucketId);
            if (existing == null) {
                albumsById.put(bucketId, new Album(bucketId, bucketName == null ? "" : bucketName, 1));
            }
            else {
                albumsById.put(bucketId, new Album(existing.id, existing.name, existing.itemCount + 1));
            }
        }

        return new ArrayList<>(albumsById.values());
    }

    //
    // Splits the ids to delete into batches, so each batch becomes one system confirmation rather
    // than one per photo.
    //
    public static List<List<String>> buildDeleteBatches(List<String> itemIds, int batchSize) {
        if (batchSize < 1) {
            throw new IllegalArgumentException("Delete batch size must be at least 1, got " + batchSize + ".");
        }

        List<List<String>> batches = new ArrayList<>();
        for (int start = 0; start < itemIds.size(); start += batchSize) {
            int end = Math.min(start + batchSize, itemIds.size());
            batches.add(new ArrayList<>(itemIds.subList(start, end)));
        }
        return batches;
    }
}
