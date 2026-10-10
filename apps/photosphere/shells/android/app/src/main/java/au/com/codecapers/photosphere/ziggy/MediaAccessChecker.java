package au.com.codecapers.photosphere.ziggy;

import android.content.Context;
import android.content.pm.PackageManager;
import android.os.Build;

// Reads how much of the device photo library the app can see right now.
public final class MediaAccessChecker {
    private MediaAccessChecker() {
    }

    // Read one permission at a time, because a user who picked some photos holds the selected-photos permission and neither per-type
    // one.
    public static MediaAccess current(Context context) {
        int sdkInt = Build.VERSION.SDK_INT;
        if (sdkInt >= MediaPermissions.FIRST_PER_TYPE_MEDIA_VERSION) {
            return MediaPermissions.mediaAccessFor(
                isGranted(context, MediaPermissions.READ_MEDIA_IMAGES),
                isGranted(context, MediaPermissions.READ_MEDIA_VIDEO),
                sdkInt >= MediaPermissions.FIRST_PARTIAL_MEDIA_VERSION && isGranted(context, MediaPermissions.READ_MEDIA_VISUAL_USER_SELECTED));
        }
        // One permission covers both types before Android 13, and no version that old can grant access to part of the library.
        boolean storageGranted = isGranted(context, MediaPermissions.READ_EXTERNAL_STORAGE);
        return MediaPermissions.mediaAccessFor(storageGranted, storageGranted, false);
    }

    private static boolean isGranted(Context context, String permission) {
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED;
    }
}
