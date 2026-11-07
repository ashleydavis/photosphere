//
// The kind of network connection currently in use. "unknown" is reported by
// platforms that cannot distinguish wired/wifi/cellular (desktop and web
// browsers); it is treated as allowed so those platforms sync whenever online.
// (Zig: an enum, whose tag names are the strings.)
//
pub const NetworkConnectionType = enum {
    // A Wi-Fi connection ("wifi").
    wifi,

    // A cellular connection ("cellular").
    cellular,

    // No connection ("none").
    none,

    // A platform that cannot tell one connection from another ("unknown").
    unknown,
};

//
// Inputs to the automatic sync check: the two persisted user toggles plus the current
// network state. Used to decide whether an automatic sync may run right now.
//
pub const ISyncGateInputs = struct {
    //
    // Master switch: whether the user has syncing enabled at all.
    //
    syncEnabled: bool,

    //
    // Whether the user has restricted automatic syncing to Wi-Fi connections.
    //
    syncOnlyOnWifi: bool,

    //
    // Whether the device currently has a network connection.
    //
    connected: bool,

    //
    // The current connection type used to enforce the Wi-Fi-only restriction.
    //
    connectionType: NetworkConnectionType,
};

//
// Computes whether an automatic sync is currently allowed. Returns false when
// syncing is disabled, when offline, or when the Wi-Fi-only restriction is on
// and the connection is cellular. A connectionType of "wifi" or "unknown" is
// permitted under the Wi-Fi-only restriction (desktop/web cannot detect
// cellular, so they report "unknown" and remain allowed).
//
pub fn computeSyncAllowed(inputs: ISyncGateInputs) bool {
    if (!inputs.syncEnabled) {
        return false;
    }
    if (!inputs.connected) {
        return false;
    }
    if (inputs.connectionType == .none) {
        return false;
    }
    if (inputs.syncOnlyOnWifi and inputs.connectionType == .cellular) {
        return false;
    }
    return true;
}
