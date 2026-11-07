//
// The kind of network connection currently in use. "unknown" is reported by
// platforms that cannot distinguish wired/wifi/cellular (desktop and web
// browsers); it is treated as allowed so those platforms sync whenever online.
//
export type NetworkConnectionType = "wifi" | "cellular" | "none" | "unknown";

//
// Inputs to the sync gate: the two persisted user toggles plus the current
// network state. Used to decide whether an automatic sync may run right now.
//
export interface ISyncGateInputs {
    //
    // Master switch: whether the user has syncing enabled at all.
    //
    syncEnabled: boolean;

    //
    // Whether the user has restricted automatic syncing to Wi-Fi connections.
    //
    syncOnlyOnWifi: boolean;

    //
    // Whether the device currently has a network connection.
    //
    connected: boolean;

    //
    // The current connection type used to enforce the Wi-Fi-only restriction.
    //
    connectionType: NetworkConnectionType;
}

//
// Computes whether an automatic sync is currently allowed. Returns false when
// syncing is disabled, when offline, or when the Wi-Fi-only restriction is on
// and the connection is cellular. A connectionType of "wifi" or "unknown" is
// permitted under the Wi-Fi-only restriction (desktop/web cannot detect
// cellular, so they report "unknown" and remain allowed).
//
export function computeSyncAllowed(inputs: ISyncGateInputs): boolean {
    if (!inputs.syncEnabled) {
        return false;
    }
    if (!inputs.connected) {
        return false;
    }
    if (inputs.connectionType === "none") {
        return false;
    }
    if (inputs.syncOnlyOnWifi && inputs.connectionType === "cellular") {
        return false;
    }
    return true;
}
