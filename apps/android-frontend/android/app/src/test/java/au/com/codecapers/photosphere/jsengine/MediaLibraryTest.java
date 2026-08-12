package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import org.junit.Test;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;

//
// Plain-JVM unit tests for the device photo library helpers: where a page starts and stops, the
// sandbox path an exported item lands on, which library items automatic import can take in, how
// albums are grouped out of the buckets the items claim, and how deletions are batched so one
// system confirmation covers many photos.
//
public final class MediaLibraryTest {

    @Test
    public void anAbsentCursorStartsAtTheBeginning() {
        assertEquals(0, MediaLibrary.offsetFromCursor(null));
        assertEquals(0, MediaLibrary.offsetFromCursor(""));
    }

    @Test
    public void aCursorSaysWhereThePageStarts() {
        assertEquals(50, MediaLibrary.offsetFromCursor("50"));
    }

    @Test
    public void anUnreadableCursorStartsAtTheBeginningRatherThanFailing() {
        assertEquals(0, MediaLibrary.offsetFromCursor("not-a-number"));
        assertEquals(0, MediaLibrary.offsetFromCursor("-5"));
    }

    @Test
    public void thePageAfterThisOneStartsWhereThisOneEnded() {
        assertEquals("50", MediaLibrary.nextCursor(0, 50, 200));
        assertEquals("100", MediaLibrary.nextCursor(50, 50, 200));
    }

    @Test
    public void theLastPageHasNoCursorAfterIt() {
        assertNull(MediaLibrary.nextCursor(150, 50, 200));
    }

    @Test
    public void aPageThatWentPastTheEndHasNoCursorAfterIt() {
        assertNull(MediaLibrary.nextCursor(180, 50, 200));
    }

    @Test
    public void anEmptyPageEndsTheListing() {
        assertNull(MediaLibrary.nextCursor(0, 0, 200));
    }

    @Test
    public void anEmptyLibraryEndsAtOnce() {
        assertNull(MediaLibrary.nextCursor(0, 0, 0));
    }

    @Test
    public void anExportedItemLandsInTheMediaTempDirectory() {
        assertEquals(".media-tmp/1234.jpg", MediaLibrary.buildExportPath("1234", "holiday.jpg", "image/jpeg"));
    }

    @Test
    public void anExportedItemTakesItsExtensionFromTheMimeTypeWhenTheNameHasNone() {
        assertEquals(".media-tmp/1234.jpeg", MediaLibrary.buildExportPath("1234", "holiday", "image/jpeg"));
    }

    @Test
    public void anExportedItemWithNoNameOrTypeStillGetsAPath() {
        assertEquals(".media-tmp/1234.bin", MediaLibrary.buildExportPath("1234", null, null));
    }

    @Test
    public void theSameItemAlwaysExportsToTheSamePath() {
        String first = MediaLibrary.buildExportPath("1234", "holiday.jpg", "image/jpeg");
        String second = MediaLibrary.buildExportPath("1234", "holiday.jpg", "image/jpeg");
        assertEquals(first, second);
    }

    @Test
    public void anIdWithAPathSeparatorInItCannotEscapeTheTempDirectory() {
        String path = MediaLibrary.buildExportPath("../../etc/passwd", "x.jpg", "image/jpeg");
        assertFalse(path.contains(".."));
        assertTrue(path.startsWith(".media-tmp/"));
    }

    @Test
    public void anEmptyIdStillYieldsAPath() {
        assertEquals(".media-tmp/unknown.jpg", MediaLibrary.buildExportPath("", "x.jpg", "image/jpeg"));
    }

    @Test
    public void imagesAndVideosAreSupported() {
        assertTrue(MediaLibrary.isSupportedMimeType("image/jpeg"));
        assertTrue(MediaLibrary.isSupportedMimeType("image/png"));
        assertTrue(MediaLibrary.isSupportedMimeType("video/mp4"));
        assertTrue(MediaLibrary.isSupportedMimeType("IMAGE/JPEG"));
    }

    @Test
    public void theTypesTheImportCannotProcessAreNotSupported() {
        assertFalse(MediaLibrary.isSupportedMimeType("image/svg+xml"));
        assertFalse(MediaLibrary.isSupportedMimeType("image/vnd.adobe.photoshop"));
        assertFalse(MediaLibrary.isSupportedMimeType("application/pdf"));
        assertFalse(MediaLibrary.isSupportedMimeType("text/plain"));
        assertFalse(MediaLibrary.isSupportedMimeType(null));
    }

