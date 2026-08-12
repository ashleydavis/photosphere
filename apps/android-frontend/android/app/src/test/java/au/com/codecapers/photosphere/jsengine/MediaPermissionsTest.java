package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;

import org.junit.Test;

//
// Plain-JVM unit tests for which photo library permissions are asked for, and under which alias.
// Android 13 split the single storage permission into per-type media ones, so asking for the wrong
// one means the request is refused on a version that has never heard of it.
//
public final class MediaPermissionsTest {

    @Test
    public void android13AndLaterAsksForBothMediaTypes() {
        assertArrayEquals(
            new String[] { MediaPermissions.READ_MEDIA_IMAGES, MediaPermissions.READ_MEDIA_VIDEO },
            MediaPermissions.permissionsForVersion(33));
        assertArrayEquals(
            new String[] { MediaPermissions.READ_MEDIA_IMAGES, MediaPermissions.READ_MEDIA_VIDEO },
            MediaPermissions.permissionsForVersion(34));
    }

    @Test
    public void android12AndEarlierAsksForTheStoragePermission() {
        assertArrayEquals(
            new String[] { MediaPermissions.READ_EXTERNAL_STORAGE },
            MediaPermissions.permissionsForVersion(32));
        assertArrayEquals(
            new String[] { MediaPermissions.READ_EXTERNAL_STORAGE },
            MediaPermissions.permissionsForVersion(24));
    }

    @Test
    public void android13AndLaterAsksUnderThePerTypeAlias() {
        assertEquals(MediaPermissions.PER_TYPE_MEDIA_ALIAS, MediaPermissions.aliasForVersion(33));
        assertEquals(MediaPermissions.PER_TYPE_MEDIA_ALIAS, MediaPermissions.aliasForVersion(34));
    }

    @Test
    public void android12AndEarlierAsksUnderTheLegacyAlias() {
        assertEquals(MediaPermissions.LEGACY_STORAGE_ALIAS, MediaPermissions.aliasForVersion(32));
        assertEquals(MediaPermissions.LEGACY_STORAGE_ALIAS, MediaPermissions.aliasForVersion(24));
    }

    @Test
    public void theTwoAliasesAreDifferentNames() {
        // The whole point of having two is that a version picks one of them. One name for both would
        // ask for the per-type permissions on a version that has never heard of them.
        assertEquals(false, MediaPermissions.PER_TYPE_MEDIA_ALIAS.equals(MediaPermissions.LEGACY_STORAGE_ALIAS));
    }
}
