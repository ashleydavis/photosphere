package au.com.codecapers.photosphere.jsengine;

import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.provider.MediaStore;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;

//
// Reads the device photo library through MediaStore, for automatic import.
//
// The pure decisions (where a page starts and stops, the sandbox path an export lands on, which
// types are supported, grouping albums, batching deletions) are in MediaLibrary and unit tested on a
// plain JVM. This class is the part that needs Android: the ContentResolver queries, copying an item
// into the sandbox, and handing a delete request to whatever can present the system confirmation.
//
public final class MediaLibraryHost {

    //
    // Buffer size used when copying a library item into the sandbox.
    //
    private static final int COPY_BUFFER_SIZE = 64 * 1024;

    //
    // The columns every listed item needs.
    //
    private static final String[] ITEM_PROJECTION = new String[] {
        MediaStore.Files.FileColumns._ID,
        MediaStore.Files.FileColumns.DISPLAY_NAME,
        MediaStore.Files.FileColumns.MIME_TYPE,
        MediaStore.Files.FileColumns.SIZE,
        MediaStore.Files.FileColumns.DATE_ADDED,
        MediaStore.Files.FileColumns.BUCKET_ID,
        MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME,
    };

    //
    // Newest first, so a backfill that is interrupted has brought in the photos the user is most
    // likely to want first.
    //
    private static final String SORT_NEWEST_FIRST = MediaStore.Files.FileColumns.DATE_ADDED + " DESC";

    //
    // Presents the system confirmation for deleting media the app does not own, and reports what the
    // user chose. Android 11 and later require this; there is no way for an app to delete another
    // app's media silently.
    //
    public interface DeleteRequester {
        //
        // Asks to delete the given items as one request, and returns true when they were deleted.
        //
        boolean requestDelete(List<Uri> itemUris);
    }

    //
    // The Android context whose ContentResolver the library is read through.
    //
    private final Context androidContext;

    //
    // The sandbox root exported items are written under.
    //
    private final File storageRoot;

    //
    // Presents the delete confirmation, or null when nothing can present one.
    //
    private volatile DeleteRequester deleteRequester;

    public MediaLibraryHost(Context androidContext, File storageRoot) {
        this.androidContext = androidContext;
        this.storageRoot = storageRoot;
    }

    //
    // Installs whatever can present the system delete confirmation. Set by the plugin, which owns
    // the Activity the dialog needs.
    //
    public void setDeleteRequester(DeleteRequester requester) {
        this.deleteRequester = requester;
    }

