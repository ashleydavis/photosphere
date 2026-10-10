//
// Photosphere's answers to the core's host requests on iOS: the photo permission prompt, the device keychain, the connection type and
// the things the background work asks of the platform. Each request is named by its method and carries and returns JSON text. The core
// calls from a worker thread and waits, so a request may block on a permission prompt.
//

import Foundation
import os.log
import Photos
import UserNotifications
import ZiggyShellIOS

// Photosphere's host request handler.
final class PhotosphereHostRequests: ZiggyHostRequestHandler {
    // The keychain the app's secrets are in.
    private let secureStore = SecureStore(service: "au.com.codecapers.photosphere.securestore")

    // Reports the kind of connection the phone has.
    private let network = NetworkHost()

    // Keeps the app running while a background pass is.
    private let wakeHold = BackgroundWakeHold()

    // Runs ImageMagick, ffmpeg and ffprobe.
    private let mediaTools = MediaTools()

    // The log the background work reports to. The background work runs with the app off screen, when the app's own log file (written
    // through the page) is not being written, so what it is doing is told to the system log.
    private let backgroundLog = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "au.com.codecapers.photosphere.ziggy", category: "AutoImportService")

    // The handlers that answer the methods this class does not, by method name. Fixed when the class is made, so the core's worker
    // threads read it without a lock.
    private let otherHandlers: [String: ZiggyHostRequestHandler]

    init(otherHandlers: [String: ZiggyHostRequestHandler]) {
        self.otherHandlers = otherHandlers
    }

    func handle(method: String, requestJson: String) throws -> String {
        switch method {
        case "requestMediaPermission":
            return try requestMediaPermission()
        case "requestNotificationPermission":
            return try requestNotificationPermission()
        case "networkConnectionType":
            return try HostJson.quote(network.connectionType(), method: method)
        case "secureStoreGet":
            let request = try HostJson.object(from: requestJson, method: method)
            let value = try keychain(method) {
                try self.secureStore.get(key: try HostJson.string(request, "key", method: method))
            }
            let reply: [String: Any] = [
                "value": value ?? NSNull(),
            ]
            return try HostJson.text(from: reply, method: method)
        case "secureStoreSet":
            let request = try HostJson.object(from: requestJson, method: method)
            let key = try HostJson.string(request, "key", method: method)
            let value = try HostJson.string(request, "value", method: method)
            try keychain(method) {
                try self.secureStore.set(key: key, value: value)
            }
            return "null"
        case "secureStoreDelete":
            let request = try HostJson.object(from: requestJson, method: method)
            let key = try HostJson.string(request, "key", method: method)
            try keychain(method) {
                try self.secureStore.delete(key: key)
            }
            return "null"
        case "secureStoreKeys":
            let keys = try keychain(method) {
                try self.secureStore.keys()
            }
            let reply: [String: Any] = [
                "keys": keys,
            ]
            return try HostJson.text(from: reply, method: method)
        case "holdAwake":
            let request = try HostJson.object(from: requestJson, method: method)
            guard let awake = request["awake"] as? Bool else {
                throw ZiggyHostRequestError("The request \(method) was not understood: \"awake\" is missing or is not true or false.")
            }
            wakeHold.hold(awake)
            return "null"
        case "runMagick", "runFfmpeg", "runFfprobe":
            return try mediaTools.run(method: method, requestJson: requestJson)
        case "backgroundLog":
            let request = try HostJson.object(from: requestJson, method: method)
            let message = try HostJson.string(request, "message", method: method)
            guard let isError = request["error"] as? Bool else {
                throw ZiggyHostRequestError("The request \(method) was not understood: \"error\" is missing or is not true or false.")
            }
            os_log("%{public}@", log: backgroundLog, type: isError ? .error : .info, message)
            return "null"
        default:
            if let other = otherHandlers[method] {
                return try other.handle(method: method, requestJson: requestJson)
            }
            throw ZiggyHostRequestError("The Photosphere iOS app cannot do \"\(method)\" yet.")
        }
    }

    // Runs a keychain operation, turning a keychain failure into a failure of the request that says the keychain could not be used.
    private func keychain<Answer>(_ method: String, _ operation: () throws -> Answer) throws -> Answer {
        do {
            return try operation()
        }
        catch let failure as ZiggyHostRequestError {
            throw failure
        }
        catch {
            throw ZiggyHostRequestError("The device keychain could not be used for \(method): \(error)")
        }
    }

    // Asks for the photo library permission and reports whether it was granted, as {granted, partial}.
    //
    // Only read access is asked for. Limited access (the user choosing particular photos) counts as granted: automatic import can
    // only see what it was given, and telling the user it was refused when they deliberately shared a few photos would be wrong. So
    // partial is always false on iOS.
    private func requestMediaPermission() throws -> String {
        let finished = DispatchSemaphore(value: 0)
        var granted = false
        PHPhotoLibrary.requestAuthorization { status in
            if #available(iOS 14, *) {
                granted = status == .authorized || status == .limited
            }
            else {
                granted = status == .authorized
            }
            finished.signal()
        }
        finished.wait()
        let reply: [String: Any] = [
            "granted": granted,
            "partial": false,
        ]
        return try HostJson.text(from: reply, method: "requestMediaPermission")
    }

    // Reports whether notifications are allowed, as {granted}, without asking. iOS shows no ongoing notification while the background
    // work runs, so there is nothing to ask for, and the answer only says what the system's setting is.
    private func requestNotificationPermission() throws -> String {
        let finished = DispatchSemaphore(value: 0)
        var granted = false
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            granted = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            finished.signal()
        }
        finished.wait()
        let reply: [String: Any] = [
            "granted": granted,
        ]
        return try HostJson.text(from: reply, method: "requestNotificationPermission")
    }
}
