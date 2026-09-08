package au.com.codecapers.photosphere.jsengine;

//
// Which photo library permissions to ask for, and how to read the answer.
//
// Android 13 split the single storage permission into per-type media ones, so which permission to
// ask for depends on the version the app is running on rather than the one it was built against.
// Kept free of Android types so it can be unit-tested on a plain JVM; the plugin code that calls it
// cannot be.
//
public final class MediaPermissions {

    //
    // The per-type media permissions, from Android 13 onwards.
    //
    public static final String READ_MEDIA_IMAGES = "android.permission.READ_MEDIA_IMAGES";

    //
    // The video half of the same pair.
    //
    public static final String READ_MEDIA_VIDEO = "android.permission.READ_MEDIA_VIDEO";

    //
    // The single storage permission, for Android 12 and earlier.
    //
    public static final String READ_EXTERNAL_STORAGE = "android.permission.READ_EXTERNAL_STORAGE";

    //
    // The permission that holds on to the photos a user picked, from Android 14 onwards.
    //
    // Asked for alongside the per-type permissions above rather than instead of them: asking for all
    // three is what puts "Select photos" in front of the user as a real answer that lasts, instead of
    // the platform granting the per-type permissions for one session and taking them back the moment
    // the app is backgrounded.
    //
    public static final String READ_MEDIA_VISUAL_USER_SELECTED = "android.permission.READ_MEDIA_VISUAL_USER_SELECTED";

    //
    // The first Android version with the per-type media permissions.
    //
    public static final int FIRST_PER_TYPE_MEDIA_VERSION = 33;

    //
    // The first Android version where the user can grant access to some photos rather than all.
    //
    public static final int FIRST_PARTIAL_MEDIA_VERSION = 34;

    //
    // Not instantiable; only static helpers.
    //
    private MediaPermissions() {
    }

    //
    // The name the per-type media permissions are requested under.
    //
    // Capacitor asks for permissions by an alias declared on the plugin, and an alias names a fixed
    // list. The list this app needs depends on the Android version it is running on, so there are two
    // aliases and the version decides which one is asked for.
    //
    public static final String PER_TYPE_MEDIA_ALIAS = "mediaLibrary";

    //
    // The name the per-type media permissions and the selected-photos one are requested under, from
    // Android 14 onwards. A third alias rather than a longer list on the one above, because an alias
    // names a fixed list and Android 13 has no selected-photos permission to ask for.
    //
    public static final String PER_TYPE_MEDIA_WITH_SELECTED_ALIAS = "mediaLibrarySelected";

    //
    // The name the single storage permission is requested under, for Android 12 and earlier.
    //
    public static final String LEGACY_STORAGE_ALIAS = "mediaLibraryLegacy";

    //
    // The permissions to ask for on the given Android version.
    //
    public static String[] permissionsForVersion(int sdkInt) {
        if (sdkInt >= FIRST_PARTIAL_MEDIA_VERSION) {
            return new String[] { READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_VISUAL_USER_SELECTED };
        }
        if (sdkInt >= FIRST_PER_TYPE_MEDIA_VERSION) {
            return new String[] { READ_MEDIA_IMAGES, READ_MEDIA_VIDEO };
        }
        return new String[] { READ_EXTERNAL_STORAGE };
    }

    //
    // The alias to ask for the photo library permission under, on the given Android version.
    //
    public static String aliasForVersion(int sdkInt) {
        if (sdkInt >= FIRST_PARTIAL_MEDIA_VERSION) {
            return PER_TYPE_MEDIA_WITH_SELECTED_ALIAS;
        }
        if (sdkInt >= FIRST_PER_TYPE_MEDIA_VERSION) {
            return PER_TYPE_MEDIA_ALIAS;
        }
        return LEGACY_STORAGE_ALIAS;
    }

    //
    // How much of the photo library the answers to the individual permissions add up to.
    //
    // Capacitor reports an alias as granted only when every permission in it is granted, so a user
    // who picked some photos comes back through the alias as a flat refusal, which is wrong in the
    // direction that matters: the app would tell them it has no access while it can see the photos
    // they chose. The permissions are therefore read one at a time and added up here.
    //
    // On Android 12 and earlier there is one storage permission covering both types, so the caller
    // passes its answer as both imagesGranted and videoGranted, and no such version can grant access
    // to part of the library.
    //
    public static MediaAccess mediaAccessFor(boolean imagesGranted, boolean videoGranted, boolean userSelectedGranted) {
        if (imagesGranted && videoGranted) {
            return MediaAccess.FULL;
        }

        if (userSelectedGranted) {
            return MediaAccess.PARTIAL;
        }

        return MediaAccess.NONE;
    }
}
