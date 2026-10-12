package au.com.codecapers.photosphere.ziggy;

// Which photo library permissions to ask for, and how to read the answer.
//
// Android 13 split the single storage permission into per-type media ones, so which permission to ask for depends on the version the
// app is running on rather than the one it was built against. Kept free of Android types so it can be unit-tested on a plain JVM.
public final class MediaPermissions {
    // The per-type media permission for images, from Android 13 onwards.
    public static final String READ_MEDIA_IMAGES = "android.permission.READ_MEDIA_IMAGES";

    // The video half of the same pair.
    public static final String READ_MEDIA_VIDEO = "android.permission.READ_MEDIA_VIDEO";

    // The single storage permission, for Android 12 and earlier.
    public static final String READ_EXTERNAL_STORAGE = "android.permission.READ_EXTERNAL_STORAGE";

    // The permission that holds on to the photos a user picked, from Android 14 onwards.
    //
    // Asked for alongside the per-type permissions rather than instead of them: asking for all three is what puts "Select photos" in
    // front of the user as a real answer that lasts, instead of the platform granting the per-type permissions for one session and
    // taking them back the moment the app is backgrounded.
    public static final String READ_MEDIA_VISUAL_USER_SELECTED = "android.permission.READ_MEDIA_VISUAL_USER_SELECTED";

    // The permission that lets the app read the location stored in a photo's EXIF. Without it Android strips the GPS tags from the
    // copy of a library photo the app is given, so the photo imports with no location.
    public static final String ACCESS_MEDIA_LOCATION = "android.permission.ACCESS_MEDIA_LOCATION";

    // The first Android version with the media location permission.
    public static final int FIRST_MEDIA_LOCATION_VERSION = 29;

    // The first Android version with the per-type media permissions.
    public static final int FIRST_PER_TYPE_MEDIA_VERSION = 33;

    // The first Android version where the user can grant access to some photos rather than all.
    public static final int FIRST_PARTIAL_MEDIA_VERSION = 34;

    private MediaPermissions() {
    }

    // The permissions to ask for on the given Android version.
    public static String[] permissionsForVersion(int sdkInt) {
        if (sdkInt >= FIRST_PARTIAL_MEDIA_VERSION) {
            return new String[] { READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, READ_MEDIA_VISUAL_USER_SELECTED, ACCESS_MEDIA_LOCATION };
        }
        if (sdkInt >= FIRST_PER_TYPE_MEDIA_VERSION) {
            return new String[] { READ_MEDIA_IMAGES, READ_MEDIA_VIDEO, ACCESS_MEDIA_LOCATION };
        }
        if (sdkInt >= FIRST_MEDIA_LOCATION_VERSION) {
            return new String[] { READ_EXTERNAL_STORAGE, ACCESS_MEDIA_LOCATION };
        }
        return new String[] { READ_EXTERNAL_STORAGE };
    }

    // How much of the photo library the answers to the individual permissions add up to.
    //
    // The permissions are read one at a time and added up here, because a user who picked some photos holds the selected-photos
    // permission and neither per-type one, and counting only whether every permission is granted would call that a flat refusal while
    // the app can see the photos they chose.
    //
    // On Android 12 and earlier there is one storage permission covering both types, so the caller passes its answer as both
    // imagesGranted and videoGranted, and no such version can grant access to part of the library.
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
