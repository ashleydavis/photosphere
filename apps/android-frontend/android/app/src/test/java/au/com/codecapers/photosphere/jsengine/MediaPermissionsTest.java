package au.com.codecapers.photosphere.jsengine;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;

import org.junit.Test;

//
// Plain-JVM unit tests for which photo library permissions are asked for, under which alias, and how
// much of the library the answers add up to. Android 13 split the single storage permission into
// per-type media ones and Android 14 added a permission for the photos a user picked, so asking for
// the wrong one means the request is refused on a version that has never heard of it.
//
public final class MediaPermissionsTest {

    @Test
    public void android13AsksForBothMediaTypes() {
        assertArrayEquals(
            new String[] { MediaPermissions.READ_MEDIA_IMAGES, MediaPermissions.READ_MEDIA_VIDEO },
            MediaPermissions.permissionsForVersion(33));
    }

    @Test
    public void android14AndLaterAlsoAsksForTheSelectedPhotosPermission() {
        assertArrayEquals(
            new String[] {
                MediaPermissions.READ_MEDIA_IMAGES,
                MediaPermissions.READ_MEDIA_VIDEO,
                MediaPermissions.READ_MEDIA_VISUAL_USER_SELECTED,
            },
            MediaPermissions.permissionsForVersion(34));
        assertArrayEquals(
            new String[] {
                MediaPermissions.READ_MEDIA_IMAGES,
                MediaPermissions.READ_MEDIA_VIDEO,
                MediaPermissions.READ_MEDIA_VISUAL_USER_SELECTED,
            },
            MediaPermissions.permissionsForVersion(36));
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
    public void android13AsksUnderThePerTypeAlias() {
        assertEquals(MediaPermissions.PER_TYPE_MEDIA_ALIAS, MediaPermissions.aliasForVersion(33));
    }

    @Test
    public void android14AndLaterAsksUnderTheSelectedPhotosAlias() {
        assertEquals(MediaPermissions.PER_TYPE_MEDIA_WITH_SELECTED_ALIAS, MediaPermissions.aliasForVersion(34));
        assertEquals(MediaPermissions.PER_TYPE_MEDIA_WITH_SELECTED_ALIAS, MediaPermissions.aliasForVersion(36));
    }

    @Test
    public void android12AndEarlierAsksUnderTheLegacyAlias() {
        assertEquals(MediaPermissions.LEGACY_STORAGE_ALIAS, MediaPermissions.aliasForVersion(32));
        assertEquals(MediaPermissions.LEGACY_STORAGE_ALIAS, MediaPermissions.aliasForVersion(24));
    }

    @Test
    public void theAliasesAreAllDifferentNames() {
        // The whole point of having one per version range is that a version picks one of them. One
        // name shared would ask for permissions on a version that has never heard of them.
        assertEquals(false, MediaPermissions.PER_TYPE_MEDIA_ALIAS.equals(MediaPermissions.LEGACY_STORAGE_ALIAS));
        assertEquals(false, MediaPermissions.PER_TYPE_MEDIA_ALIAS.equals(MediaPermissions.PER_TYPE_MEDIA_WITH_SELECTED_ALIAS));
        assertEquals(false, MediaPermissions.LEGACY_STORAGE_ALIAS.equals(MediaPermissions.PER_TYPE_MEDIA_WITH_SELECTED_ALIAS));
    }

    @Test
    public void bothMediaTypesGrantedIsFullAccess() {
        assertEquals(MediaAccess.FULL, MediaPermissions.mediaAccessFor(true, true, false));
    }

    @Test
    public void bothMediaTypesGrantedIsStillFullAccessAlongsideTheSelectedPhotosPermission() {
        // "Allow all" on Android 14 grants the selected-photos permission as well. That is still the
        // whole library, and treating it as a partial grant would switch automatic import off for a
        // user who allowed everything.
        assertEquals(MediaAccess.FULL, MediaPermissions.mediaAccessFor(true, true, true));
    }

    @Test
    public void onlyTheSelectedPhotosPermissionIsPartialAccess() {
        assertEquals(MediaAccess.PARTIAL, MediaPermissions.mediaAccessFor(false, false, true));
    }

    @Test
    public void oneMediaTypeAlongsideTheSelectedPhotosPermissionIsPartialAccess() {
        assertEquals(MediaAccess.PARTIAL, MediaPermissions.mediaAccessFor(true, false, true));
        assertEquals(MediaAccess.PARTIAL, MediaPermissions.mediaAccessFor(false, true, true));
    }

    @Test
    public void nothingGrantedIsNoAccess() {
        assertEquals(MediaAccess.NONE, MediaPermissions.mediaAccessFor(false, false, false));
    }

    @Test
    public void oneMediaTypeOnItsOwnIsNoAccess() {
        // Half the library is not the library, and there is no way for a user to arrive here on
        // purpose: the two per-type permissions are asked for and answered together.
        assertEquals(MediaAccess.NONE, MediaPermissions.mediaAccessFor(true, false, false));
        assertEquals(MediaAccess.NONE, MediaPermissions.mediaAccessFor(false, true, false));
    }
}
