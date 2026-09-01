import Foundation
import Network

//
// Reports what kind of connection this phone currently has, for the background sync.
//
// The "Only sync over Wi-Fi" setting refuses a sync on a cellular connection, and the loop that
// decides that runs while the app is off screen, so it cannot ask the WebView what the network is
// doing: there may be no WebView. It asks here instead, through the platform.
//
// The names returned are the four computeSyncAllowed understands, and match NetworkHost.java exactly.
// What to do about each of them is decided there, in TypeScript, and not here.
//
final class NetworkHost {

    //
    // The connection is Wi-Fi, or something else that is not metered by a mobile carrier.
    //
    static let connectionWifi = "wifi"

    //
    // The connection is a mobile carrier's, which is the one the Wi-Fi-only setting refuses.
    //
    static let connectionCellular = "cellular"

    //
    // There is no connection at all.
    //
    static let connectionNone = "none"

    //
    // There is a connection, but not one that can be identified as either of the two above.
    //
    // computeSyncAllowed permits this, deliberately: an unrecognised transport must not stop syncing
    // altogether, which is the same reason the desktop reports it.
    //
    static let connectionUnknown = "unknown"

    //
    // The one monitor, shared by every engine that asks.
    //
    // NWPathMonitor reports the current path continuously once started, rather than answering a
    // question when asked, so it is started once and its latest path is read from. Starting one per
    // call would answer "unsatisfied" for the first moments of every call, which for a sync loop
    // means refusing to sync on a phone that is perfectly well connected.
    //
    private static let shared = NetworkHost()

    //
    // The monitor whose latest path is read.
    //
    private let monitor = NWPathMonitor()

    //
    // Guards the latest path below, which the monitor's queue writes and callers read.
    //
    private let stateLock = NSLock()

    //
    // The most recent path the monitor reported, or nil before it has reported one.
    //
    private var latestPath: NWPath?

    //
    // Starts the monitor. Private: everything goes through the shared instance.
    //
    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else {
                return
            }
            self.stateLock.lock()
            self.latestPath = path
            self.stateLock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "au.com.codecapers.photosphere.network-host"))
    }

    //
    // Returns the current connection type as one of the four names above.
    //
    static func connectionType() -> String {
        return shared.currentConnectionType()
    }

    //
    // The current connection type, from the latest path the monitor reported.
    //
    // A path that has not arrived yet reports "unknown" rather than "none". The monitor delivers its
    // first update within moments of starting, and the difference matters: "none" refuses a sync,
    // and refusing one because the answer had not arrived yet would be a phone that syncs a few
    // seconds later than it should have, reported as a phone with no network.
    //
    func currentConnectionType() -> String {
        stateLock.lock()
        let path = latestPath
        stateLock.unlock()

        guard let path = path else {
            return NetworkHost.connectionUnknown
        }

        if path.status != .satisfied {
            return NetworkHost.connectionNone
        }

        // Cellular is checked first. A phone sharing its mobile connection over a VPN, or bridging
        // one transport over another, can report more than one, and the setting exists to keep a
        // backup off the carrier's network: answering "wifi" for a connection that is also cellular
        // is the one mistake here that costs the user money.
        if path.usesInterfaceType(.cellular) {
            return NetworkHost.connectionCellular
        }

        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
            // Ethernet counts as Wi-Fi here rather than as its own name, because the only question
            // anything asks of this is whether the connection is the carrier's. A simulator on a
            // host's network reports ethernet, and calling that "unknown" would be true and useless.
            return NetworkHost.connectionWifi
        }

        return NetworkHost.connectionUnknown
    }
}
