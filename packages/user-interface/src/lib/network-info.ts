import type { INetworkStatus } from "../context/platform-context";
import type { NetworkConnectionType } from "./sync-gate";

//
// The subset of the (non-standard) Network Information API this module reads.
// Typed locally because it is absent from the TypeScript DOM lib, and guarded at
// runtime because not every browser/WebView exposes it (Firefox, Safari, iOS
// WKWebView do not expose `type`).
//
interface INetworkInformation {
    //
    // Physical connection type, when the browser exposes it (e.g. "wifi",
    // "cellular", "ethernet"). Undefined where unsupported.
    //
    type?: string;

    //
    // Subscribes to connection changes. Present where the API is supported.
    //
    addEventListener?: (eventName: string, listener: () => void) => void;

    //
    // Unsubscribes from connection changes. Present where the API is supported.
    //
    removeEventListener?: (eventName: string, listener: () => void) => void;
}

//
// A navigator augmented with the vendor-prefixed Network Information API handles.
//
interface INavigatorWithConnection {
    //
    // Standard handle.
    //
    connection?: INetworkInformation;

    //
    // Firefox-prefixed handle.
    //
    mozConnection?: INetworkInformation;

    //
    // WebKit-prefixed handle.
    //
    webkitConnection?: INetworkInformation;
}

//
// Maps a Network Information API `type` string to our NetworkConnectionType.
// Wired and Wi-Fi links are both treated as "wifi" (unmetered, so allowed under
// the Wi-Fi-only rule); "cellular" is the only metered type; "none" means
// offline; anything else, including an unsupported/absent value, is "unknown".
//
export function mapConnectionType(connectionType: string | undefined): NetworkConnectionType {
    switch (connectionType) {
        case "wifi":
        case "ethernet":
            return "wifi";
        case "cellular":
            return "cellular";
        case "none":
            return "none";
        default:
            return "unknown";
    }
}

//
// Returns the Network Information API object if this browser/WebView exposes it,
// checking the standard and vendor-prefixed handles. Undefined when unsupported.
//
export function getNetworkInformation(): INetworkInformation | undefined {
    const navigatorWithConnection = navigator as Navigator & INavigatorWithConnection;
    return navigatorWithConnection.connection
        || navigatorWithConnection.mozConnection
        || navigatorWithConnection.webkitConnection;
}

//
// Reads the current network status from standard web APIs (navigator.onLine plus
// the Network Information API). Works in every WebView (web, Electron renderer,
// mobile). connectionType is "unknown" where the browser does not expose `type`.
//
export function readBrowserNetworkStatus(): INetworkStatus {
    const connection = getNetworkInformation();
    return {
        connected: navigator.onLine,
        connectionType: mapConnectionType(connection ? connection.type : undefined),
    };
}

//
// Subscribes to browser network changes (online/offline plus the Network
// Information API "change" event, where supported) and reports the new status.
// Returns an unsubscribe function.
//
export function subscribeBrowserNetworkStatus(callback: (status: INetworkStatus) => void): () => void {
    const handleChange = () => callback(readBrowserNetworkStatus());
    window.addEventListener("online", handleChange);
    window.addEventListener("offline", handleChange);
    const connection = getNetworkInformation();
    if (connection && connection.addEventListener) {
        connection.addEventListener("change", handleChange);
    }
    return () => {
        window.removeEventListener("online", handleChange);
        window.removeEventListener("offline", handleChange);
        if (connection && connection.removeEventListener) {
            connection.removeEventListener("change", handleChange);
        }
    };
}
