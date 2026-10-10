package au.com.codecapers.photosphere.ziggy;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;

import org.junit.Test;

// Plain-JVM tests for which photo library permissions are asked for, and how much of the library the answers add up to. Android 13
// split the single storage permission into per-type media ones and Android 14 added one for the photos a user picked, so asking for
// the wrong one means the request is refused on a version that has never heard of it.
public final class MediaPermissionsTest {
    @Test
    public void android13AsksForBothMediaTypes() {
        assertArrayEquals(
            new String[] { MediaPermissions.READ_MEDIA_IMAGES, MediaPermissions.READ_MEDIA_VIDEO },
            MediaPermissions.permissionsForVersion(33));
    }

    @Test
    public void android14AndLaterAlsoAsksForTheSelectedPhotosPermission() {
        String[] expected = new String[] {
            MediaPermissions.READ_MEDIA_IMAGES,
            MediaPermissions.READ_MEDIA_VIDEO,
            MediaPermissions.READ_MEDIA_VISUAL_USER_SELECTED,
        };
        assertArrayEquals(expected, MediaPermissions.permissionsForVersion(34));
        assertArrayEquals(expected, MediaPermissions.permissionsForVersion(36));
    }

    @Test
    public void android12AndEarlierAsksForTheStoragePermission() {
        assertArrayEquals(new String[] { MediaPermissions.READ_EXTERNAL_STORAGE }, MediaPermissions.permissionsForVersion(32));
        assertArrayEquals(new String[] { MediaPermissions.READ_EXTERNAL_STORAGE }, MediaPermissions.permissionsForVersion(24));
    }

    @Test
    public void bothTypesGrantedIsTheWholeLibrary() {
        assertEquals(MediaAccess.FULL, MediaPermissions.mediaAccessFor(true, true, false));
        assertEquals(MediaAccess.FULL, MediaPermissions.mediaAccessFor(true, true, true));
    }

    @Test
    public void onlyTheSelectedPhotosPermissionIsPartialAccessNotARefusal() {
        assertEquals(MediaAccess.PARTIAL, MediaPermissions.mediaAccessFor(false, false, true));
    }

    @Test
    public void oneTypeAloneIsNotTheWholeLibrary() {
        assertEquals(MediaAccess.NONE, MediaPermissions.mediaAccessFor(true, false, false));
        assertEquals(MediaAccess.NONE, MediaPermissions.mediaAccessFor(false, true, false));
    }

    @Test
    public void nothingGrantedIsNoAccess() {
        assertEquals(MediaAccess.NONE, MediaPermissions.mediaAccessFor(false, false, false));
    }
}