    @Test
    public void albumsAreGroupedFromTheBucketsTheItemsClaim() {
        List<String> ids = Arrays.asList("100", "200", "100", "100");
        List<String> names = Arrays.asList("Camera", "Screenshots", "Camera", "Camera");

        List<MediaLibrary.Album> albums = MediaLibrary.groupAlbums(ids, names);

        assertEquals(2, albums.size());
        assertEquals("100", albums.get(0).id);
        assertEquals("Camera", albums.get(0).name);
        assertEquals(3, albums.get(0).itemCount);
        assertEquals("200", albums.get(1).id);
        assertEquals("Screenshots", albums.get(1).name);
        assertEquals(1, albums.get(1).itemCount);
    }

    @Test
    public void anItemThatClaimsNoAlbumIsLeftOut() {
        List<String> ids = Arrays.asList("100", null, "");
        List<String> names = Arrays.asList("Camera", "Nowhere", "Nowhere");

        List<MediaLibrary.Album> albums = MediaLibrary.groupAlbums(ids, names);

        assertEquals(1, albums.size());
        assertEquals("100", albums.get(0).id);
    }

    @Test
    public void anAlbumWithNoNameStillAppears() {
        List<MediaLibrary.Album> albums = MediaLibrary.groupAlbums(
            Collections.singletonList("100"), Collections.singletonList(null));

        assertEquals(1, albums.size());
        assertEquals("", albums.get(0).name);
    }

    @Test
    public void anEmptyLibraryHasNoAlbums() {
        assertEquals(0, MediaLibrary.groupAlbums(new ArrayList<>(), new ArrayList<>()).size());
    }

    @Test
    public void albumIdsAndNamesThatDoNotLineUpAreRefused() {
        try {
            MediaLibrary.groupAlbums(Arrays.asList("100", "200"), Collections.singletonList("Camera"));
            fail("Expected mismatched album ids and names to be refused");
        }
        catch (IllegalArgumentException expected) {
            assertTrue(expected.getMessage().contains("line up"));
        }
    }

    @Test
    public void deletionsAreSplitIntoBatches() {
        List<String> ids = Arrays.asList("1", "2", "3", "4", "5");

        List<List<String>> batches = MediaLibrary.buildDeleteBatches(ids, 2);

        assertEquals(3, batches.size());
        assertEquals(Arrays.asList("1", "2"), batches.get(0));
        assertEquals(Arrays.asList("3", "4"), batches.get(1));
        assertEquals(Collections.singletonList("5"), batches.get(2));
    }

    @Test
    public void everythingFitsInOneBatchWhenItCan() {
        List<List<String>> batches = MediaLibrary.buildDeleteBatches(Arrays.asList("1", "2"), 50);

        assertEquals(1, batches.size());
        assertEquals(2, batches.get(0).size());
    }

    @Test
    public void nothingToDeleteIsNoBatches() {
        assertEquals(0, MediaLibrary.buildDeleteBatches(new ArrayList<>(), 50).size());
    }

    @Test
    public void aBatchSizeBelowOneIsRefusedRatherThanLoopingForever() {
        try {
            MediaLibrary.buildDeleteBatches(Collections.singletonList("1"), 0);
            fail("Expected a batch size below one to be refused");
        }
        catch (IllegalArgumentException expected) {
            assertTrue(expected.getMessage().contains("at least 1"));
        }
    }

    @Test
    public void theDefaultBatchSizeIsWhatTheDeleteRequestUses() {
        List<String> ids = new ArrayList<>();
        for (int index = 0; index < MediaLibrary.DELETE_BATCH_SIZE + 1; index += 1) {
            ids.add(String.valueOf(index));
        }

        List<List<String>> batches = MediaLibrary.buildDeleteBatches(ids, MediaLibrary.DELETE_BATCH_SIZE);

        assertEquals(2, batches.size());
        assertEquals(MediaLibrary.DELETE_BATCH_SIZE, batches.get(0).size());
        assertEquals(1, batches.get(1).size());
    }
}
