package au.com.codecapers.photosphere.jsengine;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkInfo;
import android.os.Build;

//
// Reports what kind of connection this phone currently has, for the background sync.
//
// The "Only sync over Wi-Fi" setting refuses a sync on a cellular connection, and the loop that
// decides that runs while the app is off screen, so it cannot ask the WebView what the network is
// doing: there may be no WebView. It asks here instead, through the platform.
//
// The names returned are the four computeSyncAllowed understands. What to do about each of them is
// decided there, in TypeScript, and not here: this class answers one question and takes no view on
// what the answer means.
//
public final class NetworkHost {

    //
    // The connection is Wi-Fi, or something else that is not metered by a mobile carrier.
    //
    public static final String CONNECTION_WIFI = "wifi";

    //
    // The connection is a mobile carrier's, which is the one the Wi-Fi-only setting refuses.
    //
    public static final String CONNECTION_CELLULAR = "cellular";

    //
    // There is no connection at all.
    //
    public static final String CONNECTION_NONE = "none";

    //
    // There is a connection, but not one that can be identified as either of the two above.
    //
    // computeSyncAllowed permits this, deliberately: an unrecognised transport must not stop syncing
    // altogether, which is the same reason the desktop reports it.
    //
    public static final String CONNECTION_UNKNOWN = "unknown";

    //
    // The Android context the connectivity service is reached through.
    //
    private final Context context;

    //
    // Constructs the reporter over the given Android context.
    //
    public NetworkHost(Context context) {
        this.context = context;
    }

    //
    // Returns the current connection type as one of the four names above.
    //
    // A phone with no connectivity service at all reports "none" rather than "unknown", because the
    // one thing that is certain in that case is that nothing can be pushed anywhere.
    //
    public String connectionType() {
        ConnectivityManager connectivityManager =
            (ConnectivityManager)context.getSystemService(Context.CONNECTIVITY_SERVICE);
        if (connectivityManager == null) {
            return CONNECTION_NONE;
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Network activeNetwork = connectivityManager.getActiveNetwork();
            if (activeNetwork == null) {
                return CONNECTION_NONE;
            }

            NetworkCapabilities capabilities = connectivityManager.getNetworkCapabilities(activeNetwork);
            if (capabilities == null) {
                return CONNECTION_NONE;
            }

            return classifyCapabilities(capabilities);
        }

        return legacyConnectionType(connectivityManager);
    }

    //
    // Names the transport a set of capabilities describes.
    //
    // Cellular is checked first. A phone sharing its mobile connection over a VPN, or bridging one
    // transport over another, can report more than one, and the setting exists to keep a backup off
    // the carrier's network: answering "wifi" for a connection that is also cellular is the one
    // mistake here that costs the user money.
    //
    private String classifyCapabilities(NetworkCapabilities capabilities) {
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            return CONNECTION_CELLULAR;
        }

        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)
            || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
            // Ethernet counts as Wi-Fi here rather than as its own name, because the only question
            // anything asks of this is whether the connection is the carrier's. An emulator on a
            // host's network reports ethernet, and calling that "unknown" would be true and useless.
            return CONNECTION_WIFI;
        }

        return CONNECTION_UNKNOWN;
    }

    //
    // The same answer on versions of Android with no NetworkCapabilities to ask.
    //
    // The app supports back to a version where getActiveNetworkInfo is the only way to ask, and it is
    // deprecated rather than absent, so this path is reached only there.
    //
    @SuppressWarnings("deprecation")
    private String legacyConnectionType(ConnectivityManager connectivityManager) {
        NetworkInfo activeNetworkInfo = connectivityManager.getActiveNetworkInfo();
        if (activeNetworkInfo == null || !activeNetworkInfo.isConnected()) {
            return CONNECTION_NONE;
        }

        int type = activeNetworkInfo.getType();
        if (type == ConnectivityManager.TYPE_MOBILE || type == ConnectivityManager.TYPE_MOBILE_DUN) {
            return CONNECTION_CELLULAR;
        }

        if (type == ConnectivityManager.TYPE_WIFI || type == ConnectivityManager.TYPE_ETHERNET) {
            return CONNECTION_WIFI;
        }

        return CONNECTION_UNKNOWN;
    }
}