    //
    // The collection holding both images and videos.
    //
    private static Uri contentUri() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL);
        }
        return MediaStore.Files.getContentUri("external");
    }

    //
    // Selects the images and videos, and nothing else in the files collection.
    //
    private static String mediaSelection() {
        return MediaStore.Files.FileColumns.MEDIA_TYPE + " IN (?, ?)";
    }

    //
    // The media types the selection above binds.
    //
    private static String[] mediaSelectionArgs() {
        return new String[] {
            String.valueOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE),
            String.valueOf(MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO),
        };
    }

    //
    // Reads one page of the library, newest first.
    //
    // How a page is asked for depends on the version: from Android 11 the limit and offset go in a
    // query bundle, and appending "LIMIT n OFFSET m" to the sort order is rejected outright with
    // "Invalid token LIMIT". Earlier versions have no bundle arguments and only understand the
    // appended form. Both are here because minSdk is 24 and the app runs on both.
    //
    private Cursor queryPage(int limit, int offset) {
        ContentResolver resolver = androidContext.getContentResolver();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            android.os.Bundle queryArgs = new android.os.Bundle();
            queryArgs.putString(ContentResolver.QUERY_ARG_SQL_SELECTION, mediaSelection());
            queryArgs.putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, mediaSelectionArgs());
            queryArgs.putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS,
                new String[] { MediaStore.Files.FileColumns.DATE_ADDED });
            queryArgs.putInt(ContentResolver.QUERY_ARG_SORT_DIRECTION, ContentResolver.QUERY_SORT_DIRECTION_DESCENDING);
            queryArgs.putInt(ContentResolver.QUERY_ARG_LIMIT, limit);
            queryArgs.putInt(ContentResolver.QUERY_ARG_OFFSET, offset);
            return resolver.query(contentUri(), ITEM_PROJECTION, queryArgs, null);
        }

        return resolver.query(
            contentUri(),
            ITEM_PROJECTION,
            mediaSelection(),
            mediaSelectionArgs(),
            SORT_NEWEST_FIRST + " LIMIT " + limit + " OFFSET " + offset);
    }

    //
    // How many images and videos the library holds. Needed so a page can say whether it was the last.
    //
    private int countItems() {
        ContentResolver resolver = androidContext.getContentResolver();
        Cursor cursor = resolver.query(
            contentUri(),
            new String[] { MediaStore.Files.FileColumns._ID },
            mediaSelection(),
            mediaSelectionArgs(),
            null);

        if (cursor == null) {
            return 0;
        }

        try {
            return cursor.getCount();
        }
        finally {
            cursor.close();
        }
    }

    //
    // host.mediaLibraryList(cursor, pageSize): returns one page of the library as JSON.
    //
    // The offset is carried in the cursor rather than kept here, because the auto-import task
    // persists it between runs and expects to hand back what it was given.
    //
    public String mediaLibraryList(String cursor, int pageSize) {
        int offset = MediaLibrary.offsetFromCursor(cursor);
        int limit = pageSize > 0 ? pageSize : 50;
        int totalCount = countItems();

        List<JSONObject> items = new ArrayList<>();
        int itemsSeen = 0;

        Cursor queryCursor = queryPage(limit, offset);

        if (queryCursor != null) {
            try {
                int idColumn = queryCursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID);
                int nameColumn = queryCursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME);
                int mimeColumn = queryCursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE);
                int sizeColumn = queryCursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE);
                int dateColumn = queryCursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_ADDED);
                int bucketColumn = queryCursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_ID);

                while (queryCursor.moveToNext()) {
                    itemsSeen += 1;

                    String mimeType = queryCursor.getString(mimeColumn);
                    if (!MediaLibrary.isSupportedMimeType(mimeType)) {
                        continue;
                    }

                    JSONObject item = new JSONObject();
                    item.put("id", String.valueOf(queryCursor.getLong(idColumn)));
                    item.put("displayName", queryCursor.getString(nameColumn));
                    item.put("mimeType", mimeType);
                    item.put("size", queryCursor.getLong(sizeColumn));
                    // MediaStore records DATE_ADDED in seconds; every other part of the system works
                    // in milliseconds, and a photo dated 1970 would never look like a new arrival.
                    item.put("createdAtMs", queryCursor.getLong(dateColumn) * 1000L);
                    item.put("albumId", queryCursor.getString(bucketColumn) == null ? "" : queryCursor.getString(bucketColumn));
                    items.add(item);
                }
            }
            catch (JSONException error) {
                throw new RuntimeException("Failed to build the media library page.", error);
            }
            finally {
                queryCursor.close();
            }
        }

        try {
            JSONObject page = new JSONObject();
            page.put("items", new JSONArray(items));

            // The cursor advances by everything the query returned, not by what survived the type
            // filter: skipping the filtered-out rows would make the next page start on top of them
            // and the walk would never finish.
            String nextCursor = MediaLibrary.nextCursor(offset, itemsSeen, totalCount);
            if (nextCursor != null) {
                page.put("nextCursor", nextCursor);
            }
            return page.toString();
        }
        catch (JSONException error) {
            throw new RuntimeException("Failed to build the media library page.", error);
        }
    }

    //
    // host.mediaLibraryAlbums(): returns the albums in the library as JSON.
    //
    public String mediaLibraryAlbums() {
        List<String> bucketIds = new ArrayList<>();
        List<String> bucketNames = new ArrayList<>();

        ContentResolver resolver = androidContext.getContentResolver();
        Cursor cursor = resolver.query(
            contentUri(),
            new String[] {
                MediaStore.Files.FileColumns.BUCKET_ID,
                MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME,
            },
            mediaSelection(),
            mediaSelectionArgs(),
            null);

        if (cursor != null) {
            try {
                int idColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_ID);
                int nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME);
                while (cursor.moveToNext()) {
                    bucketIds.add(cursor.getString(idColumn));
                    bucketNames.add(cursor.getString(nameColumn));
                }
            }
            finally {
                cursor.close();
            }
        }

        List<MediaLibrary.Album> albums = MediaLibrary.groupAlbums(bucketIds, bucketNames);
        JSONArray result = new JSONArray();
        try {
            for (MediaLibrary.Album album : albums) {
                JSONObject entry = new JSONObject();
                entry.put("id", album.id);
                entry.put("name", album.name);
                entry.put("itemCount", album.itemCount);
                result.put(entry);
            }
        }
        catch (JSONException error) {
            throw new RuntimeException("Failed to build the album list.", error);
        }
        return result.toString();
    }

    //
    // host.mediaLibraryExport(itemId): copies one library item into the sandbox and returns the
    // sandbox-relative path the import can read it from.
    //
    // A library item is not a file the import can open, which is why this exists. The copy is
    // deleted again by mediaLibraryRelease once the import has finished with it.
    //
    public String mediaLibraryExport(String itemId) {
        Uri itemUri = uriForItem(itemId);

        String displayName = null;
        String mimeType = null;
        ContentResolver resolver = androidContext.getContentResolver();
        Cursor cursor = resolver.query(
            itemUri,
            new String[] {
                MediaStore.Files.FileColumns.DISPLAY_NAME,
                MediaStore.Files.FileColumns.MIME_TYPE,
            },
            null, null, null);

        if (cursor != null) {
            try {
                if (cursor.moveToFirst()) {
                    displayName = cursor.getString(0);
                    mimeType = cursor.getString(1);
                }
            }
            finally {
                cursor.close();
            }
        }

        String relativePath = MediaLibrary.buildExportPath(itemId, displayName, mimeType);
        File destination = PathSandbox.resolveWithin(storageRoot, relativePath);

        File parent = destination.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new RuntimeException("Failed to create the media export directory: " + parent.getAbsolutePath());
        }

        try {
            InputStream input = resolver.openInputStream(itemUri);
            if (input == null) {
                throw new RuntimeException("The photo library would not open item " + itemId + ".");
            }
            try {
                OutputStream output = new FileOutputStream(destination);
                try {
                    byte[] buffer = new byte[COPY_BUFFER_SIZE];
                    int bytesRead = input.read(buffer);
                    while (bytesRead != -1) {
                        output.write(buffer, 0, bytesRead);
                        bytesRead = input.read(buffer);
                    }
                }
                finally {
                    output.close();
                }
            }
            finally {
                input.close();
            }
        }
        catch (IOException error) {
            throw new RuntimeException("Failed to export item " + itemId + " from the photo library.", error);
        }

        return relativePath;
    }

    //
    // host.mediaLibraryRelease(itemId): deletes the sandbox copy the export made.
    //
    // The library item itself is untouched. Removing a photo from the device is cleanup, which is a
    // separate operation the user confirms.
    //
    public void mediaLibraryRelease(String itemId) {
        // The export path depends on the item's name and type, which are no longer needed: every
        // file in the temp directory whose name starts with this item's id is this item's copy.
        File tempDir = PathSandbox.resolveWithin(storageRoot, MediaLibrary.MEDIA_TEMP_DIR);
        File[] entries = tempDir.listFiles();
        if (entries == null) {
            return;
        }

        String prefix = MediaLibrary.sanitiseId(itemId) + ".";
        for (File entry : entries) {
            if (entry.getName().startsWith(prefix)) {
                entry.delete();
            }
        }
    }

    //
    // host.mediaLibraryDelete(itemIdsJson): asks to delete the named items, as one system
    // confirmation, and returns what happened as JSON.
    //
    // Nothing is reported as deleted unless the platform said so. A caller that believed a photo was
    // gone when it was not would go on to free space that is still in use.
    //
    public String mediaLibraryDelete(String itemIdsJson) {
        List<String> itemIds = parseIds(itemIdsJson);

        DeleteRequester requester = this.deleteRequester;
        if (requester == null) {
            throw new RuntimeException(
                "Nothing can present the delete confirmation, so photos cannot be removed from the library. "
                + "Android requires a system confirmation for media this app does not own.");
        }

        List<String> deletedIds = new ArrayList<>();
        List<String> failedIds = new ArrayList<>();

        for (List<String> batch : MediaLibrary.buildDeleteBatches(itemIds, MediaLibrary.DELETE_BATCH_SIZE)) {
            List<Uri> uris = new ArrayList<>();
            for (String itemId : batch) {
                uris.add(uriForItem(itemId));
            }

            if (requester.requestDelete(uris)) {
                deletedIds.addAll(batch);
            }
            else {
                failedIds.addAll(batch);
            }
        }

        try {
            JSONObject result = new JSONObject();
            result.put("deletedIds", new JSONArray(deletedIds));
            result.put("failedIds", new JSONArray(failedIds));
            return result.toString();
        }
        catch (JSONException error) {
            throw new RuntimeException("Failed to report the outcome of the delete request.", error);
        }
    }

    //
    // The content uri for one library item.
    //
    private static Uri uriForItem(String itemId) {
        try {
            return ContentUris.withAppendedId(contentUri(), Long.parseLong(itemId));
        }
        catch (NumberFormatException error) {
            throw new RuntimeException("\"" + itemId + "\" is not a photo library item id.", error);
        }
    }

    //
    // Reads the ids out of the JSON array the worker sent.
    //
    static List<String> parseIds(String itemIdsJson) {
        List<String> itemIds = new ArrayList<>();
        try {
            JSONArray parsed = new JSONArray(itemIdsJson);
            for (int index = 0; index < parsed.length(); index += 1) {
                itemIds.add(parsed.getString(index));
            }
        }
        catch (JSONException error) {
            throw new RuntimeException("Failed to read the list of items to delete.", error);
        }
        return itemIds;
    }
}
