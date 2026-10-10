package au.com.codecapers.photosphere.ziggy;

import android.content.ContentResolver;
import android.content.ContentUris;
import android.content.Context;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.MediaStore;
import dev.ziggy.shell.HostRequestException;
import dev.ziggy.shell.HostRequestHandler;
import dev.ziggy.shell.ZiggyShell;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

// Answers the core's requests for the device photo library: mediaLibraryList, mediaLibraryAlbums, mediaLibraryOpen, mediaLibraryClose
// and mediaLibraryDelete. Automatic import reads the library through these. The library is read through MediaStore. The pure decisions
// (where a page starts and stops, the cache path an exported item lands on, which types are supported, grouping albums, batching
// deletions) are in MediaLibrary. The core calls from a worker thread and waits, so a request may block on the system's delete
// confirmation.
public final class MediaLibraryHostRequests implements HostRequestHandler {
    // Buffer size used when copying a library item into the cache directory.
    private static final int COPY_BUFFER_SIZE = 64 * 1024;

    // The page size used when the request gives none.
    private static final int DEFAULT_PAGE_SIZE = 50;

    // The columns every listed item needs.
    private static final String[] ITEM_PROJECTION = new String[] {
        MediaStore.Files.FileColumns._ID,
        MediaStore.Files.FileColumns.DISPLAY_NAME,
        MediaStore.Files.FileColumns.MIME_TYPE,
        MediaStore.Files.FileColumns.SIZE,
        MediaStore.Files.FileColumns.DATE_ADDED,
        MediaStore.Files.FileColumns.BUCKET_ID,
        MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME,
    };

    // Newest first, with the id breaking ties. The id is not decoration: pages are asked for with a limit and an offset, and date
    // added is not unique (a burst of photos, or a batch copied onto the device, all carry the same second). Rows that compare equal
    // have no defined order between one query and the next, so a page could return a row an earlier page had already returned and
    // leave another out altogether. The id makes the order total, so every row is returned by exactly one page.
    private static final String SORT_NEWEST_FIRST = MediaStore.Files.FileColumns.DATE_ADDED + " DESC, " + MediaStore.Files.FileColumns._ID + " DESC";

    private final Context context;
    private final ZiggyShell shell;
    private final File cacheRoot;

    public MediaLibraryHostRequests(Context context, ZiggyShell shell) {
        this.context = context;
        this.shell = shell;
        this.cacheRoot = context.getCacheDir();
    }

    @Override
    public String handle(String method, String requestJson) throws HostRequestException {
        try {
            switch (method) {
                case "mediaLibraryList": {
                    JSONObject request = new JSONObject(requestJson);
                    requireAccess(method);
                    return list(request.getString("cursor"), request.getInt("pageSize"));
                }
                case "mediaLibraryAlbums":
                    requireAccess(method);
                    return albums();
                case "mediaLibraryOpen":
                    requireAccess(method);
                    return JSONObject.quote(open(new JSONObject(requestJson).getString("itemId")));
                case "mediaLibraryClose":
                    close(new JSONObject(requestJson).getString("itemId"));
                    return "null";
                case "mediaLibraryDelete":
                    requireAccess(method);
                    return delete(readIds(new JSONObject(requestJson).getJSONArray("itemIds")));
                default:
                    throw new HostRequestException("MediaLibraryHostRequests does not answer \"" + method + "\".");
            }
        } catch (JSONException error) {
            throw new HostRequestException("The request " + method + " was not understood: " + error.getMessage(), error);
        } catch (SecurityException error) {
            throw new HostRequestException("The photo library refused " + method + ": " + error.getMessage(), error);
        }
    }

    // A request fails, naming the permission, when the app can see none of the library, because an empty answer would be taken for a
    // library with no photos in it and nothing would be backed up.
    private void requireAccess(String method) throws HostRequestException {
        if (MediaAccessChecker.current(context) == MediaAccess.NONE) {
            throw new HostRequestException(method + " needs permission to read the photo library, and the app does not have it. Allow access to photos and videos for Photosphere in the phone's settings.");
        }
    }

