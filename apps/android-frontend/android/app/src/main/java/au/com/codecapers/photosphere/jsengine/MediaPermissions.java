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
    // The first Android version with the per-type media permissions.
    //
    public static final int FIRST_PER_TYPE_MEDIA_VERSION = 33;

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
    // The name the single storage permission is requested under, for Android 12 and earlier.
    //
    public static final String LEGACY_STORAGE_ALIAS = "mediaLibraryLegacy";

    //
    // The permissions to ask for on the given Android version.
    //
    public static String[] permissionsForVersion(int sdkInt) {
        if (sdkInt >= FIRST_PER_TYPE_MEDIA_VERSION) {
            return new String[] { READ_MEDIA_IMAGES, READ_MEDIA_VIDEO };
        }
        return new String[] { READ_EXTERNAL_STORAGE };
    }

    //
    // The alias to ask for the photo library permission under, on the given Android version.
    //
    public static String aliasForVersion(int sdkInt) {
        if (sdkInt >= FIRST_PER_TYPE_MEDIA_VERSION) {
            return PER_TYPE_MEDIA_ALIAS;
        }
        return LEGACY_STORAGE_ALIAS;
    }
}
