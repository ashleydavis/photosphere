package au.com.codecapers.photosphere.ziggy;

import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkInfo;
import android.os.Build;

// Reports what kind of connection this phone currently has, for the background sync.
//
// The "Only sync over Wi-Fi" setting refuses a sync on a cellular connection, and the loop that decides that runs while the app is off
// screen, so it asks the platform here. The names returned are the four the sync decision understands. What to do about each of them is
// decided there, and not here: this class answers one question and takes no view on what the answer means.
public final class NetworkHost {
    // The connection is Wi-Fi, or something else that is not metered by a mobile carrier.
    public static final String CONNECTION_WIFI = "wifi";

    // The connection is a mobile carrier's, which is the one the Wi-Fi-only setting refuses.
    public static final String CONNECTION_CELLULAR = "cellular";

    // There is no connection at all.
    public static final String CONNECTION_NONE = "none";

    // There is a connection, but not one that can be identified as either of the two above. Syncing is allowed on it, so an
    // unrecognised transport does not stop syncing altogether.
    public static final String CONNECTION_UNKNOWN = "unknown";

    private final Context context;

    public NetworkHost(Context context) {
        this.context = context;
    }

    // Returns the current connection type as one of the four names above. A phone with no connectivity service at all reports "none"
    // rather than "unknown", because the one thing that is certain then is that nothing can be pushed anywhere.
    public String connectionType() {
        ConnectivityManager connectivityManager = (ConnectivityManager) context.getSystemService(Context.CONNECTIVITY_SERVICE);
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

    // Names the transport a set of capabilities describes. Cellular is checked first: a phone sharing its mobile connection over a VPN
    // can report more than one transport, and the setting exists to keep a backup off the carrier's network, so answering "wifi" for a
    // connection that is also cellular is the one mistake here that costs the user money. Ethernet counts as Wi-Fi, because the only
    // question asked is whether the connection is the carrier's.
    private String classifyCapabilities(NetworkCapabilities capabilities) {
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR)) {
            return CONNECTION_CELLULAR;
        }
        if (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) {
            return CONNECTION_WIFI;
        }
        return CONNECTION_UNKNOWN;
    }

    // The same answer on versions of Android with no NetworkCapabilities to ask.
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