    // The collection holding both images and videos.
    private static Uri contentUri() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            return MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL);
        }
        return MediaStore.Files.getContentUri("external");
    }

    // Selects the images and videos, and nothing else in the files collection.
    private static String mediaSelection() {
        return MediaStore.Files.FileColumns.MEDIA_TYPE + " IN (?, ?)";
    }

    // The media types the selection above binds.
    private static String[] mediaSelectionArgs() {
        return new String[] {
            String.valueOf(MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE),
            String.valueOf(MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO),
        };
    }

    // Reads one page of the library, newest first. From Android 11 the limit and offset go in a query bundle, and appending
    // "LIMIT n OFFSET m" to the sort order is rejected outright. Earlier versions have no bundle arguments and only understand the
    // appended form. Both are here because minSdk is below 30.
    private Cursor queryPage(int limit, int offset) {
        ContentResolver resolver = context.getContentResolver();

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Bundle queryArgs = new Bundle();
            queryArgs.putString(ContentResolver.QUERY_ARG_SQL_SELECTION, mediaSelection());
            queryArgs.putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, mediaSelectionArgs());
            queryArgs.putStringArray(ContentResolver.QUERY_ARG_SORT_COLUMNS,
                new String[] { MediaStore.Files.FileColumns.DATE_ADDED, MediaStore.Files.FileColumns._ID });
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

    // How many images and videos the library holds. Needed so a page can say whether it was the last.
    private int countItems() throws HostRequestException {
        Cursor cursor = context.getContentResolver().query(
            contentUri(),
            new String[] { MediaStore.Files.FileColumns._ID },
            mediaSelection(),
            mediaSelectionArgs(),
            null);
        if (cursor == null) {
            throw new HostRequestException("The photo library could not be queried.");
        }
        try {
            return cursor.getCount();
        } finally {
            cursor.close();
        }
    }

    // One page of the library. The offset is carried in the cursor rather than kept here, because the caller persists it between
    // runs and hands back what it was given.
    private String list(String cursor, int pageSize) throws HostRequestException, JSONException {
        int offset = MediaLibrary.offsetFromCursor(cursor);
        int limit = pageSize > 0 ? pageSize : DEFAULT_PAGE_SIZE;
        int totalCount = countItems();

        JSONArray items = new JSONArray();
        int itemsSeen = 0;

        Cursor queryCursor = queryPage(limit, offset);
        if (queryCursor == null) {
            throw new HostRequestException("The photo library could not be queried.");
        }
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
                // MediaStore records DATE_ADDED in seconds; everything else works in milliseconds, and a photo dated 1970 would
                // never look like a new arrival.
                item.put("createdAtMs", queryCursor.getLong(dateColumn) * 1000L);
                String bucketId = queryCursor.getString(bucketColumn);
                item.put("albumId", bucketId == null ? "" : bucketId);
                items.put(item);
            }
        } finally {
            queryCursor.close();
        }

        JSONObject page = new JSONObject();
        page.put("items", items);
        // The cursor advances by everything the query returned, not by what survived the type filter: skipping the filtered-out rows
        // would make the next page start on top of them and the walk would never finish.
        String nextCursor = MediaLibrary.nextCursor(offset, itemsSeen, totalCount);
        if (nextCursor != null) {
            page.put("nextCursor", nextCursor);
        }
        return page.toString();
    }

    // The albums in the library.
    private String albums() throws HostRequestException, JSONException {
        List<String> bucketIds = new ArrayList<String>();
        List<String> bucketNames = new ArrayList<String>();

        Cursor cursor = context.getContentResolver().query(
            contentUri(),
            new String[] {
                MediaStore.Files.FileColumns.BUCKET_ID,
                MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME,
            },
            mediaSelection(),
            mediaSelectionArgs(),
            null);
        if (cursor == null) {
            throw new HostRequestException("The photo library could not be queried.");
        }
        try {
            int idColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_ID);
            int nameColumn = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.BUCKET_DISPLAY_NAME);
            while (cursor.moveToNext()) {
                bucketIds.add(cursor.getString(idColumn));
                bucketNames.add(cursor.getString(nameColumn));
            }
        } finally {
            cursor.close();
        }

        JSONArray result = new JSONArray();
        for (MediaLibrary.Album album : MediaLibrary.groupAlbums(bucketIds, bucketNames)) {
            result.put(new JSONObject()
                .put("id", album.id)
                .put("name", album.name)
                .put("itemCount", album.itemCount));
        }
        return result.toString();
    }

    // Copies one library item into the app's cache directory and returns the absolute path the import can read it from. A library
    // item is not a file the import can open, which is why this exists. The copy is deleted again by close.
    private String open(String itemId) throws HostRequestException {
        Uri itemUri = uriForItem(itemId);
        ContentResolver resolver = context.getContentResolver();

        String displayName = null;
        String mimeType = null;
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
            } finally {
                cursor.close();
            }
        }

        File destination = new File(cacheRoot, MediaLibrary.buildExportPath(itemId, displayName, mimeType));
        File parent = destination.getParentFile();
        if (parent != null && !parent.exists() && !parent.mkdirs()) {
            throw new HostRequestException("Failed to create the media export directory: " + parent.getAbsolutePath());
        }

        try {
            InputStream input = resolver.openInputStream(itemUri);
            if (input == null) {
                throw new HostRequestException("The photo library would not open item " + itemId + ".");
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
                } finally {
                    output.close();
                }
            } finally {
                input.close();
            }
        } catch (IOException error) {
            destination.delete();
            throw new HostRequestException("Failed to copy item " + itemId + " out of the photo library: " + error.getMessage(), error);
        }

        return destination.getAbsolutePath();
    }

    // Deletes the cache copy open made. The library item itself is untouched: removing a photo from the device is cleanup, which is
    // a separate operation the user confirms. The copy's name depends on the item's name and type, which are no longer known, so
    // every file in the temp directory whose name starts with this item's id is this item's copy.
    private void close(String itemId) {
        File[] entries = new File(cacheRoot, MediaLibrary.MEDIA_TEMP_DIR).listFiles();
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

    // Asks to delete the items, one system confirmation per batch, and says what happened. Nothing is reported as deleted unless the
    // platform said so: a caller that believed a photo was gone when it was not would go on to free space that is still in use.
    private String delete(List<String> itemIds) throws HostRequestException, JSONException {
        JSONArray deletedIds = new JSONArray();
        JSONArray failedIds = new JSONArray();

        for (List<String> batch : MediaLibrary.buildDeleteBatches(itemIds, MediaLibrary.DELETE_BATCH_SIZE)) {
            List<Uri> uris = new ArrayList<Uri>();
            for (String itemId : batch) {
                uris.add(uriForItem(itemId));
            }

            JSONArray target = requestDelete(uris) ? deletedIds : failedIds;
            for (String itemId : batch) {
                target.put(itemId);
            }
        }

        return new JSONObject()
            .put("deletedIds", deletedIds)
            .put("failedIds", failedIds)
            .toString();
    }

    // Presents the system confirmation for deleting the items, and waits until the user answers. Android 11 and later require it for
    // media the app does not own. Before that, an app holding the storage permission deletes directly.
    private boolean requestDelete(List<Uri> uris) throws HostRequestException {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            int deleted = 0;
            for (Uri uri : uris) {
                deleted += context.getContentResolver().delete(uri, null, null);
            }
            return deleted == uris.size();
        }

        try {
            return shell.startIntentSenderAndWait(
                MediaStore.createDeleteRequest(context.getContentResolver(), uris).getIntentSender());
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new HostRequestException("The delete confirmation was interrupted.", interrupted);
        }
    }

    // The content uri for one library item.
    private static Uri uriForItem(String itemId) throws HostRequestException {
        try {
            return ContentUris.withAppendedId(contentUri(), Long.parseLong(itemId));
        } catch (NumberFormatException error) {
            throw new HostRequestException("\"" + itemId + "\" is not a photo library item id.", error);
        }
    }

    // Reads the ids out of the JSON array the core sent.
    private static List<String> readIds(JSONArray parsed) throws JSONException {
        List<String> itemIds = new ArrayList<String>();
        for (int index = 0; index < parsed.length(); index += 1) {
            itemIds.add(parsed.getString(index));
        }
        return itemIds;
    }
}
