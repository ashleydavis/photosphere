//
// Typed access to the native connection-type host function.
//
// The background sync loop has to know whether the phone is on Wi-Fi, on a cellular connection, or
// on nothing at all, because the "Only sync over Wi-Fi" setting refuses a sync on cellular. The app's
// own network status lives in the WebView, and there may be no WebView: the loop runs while the app
// is off screen. So the worker asks the platform directly, through ConnectivityManager on Android and
// NWPathMonitor on iOS.
//
// The host is read lazily at call time, mirroring the other shims, so the runtime-wrapped host is
// always the one used.
//

import type { NetworkConnectionType } from "api/src/lib/sync-gate";
import { callHost } from "./host-access";

//
// The native host function the connection type is read through.
//
export interface INetworkStatusHost {
    // Returns the current connection type as one of "wifi", "cellular", "none" or "unknown".
    networkConnectionType: () => string;
}

//
// Returns the installed native host bridge, throwing a clear error when it is missing, which would
// mean the connection type was asked for outside the embedded worker.
//
export function getNetworkStatusHost(): INetworkStatusHost {
    const host = (globalThis as any).host;
    if (!host) {
        throw new Error("Native host bridge (globalThis.host) is not installed; the connection type cannot be read.");
    }

    return host as INetworkStatusHost;
}

//
// Turns what the platform reported into the connection type computeSyncAllowed understands.
//
// Anything unrecognised, including an empty string, becomes "unknown" rather than throwing. A
// platform reporting a connection nobody anticipated (a new transport, a VPN described some other
// way) must not stop syncing altogether, and "unknown" is the value computeSyncAllowed already
// permits for exactly this reason: the desktop cannot report a type either.
//
export function toNetworkConnectionType(reported: string): NetworkConnectionType {
    if (reported === "wifi" || reported === "cellular" || reported === "none" || reported === "unknown") {
        return reported;
    }
    return "unknown";
}

//
// Reads the current connection type from the platform.
//
export function readNetworkConnectionType(): NetworkConnectionType {
    const host = getNetworkStatusHost();
    const reported = callHost(() => host.networkConnectionType());
    return toNetworkConnectionType(reported);
}
